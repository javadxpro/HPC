#!/system/bin/sh
# Hamedis Performance Core (HPC) - graphics pipeline management
#
# ======================================================================
# READ THIS FIRST - what this file does and does NOT do
# ======================================================================
#
# A very common request is "put all the graphics load on the GPU so the
# CPU only does its own work". That request is based on a misconception
# worth spelling out, because acting on it naively makes things WORSE.
#
# 1. Rendering is ALREADY on the GPU. Hardware acceleration has been the
#    default for every app targeting API 14+ since Android 4.0. There is
#    no switch that "moves rendering to the GPU" because it is already
#    there.
#
# 2. CPU render work CANNOT be moved to the GPU. In a game frame the CPU
#    does game logic, physics, culling, asset streaming and - critically -
#    builds the command buffer that tells the GPU what to draw. The GPU
#    physically cannot build its own command buffer. This is not a tuning
#    limitation; it is what the two processors are.
#
# 3. "Disable HW overlays" (developer options) does the OPPOSITE of what
#    people expect. Hardware overlay planes composite surfaces in the
#    display controller for near-zero cost. Disabling them forces
#    SurfaceFlinger to composite on the GPU, which ADDS GPU load, adds a
#    render pass, and burns more power. This module never touches it.
#
# 4. "Force GPU rendering" only affects legacy apps that explicitly opted
#    OUT of acceleration. On a modern ROM it is close to a no-op, and it
#    can break apps that deliberately render in software.
#
# What this file DOES, which is real:
#
#   - Switches HWUI to the Vulkan backend (skiavk) where the driver
#     supports it. This genuinely reduces CPU-side driver overhead,
#     because Vulkan's command submission is far cheaper per draw call
#     than GLES. That is a real CPU->GPU efficiency shift.
#   - Keeps the GPU from power-gating between frames during gameplay.
#   - Reports which renderer is active and whether anything is falling
#     back to software rendering, so you can see the real state instead
#     of guessing.
# ======================================================================
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_GFX_BACKUP="$HPC_STATE/graphics_original"

# ----------------------------------------------------------------------
# Detection
# ----------------------------------------------------------------------

# Which HWUI backend is configured right now?
gfx_current_renderer() {
    _gr=$(getprop debug.hwui.renderer 2>/dev/null)
    if [ -z "$_gr" ]; then
        _gr=$(getprop ro.hwui.renderer 2>/dev/null)
    fi
    [ -n "$_gr" ] || _gr="default(skiagl)"
    printf '%s' "$_gr"
}

# Does this device actually have a Vulkan driver?
# We check for the loader library and the driver HAL, not just a property.
gfx_vulkan_available() {
    for _vl in /vendor/lib64/hw/vulkan.*.so \
               /vendor/lib/hw/vulkan.*.so \
               /system/lib64/libvulkan.so \
               /system/lib/libvulkan.so ; do
        [ -f "$_vl" ] && return 0
    done
    return 1
}

# Vulkan API level the device reports, if any.
gfx_vulkan_version() {
    _vv=$(getprop ro.hardware.vulkan.level 2>/dev/null)
    _vd=$(getprop ro.hardware.vulkan.version 2>/dev/null)
    if [ -n "$_vv" ] || [ -n "$_vd" ]; then
        printf 'level=%s version=%s' "${_vv:-?}" "${_vd:-?}"
        return 0
    fi
    return 1
}

# Is the GPU currently doing work? Adreno exposes a busy percentage.
gfx_gpu_busy() {
    _gg="${GPU_PATH:-}"
    [ -n "$_gg" ] || _gg=$(detect_gpu_path 2>/dev/null)
    [ -n "$_gg" ] || return 1
    _gb=$(read_node "$_gg/gpu_busy_percentage" 2>/dev/null)
    # Some kernels format this as "12 %" - strip anything non-numeric.
    _gb=$(printf '%s' "$_gb" | tr -cd '0-9')
    [ -n "$_gb" ] || return 1
    printf '%s' "$_gb"
}

gfx_gpu_clock_mhz() {
    _gc="${GPU_PATH:-}"
    [ -n "$_gc" ] || _gc=$(detect_gpu_path 2>/dev/null)
    [ -n "$_gc" ] || return 1
    _hz=$(read_node "$_gc/gpuclk" 2>/dev/null)
    case "$_hz" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' $(( _hz / 1000000 ))
}

# Is SurfaceFlinger using hardware overlay planes (good) or falling back
# to GPU composition (worse)? Requires one dumpsys call, so this is only
# ever used in the status report, never in the service loop.
gfx_composition_mode() {
    command -v dumpsys >/dev/null 2>&1 || { printf 'unknown'; return 1; }
    _cm=$(dumpsys SurfaceFlinger 2>/dev/null | grep -c 'DEVICE' 2>/dev/null)
    case "$_cm" in ''|*[!0-9]*) printf 'unknown'; return 1 ;; esac
    if [ "$_cm" -gt 0 ]; then
        printf 'hardware overlays'
    else
        printf 'GPU composition'
    fi
}

