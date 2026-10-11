#!/system/bin/sh
# Hamedis Performance Core (HPC) - hardware / kernel capability detection
#
# Nothing in HPC assumes a Snapdragon 860, a cluster layout, a governor
# name, a GPU vendor or a thermal zone name. Everything is discovered at
# runtime and cached, so the same module works on other devices/kernels.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_CAPS="$HPC_STATE/capabilities.conf"

CPU_SYS="/sys/devices/system/cpu"

# ----------------------------------------------------------------------
# CPU
# ----------------------------------------------------------------------

detect_cpu_count() {
    _n=0
    for _c in "$CPU_SYS"/cpu[0-9]*; do
        [ -d "$_c" ] || continue
        case "${_c##*/}" in
            cpu[0-9]*) _n=$((_n + 1)) ;;
        esac
    done
    printf '%s' "$_n"
}

# cpufreq policies are the reliable way to find clusters.
# Falls back to per-cpu cpufreq dirs on older kernels.
detect_policies() {
    _found=""
    for _p in "$CPU_SYS"/cpufreq/policy[0-9]*; do
        [ -d "$_p" ] || continue
        _found="$_found $_p"
    done
    if [ -z "$_found" ]; then
        for _c in "$CPU_SYS"/cpu[0-9]*/cpufreq; do
            [ -d "$_c" ] || continue
            _found="$_found $_c"
        done
    fi
    printf '%s' "${_found# }"
}

# Cluster = distinct policy. Report first CPU of each policy.
detect_clusters() {
    _out=""
    for _p in $(detect_policies); do
        _cpus=$(read_node "$_p/related_cpus" 2>/dev/null)
        [ -n "$_cpus" ] || _cpus=$(read_node "$_p/affected_cpus" 2>/dev/null)
        _first=$(printf '%s' "$_cpus" | awk '{print $1}')
        [ -n "$_first" ] && _out="$_out $_first"
    done
    printf '%s' "${_out# }"
}

detect_governors() {
    # Available governors on the first policy that exposes them.
    for _p in $(detect_policies); do
        _g=$(read_node "$_p/scaling_available_governors") && {
            printf '%s' "$_g"
            return 0
        }
    done
    return 1
}

# Pick the best available governor from a preference list.
# pick_governor "schedutil walt interactive ondemand"
pick_governor() {
    _want="$1"
    _avail=$(detect_governors) || return 1
    for _g in $_want; do
        for _a in $_avail; do
            [ "$_g" = "$_a" ] && { printf '%s' "$_g"; return 0; }
        done
    done
    return 1
}

cpu_online_state() {
    _on=0; _off=0
    for _c in "$CPU_SYS"/cpu[0-9]*; do
        [ -d "$_c" ] || continue
        _f="$_c/online"
        if [ -f "$_f" ]; then
            if [ "$(read_node "$_f")" = "1" ]; then _on=$((_on+1)); else _off=$((_off+1)); fi
        else
            # cpu0 usually has no online node; it is always online.
            _on=$((_on + 1))
        fi
    done
    printf '%s/%s' "$_on" "$((_on + _off))"
}

# ----------------------------------------------------------------------
# GPU  (Adreno/KGSL, Mali, PowerVR - discovered, never assumed)
# ----------------------------------------------------------------------

detect_gpu_path() {
    # Ordered by likelihood on Qualcomm, then generic devfreq.
    for _p in \
        /sys/class/kgsl/kgsl-3d0 \
        /sys/devices/platform/soc/*.qcom,kgsl-3d0/kgsl/kgsl-3d0 \
        /sys/devices/platform/*.mali \
        /sys/class/devfreq/*.gpu \
        /sys/class/devfreq/*gpu* ; do
        [ -d "$_p" ] && { printf '%s' "$_p"; return 0; }
    done
    return 1
}

detect_gpu_vendor() {
    _g="$1"
    case "$_g" in
        *kgsl*)  printf 'adreno' ;;
        *mali*)  printf 'mali' ;;
        *)       printf 'generic' ;;
    esac
}

# Which GPU knobs actually exist here?
detect_gpu_caps() {
    _g="$1"
    _caps=""
    [ -f "$_g/devfreq/governor" ]           && _caps="$_caps governor"
    [ -f "$_g/devfreq/min_freq" ]           && _caps="$_caps min_freq"
    [ -f "$_g/devfreq/max_freq" ]           && _caps="$_caps max_freq"
    [ -f "$_g/devfreq/available_governors" ] && _caps="$_caps avail_gov"
    [ -f "$_g/force_clk_on" ]               && _caps="$_caps force_clk"
    [ -f "$_g/idle_timer" ]                 && _caps="$_caps idle_timer"
    [ -f "$_g/throttling" ]                 && _caps="$_caps throttling"
    [ -f "$_g/gpu_busy_percentage" ]        && _caps="$_caps busy_pct"
    [ -f "$_g/gpuclk" ]                     && _caps="$_caps gpuclk"
    printf '%s' "${_caps# }"
}

# ----------------------------------------------------------------------
# Thermal
# ----------------------------------------------------------------------

# All thermal zones with a readable temp. Output: "zonepath:type" per line.
detect_thermal_zones() {
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -d "$_z" ] || continue
        [ -r "$_z/temp" ] || continue
        _tz_type=$(read_node "$_z/type" 2>/dev/null)
        [ -n "$_tz_type" ] || _tz_type="unknown"
        printf '%s:%s\n' "$_z" "$_tz_type"
    done
}

# Find the zone that best represents CPU/SoC temperature.
# Different kernels name these wildly differently, so we score candidates.
detect_cpu_thermal_zone() {
    _best=""
    _best_score=0
    for _line in $(detect_thermal_zones); do
        _z="${_line%%:*}"
        _type="${_line#*:}"
        _score=0
        case "$_type" in
            *cpu-0-0*|*cpuss*|*cpu0*)      _score=100 ;;
            *cpu*)                          _score=90 ;;
            *apc*|*silver*|*gold*)          _score=80 ;;
            *soc*|*aoss*)                   _score=60 ;;
            *tsens*)                        _score=50 ;;
            *skin*|*quiet-therm*|*xo*)      _score=30 ;;
            *battery*|*bat*|*usb*|*chg*)    _score=0  ;;
            *)                              _score=10 ;;
        esac
        [ "$_score" -gt "$_best_score" ] && { _best_score=$_score; _best="$_z"; }
    done
    [ -n "$_best" ] && { printf '%s' "$_best"; return 0; }
    return 1
}

# Milli-degrees -> degrees. Handles both scales defensively.
read_temp_c() {
    _z="$1"
    _raw=$(read_node "$_z/temp") || return 1
    case "$_raw" in
        ''|*[!0-9-]*) return 1 ;;
    esac
    if [ "$_raw" -gt 1000 ] || [ "$_raw" -lt -1000 ]; then
        printf '%s' "$((_raw / 1000))"
    else
        printf '%s' "$_raw"
    fi
}

# Is the kernel currently throttling? Only if it exposes the state.
detect_thermal_throttling() {
    for _p in \
        /sys/class/thermal/thermal_message/sconfig \
        /sys/module/msm_thermal/parameters/enabled ; do
        [ -r "$_p" ] && { read_node "$_p"; return 0; }
    done
    return 1
}

# ----------------------------------------------------------------------
# Memory / zRAM
# ----------------------------------------------------------------------

detect_zram() {
    for _z in /sys/block/zram[0-9]*; do
        [ -d "$_z" ] && { printf '%s' "$_z"; return 0; }
    done
    return 1
}

zram_active() {
    _z=$(detect_zram) || return 1
    _d=$(read_node "$_z/disksize" 2>/dev/null)
    [ -n "$_d" ] && [ "$_d" != "0" ]
}

detect_vm_knobs() {
    _vmk=""
    for _n in swappiness vfs_cache_pressure dirty_ratio dirty_background_ratio \
              dirty_expire_centisecs dirty_writeback_centisecs \
              min_free_kbytes watermark_boost_factor extra_free_kbytes \
              page-cluster stat_interval ; do
        [ -w "/proc/sys/vm/$_n" ] && _vmk="$_vmk $_n"
    done
    printf '%s' "${_vmk# }"
}

# ----------------------------------------------------------------------
# Battery
# ----------------------------------------------------------------------

detect_battery_path() {
    for _b in /sys/class/power_supply/battery \
              /sys/class/power_supply/bms \
              /sys/class/power_supply/BAT0 ; do
        [ -d "$_b" ] && [ -r "$_b/capacity" ] && { printf '%s' "$_b"; return 0; }
    done
    for _b in /sys/class/power_supply/*; do
        [ -r "$_b/capacity" ] && { printf '%s' "$_b"; return 0; }
    done
    return 1
}

battery_capacity() {
    _b=$(detect_battery_path) || return 1
    read_node "$_b/capacity"
}

battery_charging() {
    _b=$(detect_battery_path) || return 1
    _s=$(read_node "$_b/status") || return 1
    case "$_s" in
        Charging|Full) return 0 ;;
        *) return 1 ;;
    esac
}

battery_temp_c() {
    _b=$(detect_battery_path) || return 1
    _bt_raw=$(read_node "$_b/temp") || return 1
    case "$_bt_raw" in ''|*[!0-9-]*) return 1 ;; esac
    # Usually decidegrees (e.g. 350 = 35.0 C)
    if [ "$_bt_raw" -gt 200 ] || [ "$_bt_raw" -lt -200 ]; then
        printf '%s' "$((_bt_raw / 10))"
    else
        printf '%s' "$_bt_raw"
    fi
}

# ----------------------------------------------------------------------
# Scheduler / misc kernel knobs
# ----------------------------------------------------------------------

detect_sched_knobs() {
    _schedk=""
    for _n in sched_min_granularity_ns sched_wakeup_granularity_ns \
              sched_migration_cost_ns sched_latency_ns \
              sched_child_runs_first sched_autogroup_enabled ; do
        [ -w "/proc/sys/kernel/$_n" ] && _schedk="$_schedk $_n"
    done
    printf '%s' "${_schedk# }"
}

detect_stune() {
    [ -d /dev/stune ] && { printf '/dev/stune'; return 0; }
    [ -d /dev/cpuctl ] && { printf '/dev/cpuctl'; return 0; }
    return 1
}

# ----------------------------------------------------------------------
# Capability snapshot
# ----------------------------------------------------------------------

run_detection() {
    [ -d "$HPC_STATE" ] || mkdir -p "$HPC_STATE" 2>/dev/null

    _cpus=$(detect_cpu_count)
    _pols=$(detect_policies)
    _npol=$(printf '%s' "$_pols" | wc -w | tr -d ' ')
    _clusters=$(detect_clusters)
    _govs=$(detect_governors 2>/dev/null)
    _gpu=$(detect_gpu_path 2>/dev/null)
    _gpuvendor=""
    _gpucaps=""
    if [ -n "$_gpu" ]; then
        _gpuvendor=$(detect_gpu_vendor "$_gpu")
        _gpucaps=$(detect_gpu_caps "$_gpu")
    fi
    _tz=$(detect_cpu_thermal_zone 2>/dev/null)
    _tzcount=$(detect_thermal_zones | wc -l | tr -d ' ')
    _zram=$(detect_zram 2>/dev/null)
    _vm=$(detect_vm_knobs)
    _sched=$(detect_sched_knobs)
    _stune=$(detect_stune 2>/dev/null)
    _batt=$(detect_battery_path 2>/dev/null)

    {
        printf '# HPC capability snapshot - generated %s\n' "$(date 2>/dev/null)"
        printf 'CPU_COUNT=%s\n'        "$_cpus"
        printf 'POLICY_COUNT=%s\n'     "$_npol"
        printf 'POLICIES="%s"\n'       "$_pols"
        printf 'CLUSTERS="%s"\n'       "$_clusters"
        printf 'GOVERNORS="%s"\n'      "$_govs"
        printf 'GPU_PATH="%s"\n'       "$_gpu"
        printf 'GPU_VENDOR="%s"\n'     "$_gpuvendor"
        printf 'GPU_CAPS="%s"\n'       "$_gpucaps"
        printf 'THERMAL_ZONE="%s"\n'   "$_tz"
        printf 'THERMAL_ZONES=%s\n'    "$_tzcount"
        printf 'ZRAM_PATH="%s"\n'      "$_zram"
        printf 'VM_KNOBS="%s"\n'       "$_vm"
        printf 'SCHED_KNOBS="%s"\n'    "$_sched"
        printf 'STUNE_PATH="%s"\n'     "$_stune"
        printf 'BATTERY_PATH="%s"\n'   "$_batt"
    } >"$HPC_CAPS" 2>/dev/null

    chmod 0600 "$HPC_CAPS" 2>/dev/null
    log_info "detection: cpus=$_cpus policies=$_npol gpu=${_gpuvendor:-none} tz=${_tz:-none} zram=${_zram:-none}"
    return 0
}

load_capabilities() {
    if [ ! -f "$HPC_CAPS" ]; then
        run_detection
    fi
    # shellcheck source=/dev/null
    [ -f "$HPC_CAPS" ] && . "$HPC_CAPS"
    return 0
}