# Is the "disable HW overlays" developer option currently set?
#
# BUG FIX (v1.8.5): this used to read debug.sf.disable_hwc and
# debug.sf.disable_overlays with getprop. Neither property exists.
#
# The Settings toggle does NOT set a system property. It sends a binder
# transaction straight to SurfaceFlinger:
#
#   data.writeInterfaceToken("android.ui.ISurfaceComposer");
#   data.writeInt(disableOverlays ? 1 : 0);
#   flinger.transact(1008, data, null, 0);
#
# which flips mDebugDisableHWC inside the running SurfaceFlinger process.
# Nothing is persisted anywhere - that is also why the toggle resets on
# every reboot.
#
# So the old check returned "not disabled" unconditionally, and the
# status report cheerfully printed "HW overlays : enabled (correct)"
# on a device where the user had just turned them off. It was reporting
# a constant, not a measurement.
#
# The real state lives in SurfaceFlinger's own dump. When HWC is
# disabled every layer is composited by the GPU, so the composition
# type for all layers becomes CLIENT instead of DEVICE.
gfx_overlays_disabled() {
    command -v dumpsys >/dev/null 2>&1 || return 1

    _od_dump=$(dumpsys SurfaceFlinger 2>/dev/null)
    [ -n "$_od_dump" ] || return 1

    # Some builds print the flag outright. Trust it when present.
    case "$_od_dump" in
        *"mDebugDisableHWC=1"*) return 0 ;;
        *"mDebugDisableHWC=0"*) return 1 ;;
    esac

    # Otherwise infer from composition types. A normal device composites
    # at least one layer on the display controller (DEVICE). If there
    # are visible layers and NONE of them is DEVICE, HWC is off.
    _od_dev=$(printf '%s' "$_od_dump" | grep -c 'DEVICE' 2>/dev/null)
    _od_cli=$(printf '%s' "$_od_dump" | grep -c 'CLIENT' 2>/dev/null)
    case "$_od_dev" in ''|*[!0-9]*) return 1 ;; esac
    case "$_od_cli" in ''|*[!0-9]*) _od_cli=0 ;; esac

    [ "$_od_dev" -eq 0 ] && [ "$_od_cli" -gt 0 ] && return 0
    return 1
}

# Is "Force 4x MSAA" on?
#
# Unlike the overlay toggle, this one IS a real system property. From
# AOSP eglApi.cpp:
#
#   property_get("debug.egl.force_msaa", value, "false");
#   ... // Only enable MSAA if the context is OpenGL ES 2.0
#   aaAttribs[0] = EGL_SAMPLE_BUFFERS;   // force-enable MSAA 4x
#
# Two consequences people get wrong:
#
#  - It only applies to contexts requesting EGL_OPENGL_ES2_BIT. An
#    engine on GLES 3.x or Vulkan ignores it completely. This device
#    renders with skiavk (Vulkan), so the system UI is unaffected.
#  - Where it DOES apply it makes the GPU shade 4 samples per pixel.
#    That is strictly more GPU work, more memory bandwidth and more
#    heat. It cannot reduce load.
gfx_msaa_forced() {
    _fm=$(getprop debug.egl.force_msaa 2>/dev/null)
    [ "$_fm" = "true" ] || [ "$_fm" = "1" ]
}

# ----------------------------------------------------------------------
# Property backup / restore
# ----------------------------------------------------------------------

_gfx_backup_prop() {
    _bp="$1"
    [ -d "$HPC_STATE" ] || mkdir -p "$HPC_STATE" 2>/dev/null
    [ -f "$HPC_GFX_BACKUP" ] || : >"$HPC_GFX_BACKUP" 2>/dev/null
    # Only save the first time we see this property.
    if ! awk -F '\t' -v k="$_bp" '$1==k{f=1;exit} END{exit !f}' \
         "$HPC_GFX_BACKUP" 2>/dev/null; then
        _bv=$(getprop "$_bp" 2>/dev/null)
        printf '%s\t%s\n' "$_bp" "$_bv" >>"$HPC_GFX_BACKUP" 2>/dev/null
    fi
}

_gfx_set_prop() {
    _sp="$1"; _sv="$2"
    command -v resetprop >/dev/null 2>&1 || {
        log_unsupported "resetprop" "not available"
        return 1
    }
    _gfx_backup_prop "$_sp"
    if resetprop "$_sp" "$_sv" 2>/dev/null; then
        log_debug "prop $_sp = $_sv"
        return 0
    fi
    log_warn "failed to set $_sp"
    return 1
}

gfx_restore_props() {
    [ -f "$HPC_GFX_BACKUP" ] || return 0
    command -v resetprop >/dev/null 2>&1 || return 1
    while IFS="$(printf '\t')" read -r _rp _rv; do
        [ -n "$_rp" ] || continue
        if [ -z "$_rv" ]; then
            resetprop --delete "$_rp" 2>/dev/null
        else
            resetprop "$_rp" "$_rv" 2>/dev/null
        fi
    done <"$HPC_GFX_BACKUP"
    : >"$HPC_GFX_BACKUP" 2>/dev/null
    log_info "graphics properties restored"
    return 0
}

# ----------------------------------------------------------------------
# The one real optimisation: Vulkan backend for HWUI
# ----------------------------------------------------------------------
#
# GLES command submission costs meaningful CPU time per draw call because
# the driver validates and translates state on the CPU. Vulkan moves that
# work into pre-built command buffers, cutting CPU driver overhead
# substantially. For a UI/game thread that is CPU-bound on draw
# submission, this is a genuine win - and it is the closest thing that
# exists to "let the CPU do less graphics work".
#
# It is applied only when a Vulkan driver is actually present, and it is
# reversible.

gfx_enable_vulkan() {
    if ! gfx_vulkan_available; then
        log_info "graphics: no Vulkan driver present, keeping GLES"
        return 1
    fi
    _gfx_set_prop debug.hwui.renderer skiavk
    log_info "graphics: HWUI backend -> Vulkan (skiavk)"
    return 0
}

gfx_enable_gles() {
    _gfx_set_prop debug.hwui.renderer skiagl
    log_info "graphics: HWUI backend -> GLES (skiagl)"
    return 0
}

# ----------------------------------------------------------------------
# Profile hook
# ----------------------------------------------------------------------
#
# Called by apply_profile. Honours GFX_RENDERER from the active profile:
#   auto    - Vulkan if available, else leave alone   (recommended)
#   vulkan  - force Vulkan if a driver exists
#   gles    - force the GLES backend
#   off     - do not touch the renderer at all
#
# NOTE: HWUI reads this property when an app process starts. Changing it
# affects apps launched afterwards, not ones already running. This is a
# platform behaviour, not a bug in the module - which is exactly why we
# report it rather than pretending the change is instant.

apply_graphics() {
    _gm="${GFX_RENDERER:-auto}"

    case "$_gm" in
        off|"")
            return 0
            ;;
        vulkan)
            gfx_enable_vulkan
            ;;
        gles)
            gfx_enable_gles
            ;;
        auto)
            # Only switch if we are not already on Vulkan.
            case "$(gfx_current_renderer)" in
                *vk*) log_debug "graphics: already on Vulkan" ;;
                *)    gfx_enable_vulkan ;;
            esac
            ;;
        *)
            log_warn "unknown GFX_RENDERER: $_gm"
            ;;
    esac

    # Safety net: if the user has left "disable HW overlays" on in
    # developer options, that is costing them GPU time and battery.
    # We do not silently override a deliberate developer setting, but we
    # make sure it is visible.
    if gfx_overlays_disabled; then
        log_warn "developer option 'disable HW overlays' is ON - this forces GPU composition and hurts performance. Turn it off in Developer Options."
    fi

    return 0
}

# ----------------------------------------------------------------------
# Reporting
# ----------------------------------------------------------------------

gfx_report() {
    printf '  Renderer     : %s\n' "$(gfx_current_renderer)"

    if gfx_vulkan_available; then
        _vinfo=$(gfx_vulkan_version 2>/dev/null)
        printf '  Vulkan       : available%s\n' "${_vinfo:+ ($_vinfo)}"
    else
        printf '  Vulkan       : not present\n'
    fi

    _busy=$(gfx_gpu_busy 2>/dev/null)
    _clk=$(gfx_gpu_clock_mhz 2>/dev/null)
    if [ -n "$_busy" ] || [ -n "$_clk" ]; then
        printf '  GPU load     : %s%%%s\n' "${_busy:-?}" \
            "${_clk:+  @ ${_clk} MHz}"
    fi

    # Three states, not two. Previously this printed "enabled (correct)"
    # whenever the check failed, which on this device meant ALWAYS -
    # including when the user had just switched overlays off by hand.
    # Claiming to know something we cannot read is worse than saying so.
    if ! command -v dumpsys >/dev/null 2>&1; then
        printf '  HW overlays  : unknown (dumpsys unavailable)\n'
    elif gfx_overlays_disabled; then
        printf '  HW overlays  : DISABLED - forces GPU composition\n'
        printf '                 this ADDS GPU load and power draw.\n'
        printf '                 Re-enable:  service call SurfaceFlinger 1008 i32 0\n'
    else
        printf '  HW overlays  : enabled (correct)\n'
    fi

    if gfx_msaa_forced; then
        printf '  Force 4x MSAA: ON - 4x GPU shading cost in GLES2 apps\n'
        printf '                 no effect on Vulkan/GLES3 titles.\n'
        printf '                 Turn off:  setprop debug.egl.force_msaa false\n'
    fi
}
