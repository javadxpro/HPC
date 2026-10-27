#!/system/bin/sh
# Hamedis Performance Core - WebUI backend (CGI)
#
# Every endpoint is a thin wrapper over the same functions hpc.sh
# uses, so the web interface can never do anything the CLI cannot, and
# all writes still go through safe_write() with backup + verify.
# shellcheck disable=SC3043

# BUG FIX (v1.8.6 - APK support): the module path was hardcoded. The HPC
# Kernel Manager app invokes this script by its real location via su, so
# derive MODDIR from $0 first (same logic as hpc.sh) and only fall back to
# the historical default when the path is unusable.
MODDIR="${0%/*}"
case "$MODDIR" in
    /*) ;;                                    # already absolute
    *)  MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" || MODDIR="" ;;
esac
if [ ! -f "$MODDIR/../../module.prop" ]; then
    MODDIR="${HPC_WEB_MODDIR:-/data/adb/modules/hamedis_performance_core}"
fi
export HPC_MODDIR="$MODDIR"

# BUG FIX (v1.8.4): "Connection error" in the WebUI.
#
# The header was printed AFTER sourcing common.sh. Anything that made
# the bootstrap die - a hand-edited config.conf with an unterminated
# quote, a partially-extracted module after a failed flash - killed the
# script before a single byte was sent. busybox httpd then closed the
# connection with no status line at all, and fetch() rejected, which
# the UI reports as "خطای ارتباط".
#
# Worse, the `|| { ...; exit 0; }` fallback below never ran. A syntax
# error inside a sourced file is a FATAL error in Android's shell: it
# terminates the whole script immediately and the `||` branch is not
# reached. The error handler only ever worked under bash.
#
# So: emit the header FIRST. Whatever happens afterwards, the browser
# already has a valid HTTP response and shows a real message instead of
# a dead connection.
printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'

if [ ! -f "$MODDIR/scripts/common.sh" ]; then
    printf '{"error":"module not found at %s"}' "$MODDIR"
    exit 0
fi

# Sourcing happens in a guarded subshell first: if the config or any
# library has a syntax error, the subshell dies but WE survive and can
# report it, instead of the connection dropping. When the config is the
# culprit, say so with the offending line (ash includes the number).
if ! ( . "$MODDIR/scripts/common.sh" && hpc_bootstrap ) >/dev/null 2>&1; then
    _bs_cfg=$( ( . "$MODDIR/scripts/common.sh" 2>/dev/null && hpc_config_check ) 2>/dev/null )
    case "$_bs_cfg" in
        ok|missing)
            _bs_hint="bootstrap failed - run: sh $MODDIR/hpc.sh doctor"
            ;;
        *)
            _bs_hint="bootstrap failed - config.conf is broken: $_bs_cfg (fix: sh $MODDIR/hpc.sh config-fix)"
            ;;
    esac
    # jstr is defined further down; escape inline (backslash, quote,
    # control chars) so the hint can never break the JSON.
    _bs_esc=$(printf '%s' "$_bs_hint" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\t' ' ' | tr -d '\000-\037\177')
    printf '{"error":"%s"}\n' "$_bs_esc"
    exit 0
fi

# shellcheck source=/dev/null
. "$MODDIR/scripts/common.sh" 2>/dev/null
hpc_bootstrap >/dev/null 2>&1

# ---------------------------------------------------------------- utils
# Parse QUERY_STRING into a value. qs_get KEY
qs_get() {
    printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' |
        awk -F= -v k="$1" '$1==k {print $2; exit}'
}

# BUG FIX (v1.8.4): only CR and LF were stripped. JSON forbids EVERY
# control character below 0x20 in a string, unescaped. A log line
# containing a tab - which any `printf '%s\t%s'` in the codebase can
# produce - emitted a raw 0x09 and JSON.parse() threw, so the whole
# page reported "connection error" when the connection was fine.
#
# tr -d with a range deletes the lot. Tabs become spaces first, since
# they are usually meaningful alignment in a log line.
json_esc() {
    printf '%s' "$1" |
        sed 's/\\/\\\\/g; s/"/\\"/g' |
        tr '\t' ' ' |
        tr -d '\000-\037\177'
}

jstr() { printf '"%s"' "$(json_esc "$1")"; }

# Emit a number, or null when empty/non-numeric.
jnum() {
    case "$1" in
        ''|*[!0-9-]*) printf 'null' ;;
        *)            printf '%s' "$1" ;;
    esac
}

# --------------------------------------------------------------- SECURITY
# BUG FIX (v1.8.1): profile names arrived from the query string and were
# interpolated straight into a filesystem path, so
#   ?action=profile_detail&value=../../state/original_values
# escaped the profile directory. Names are now checked against a fixed
# list and the path is built by one function only.
# The curated built-in profile set (v1.12.0). User-created profiles are
# handled separately (kmprof), this list only guards the built-in name
# -> path mapping.
HPC_VALID_PROFILES="overclock gaming120 gaming90 performance balanced battery_saver longevity"

valid_profile() {
    case "$1" in
        ''|*[!a-z0-9]*) return 1 ;;
    esac
    for _vp in $HPC_VALID_PROFILES; do
        [ "$1" = "$_vp" ] && return 0
    done
    return 1
}

# The ONLY sanctioned way to turn a profile name into a path.
profile_path_safe() {
    valid_profile "$1" || return 1
    if [ -f "$HPC_DATA/profiles/$1.conf" ]; then
        printf '%s' "$HPC_DATA/profiles/$1.conf"; return 0
    fi
    if [ -f "$HPC_MODDIR/config/profiles/$1.conf" ]; then
        printf '%s' "$HPC_MODDIR/config/profiles/$1.conf"; return 0
    fi
    return 1
}

ACTION=$(qs_get action)
[ -n "$ACTION" ] || ACTION="status"

# Reject anything that is not a known action before it reaches dispatch.
case "$ACTION" in
    status|profiles|profile_detail|kernel|games|setprofile|\
    setio|settcp|tune|do|log|ping|clean|cleanrun|ramclean|boost|boostset|\
    km|kmctl|kmrollback|kmprof|kmbench|kmadvise|kmreport|mgsk|renderer) ;;
    *) printf '{"error":"invalid action"}'; exit 0 ;;
esac

# ---------------------------------------------------------------- ping
# Lightweight reachability probe for the native HPC Kernel Manager app:
# no node reads, no bootstrap-heavy work beyond what is already done.
api_ping() {
    printf '{"ok":true,"version":%s,"module":%s}' \
        "$(jstr "${HPC_VERSION:-?}")" "$(jstr "$(basename "$HPC_MODDIR")")"
}

# ---------------------------------------------------------- renderer
# Global HWUI renderer switch (debug.hwui.renderer). Valueless = report
# state; with value = switch (vulkan|gles|legacy|default). Only affects
# apps launched afterwards - the API says so, it does not force-stop
# anything on the user's behalf.
api_renderer() {
    _rv=$(qs_get value)
    case "$_rv" in
        ''|null)
            gfx_renderer_json
            printf '\n'
            ;;
        vulkan|gles|legacy|default)
            if gfx_set_renderer "$_rv"; then
                printf '{"ok":true,"current":%s,"note":"applies to apps launched after this change"}\n' \
                    "$(jstr "$(gfx_current_renderer 2>/dev/null)")"
            else
                printf '{"ok":false,"error":"failed to set renderer (resetprop missing or no Vulkan driver)"}\n'
            fi
            ;;
        *)
            printf '{"ok":false,"error":"bad renderer mode (use vulkan|gles|legacy|default)"}\n'
            ;;
    esac
}

# ---------------------------------------------------------------- status
api_status() {
    _temp=$(thermal_read 2>/dev/null)
    _tstate=$(thermal_get_state 2>/dev/null)
    _tstep=$(thermal_get_step 2>/dev/null)
    _prof=$(current_profile 2>/dev/null)
    _cap=$(battery_capacity 2>/dev/null)
    _btemp=$(battery_temp_c 2>/dev/null)
    _chg=false; battery_charging 2>/dev/null && _chg=true
    _game=$(game_current_pkg 2>/dev/null)
    _gov=""
    for _p in $(detect_policies); do
        _gov=$(read_node "$_p/scaling_governor" 2>/dev/null)
        [ -n "$_gov" ] && break
    done
    _cmax=""; _cmin=""; _ccur=""
    for _p in $(detect_policies); do
        _cmax=$(read_node "$_p/scaling_max_freq" 2>/dev/null)
        _cmin=$(read_node "$_p/scaling_min_freq" 2>/dev/null)
        _ccur=$(read_node "$_p/scaling_cur_freq" 2>/dev/null)
        [ -n "$_cmax" ] && break
    done
    _gbusy=$(gfx_gpu_busy 2>/dev/null)
    _gclk=$(gfx_gpu_clock_mhz 2>/dev/null)
    _rate=$(km_charge_rate_ma 2>/dev/null)
    _ram=$(ram_summary 2>/dev/null)
    _rend=$(gfx_current_renderer 2>/dev/null)

    printf '{'
    printf '"profile":%s,'      "$(jstr "$_prof")"
    printf '"game":%s,'         "$(jstr "$_game")"
    printf '"soc_temp":%s,'     "$(jnum "$_temp")"
    printf '"thermal_state":%s,' "$(jstr "$_tstate")"
    printf '"thermal_step":%s,' "$(jnum "$_tstep")"
    printf '"battery":%s,'      "$(jnum "$_cap")"
    printf '"battery_temp":%s,' "$(jnum "$_btemp")"
    printf '"charging":%s,'     "$_chg"
    printf '"charge_rate":%s,'  "$(jnum "$_rate")"
    printf '"governor":%s,'     "$(jstr "$_gov")"
    printf '"cpu_max":%s,'      "$(jnum "$_cmax")"
    printf '"cpu_min":%s,'      "$(jnum "$_cmin")"
    printf '"cpu_cur":%s,'      "$(jnum "$_ccur")"
    printf '"gpu_busy":%s,'     "$(jnum "$_gbusy")"
    printf '"gpu_mhz":%s,'      "$(jnum "$_gclk")"
    printf '"renderer":%s,'     "$(jstr "$_rend")"
    printf '"ram":%s,'          "$(jstr "$_ram")"
    printf '"cores":%s,'        "$(jnum "${CPU_COUNT:-}")"
    printf '"gpu_vendor":%s,'   "$(jstr "${GPU_VENDOR:-}")"
    printf '"version":%s'       "$(jstr "${HPC_VERSION:-?}")"
    printf '}'
}

# ------------------------------------------------------------ profiles
api_profiles() {
    printf '{"current":%s,"list":[' "$(jstr "$(current_profile)")"
    _first=1
    for _f in "$HPC_DATA/profiles"/*.conf; do
        [ -f "$_f" ] || continue
        _n=$(basename "$_f" .conf)
        _desc=$(grep '^PROFILE_DESC=' "$_f" 2>/dev/null | cut -d'"' -f2)
        _cmaxp=$(grep '^CPU_MAX_PERCENT=' "$_f" 2>/dev/null | cut -d= -f2)
        _cminp=$(grep '^CPU_MIN_PERCENT=' "$_f" 2>/dev/null | cut -d= -f2)
        _tw=$(grep '^TEMP_WARM=' "$_f" 2>/dev/null | cut -d= -f2)
        _th=$(grep '^TEMP_HOT=' "$_f" 2>/dev/null | cut -d= -f2)
        [ "$_first" -eq 1 ] || printf ','
        _first=0
        printf '{"id":%s,"desc":%s,"cpu_max":%s,"cpu_min":%s,"warm":%s,"hot":%s}' \
            "$(jstr "$_n")" "$(jstr "$_desc")" \
            "$(jnum "$_cmaxp")" "$(jnum "$_cminp")" \
            "$(jnum "$_tw")" "$(jnum "$_th")"
    done
    printf ']}'
}

# -------------------------------------------------------------- kernel
api_kernel() {
    _io=$(km_io_current 2>/dev/null)
    _ioav=$(km_io_available 2>/dev/null)
    _tcp=$(km_tcp_current 2>/dev/null)
    _tcpav=$(km_tcp_available 2>/dev/null)
    _zram=$(km_zram_info 2>/dev/null)
    _health=$(km_battery_health 2>/dev/null)
    _ra=""
    for _d in $(km_block_devices); do
        _ra=$(read_node "$_d/queue/read_ahead_kb" 2>/dev/null)
        [ -n "$_ra" ] && break
    done
    _sel=false; _selinux_enforcing 2>/dev/null && _sel=true

    printf '{'
    printf '"io":%s,'            "$(jstr "$_io")"
    printf '"io_available":%s,'  "$(jstr "$_ioav")"
    printf '"read_ahead":%s,'    "$(jnum "$_ra")"
    printf '"tcp":%s,'           "$(jstr "$_tcp")"
    printf '"tcp_available":%s,' "$(jstr "$_tcpav")"
    printf '"zram":%s,'          "$(jstr "$_zram")"
    printf '"battery_health":%s,' "$(jstr "$_health")"
    printf '"selinux":%s'        "$_sel"
    printf '}'
}

# --------------------------------------------------------------- games
api_games() {
    printf '{"auto":%s,"profile":%s,"packages":[' \
        "$([ "${AUTO_GAME_MODE:-1}" = "1" ] && echo true || echo false)" \
        "$(jstr "${GAME_PROFILE:-performance}")"
    _first=1
    for _p in ${GAME_PACKAGES:-}; do
        case "$_p" in ''|\#*) continue ;; esac
        [ "$_first" -eq 1 ] || printf ','
        _first=0
        printf '%s' "$(jstr "$_p")"
    done
    printf ']}'
}

# ---------------------------------------------------------------- apply
api_set_profile() {
    # NOTE: every local here is prefixed. POSIX sh has no scoping, and the
    # library functions we call (detect_policies, apply_profile, ...) use
    # short names like _p and _t internally. Sharing a name means the
    # callee silently overwrites our value mid-function.
    _asp_req=$(qs_get value)
    valid_profile "$_asp_req" || {
        printf '{"ok":false,"error":"unknown profile"}'; return; }
    _asp_eff=$(battery_adjust_profile "$_asp_req")
    apply_profile "$_asp_eff" quiet >/dev/null 2>&1
    # Per-key persistence: if MODE= is missing, sed would no-op and the
    # service hot-reload would bounce the profile back to the default.
    if [ -f "$HPC_CONFIG" ]; then
        if grep -q '^MODE=' "$HPC_CONFIG" 2>/dev/null; then
            _asp_tmp="$HPC_CONFIG.tmp.$$"
            sed "s/^MODE=.*/MODE=$_asp_req/" "$HPC_CONFIG" >"$_asp_tmp" 2>/dev/null &&
                mv -f "$_asp_tmp" "$HPC_CONFIG" 2>/dev/null || rm -f "$_asp_tmp" 2>/dev/null
        else
            printf 'MODE=%s\n' "$_asp_req" >>"$HPC_CONFIG" 2>/dev/null
        fi
    fi
    printf '{"ok":true,"applied":%s,"requested":%s}' \
        "$(jstr "$_asp_eff")" "$(jstr "$_asp_req")"
}

api_set_io() {
    _sio_v=$(qs_get value)
    if km_set_io "$_sio_v" >/dev/null 2>&1; then
        printf '{"ok":true,"io":%s}' "$(jstr "$_sio_v")"
    else
        printf '{"ok":false,"error":"scheduler not available"}'
    fi
}

api_set_tcp() {
    _stc_v=$(qs_get value)
    TCP_CONGESTION="$_stc_v"
    if km_apply_tcp >/dev/null 2>&1; then
        printf '{"ok":true,"tcp":%s}' "$(jstr "$_stc_v")"
    else
        printf '{"ok":false,"error":"congestion algorithm not available"}'
    fi
}

# Write a single key into a profile file. Used by the manual tuning UI.
api_tune() {
    _tn_prof=$(qs_get profile)
    _tn_key=$(qs_get key)
    _tn_val=$(qs_get value)
    _tn_file=$(profile_path_safe "$_tn_prof") || {
        printf '{"ok":false,"error":"no such profile"}'; return; }

    # Whitelist: only tunables we understand may be written from the web.
    case "$_tn_key" in
        CPU_MAX_PERCENT|CPU_MIN_PERCENT|GPU_MAX_PERCENT|GPU_MIN_PERCENT|\
        TEMP_WARM|TEMP_HOT|TEMP_CRITICAL|\
        GPU_IDLE_TIMER|POLL_INTERVAL|SCHED_LATENCY_NS|\
        IO_READ_AHEAD_KB|VM_SWAPPINESS) ;;
        *) printf '{"ok":false,"error":"key not tunable"}'; return ;;
    esac
    case "$_tn_val" in ''|*[!0-9]*) printf '{"ok":false,"error":"bad value"}'; return ;; esac

    # Sanity clamps so the UI cannot produce a dangerous config.
    case "$_tn_key" in
        CPU_MAX_PERCENT|GPU_MAX_PERCENT)
            [ "$_tn_val" -lt 30 ] && _tn_val=30
            [ "$_tn_val" -gt 100 ] && _tn_val=100 ;;
        CPU_MIN_PERCENT|GPU_MIN_PERCENT)
            [ "$_tn_val" -gt 60 ] && _tn_val=60 ;;
        TEMP_WARM|TEMP_HOT|TEMP_CRITICAL)
            [ "$_tn_val" -lt 35 ] && _tn_val=35
            # Never allow a threshold above the kernel's own throttle range.
            [ "$_tn_val" -gt 85 ] && _tn_val=85 ;;
        POLL_INTERVAL)
            [ "$_tn_val" -lt 15 ] && _tn_val=15
            [ "$_tn_val" -gt 300 ] && _tn_val=300 ;;
        VM_SWAPPINESS)
            [ "$_tn_val" -gt 200 ] && _tn_val=200 ;;
    esac

    _tn_tmp="$_tn_file.tmp.$$"
    if grep -q "^$_tn_key=" "$_tn_file" 2>/dev/null; then
        sed "s/^$_tn_key=.*/$_tn_key=$_tn_val/" "$_tn_file" >"$_tn_tmp" 2>/dev/null
    else
        cp "$_tn_file" "$_tn_tmp" 2>/dev/null
        printf '%s=%s\n' "$_tn_key" "$_tn_val" >>"$_tn_tmp" 2>/dev/null
    fi
    mv -f "$_tn_tmp" "$_tn_file" 2>/dev/null || {
        rm -f "$_tn_tmp"
        printf '{"ok":false,"error":"write failed"}'
        return
    }

    log_info "webui: $_tn_prof $_tn_key=$_tn_val"

    # Capture the reply BEFORE re-applying: apply_profile sources the
    # profile file and clobbers our variables.
    _tn_reply=$(printf '{"ok":true,"key":%s,"value":%s}' \
        "$(jstr "$_tn_key")" "$_tn_val")

    if [ "$_tn_prof" = "$(current_profile)" ]; then
        apply_profile "$_tn_prof" quiet >/dev/null 2>&1
    fi
    printf '%s' "$_tn_reply"
}

api_profile_detail() {
    _apd_p=$(qs_get value)
    _f=$(profile_path_safe "$_apd_p") || {
        printf '{"ok":false,"error":"unknown profile"}'; return; }
    printf '{"ok":true,"values":{'
    _first=1
    for _k in CPU_MAX_PERCENT CPU_MIN_PERCENT GPU_MAX_PERCENT GPU_MIN_PERCENT \
              TEMP_WARM TEMP_HOT TEMP_CRITICAL \
              GPU_IDLE_TIMER POLL_INTERVAL VM_SWAPPINESS IO_READ_AHEAD_KB; do
        _v=$(grep "^$_k=" "$_f" 2>/dev/null | cut -d= -f2 | tr -d ' ')
        [ -n "$_v" ] || continue
        [ "$_first" -eq 1 ] || printf ','
        _first=0
        printf '%s:%s' "$(jstr "$_k")" "$(jnum "$_v")"
    done
    printf '}}'
}

api_action() {
    _c=$(qs_get value)
    case "$_c" in
        game)      _h=$(game_scan); [ -n "$_h" ] && game_enter "${_h%% *}" "${_h#* }" >/dev/null 2>&1
                   printf '{"ok":true}' ;;
        stopgame)  game_exit >/dev/null 2>&1; printf '{"ok":true}' ;;
        reset)     restore_all >/dev/null 2>&1
                   gfx_restore_props >/dev/null 2>&1
                   printf '{"ok":true}' ;;
        reload)    hpc_load_config; run_detection >/dev/null 2>&1
                   printf '{"ok":true}' ;;
        *)         printf '{"ok":false,"error":"unknown"}' ;;
    esac
}

api_log() {
    printf '{"lines":['
    _first=1
    if [ -f "$HPC_LOG_DIR/hpc.log" ]; then
        tail -n 60 "$HPC_LOG_DIR/hpc.log" 2>/dev/null | while IFS= read -r _l; do
            [ "$_first" -eq 1 ] || printf ','
            _first=0
            jstr "$_l"
        done
    fi
    printf ']}'
}

# -------------------------------------------------------------- cleaner
# Scan: sizes of every cleanable target (no deletion).
api_clean() {
    _acf_free=$(cleaner_storage_free_kb /data)
    _acr_free=$(cleaner_storage_free_kb /cache)
    _asd_free=$(cleaner_storage_free_kb /sdcard)
    printf '{'
    printf '"free_data":%s,'  "$(jnum "$_acf_free")"
    printf '"free_cache":%s,' "$(jnum "$_acr_free")"
    printf '"free_sdcard":%s,' "$(jnum "$_asd_free")"
    printf '"quick":%s,' "$(cleaner_scan_json quick)"
    printf '"deep":%s'   "$(cleaner_scan_json deep)"
    printf '}'
}

# Run a cleanup. value=quick|deep (whitelisted - the target list itself
# is hardcoded in cleaner.sh, never user-supplied).
api_cleanrun() {
    _acl_mode=$(qs_get value)
    case "$_acl_mode" in
        quick|deep) ;;
        *) printf '{"ok":false,"error":"bad mode"}'; return ;;
    esac
    # Free space before, so the reply can state the real delta.
    _acl_before=$(cleaner_storage_free_kb /data)
    _acl_kb=$(cleaner_run "$_acl_mode")
    _acl_after=$(cleaner_storage_free_kb /data)
    _acl_delta=0
    case "$_acl_before" in ''|*[!0-9]*) ;; *)
        case "$_acl_after" in ''|*[!0-9]*) ;; *)
            _acl_delta=$(( _acl_after - _acl_before )) ;;
        esac ;;
    esac
    printf '{"ok":true,"mode":%s,"freed_kb":%s,"delta_kb":%s,"free_data":%s}' \
        "$(jstr "$_acl_mode")" "$(jnum "$_acl_kb")" \
        "$(jnum "$_acl_delta")" "$(jnum "$_acl_after")"
}

# RAM housekeeping (logcat clear + drop clean page caches).
api_ramclean() {
    if [ "$(cleaner_ram)" = "ok" ]; then
        printf '{"ok":true}'
    else
        printf '{"ok":false,"error":"unsupported"}'
    fi
}

# -------------------------------------------------------------- booster
api_boost() {
    _ab_gov=""
    for _ab_p in $(detect_policies); do
        _ab_gov=$(read_node "$_ab_p/scaling_governor" 2>/dev/null)
        [ -n "$_ab_gov" ] && break
    done
    _ab_io=$(km_io_current 2>/dev/null)
    _ab_anim=$(booster_anim_value 2>/dev/null)
    _ab_swap=$(read_node /proc/sys/vm/swappiness 2>/dev/null)
    _ab_vfs=$(read_node /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
    _ab_mem=$(booster_memext_state 2>/dev/null)
    _ab_act=false; booster_active 2>/dev/null && _ab_act=true
    _ab_prof=$(current_profile 2>/dev/null)

    printf '{'
    printf '"active":%s,'        "$_ab_act"
    printf '"profile":%s,'       "$(jstr "$_ab_prof")"
    printf '"governor":%s,'      "$(jstr "$_ab_gov")"
    printf '"io":%s,'            "$(jstr "$_ab_io")"
    printf '"animations":%s,'    "$(jstr "$_ab_anim")"
    printf '"swappiness":%s,'    "$(jnum "$_ab_swap")"
    printf '"cache_pressure":%s,' "$(jnum "$_ab_vfs")"
    printf '"virtual_ram":%s'    "$(jstr "$_ab_mem")"
    printf '}'
}

# value is a strict whitelist; anything else is rejected.
api_boostset() {
    _abs_v=$(qs_get value)
    case "$_abs_v" in
        speed_on|speed_off|anim_on|anim_off|vm_on|vm_off|memext_on|memext_off) ;;
        *) printf '{"ok":false,"error":"unknown"}'; return ;;
    esac
    case "$_abs_v" in
        speed_on)   booster_speed_on;  printf '{"ok":true,"mode":"speed_on"}' ;;
        speed_off)  booster_speed_off; printf '{"ok":true,"mode":"speed_off"}' ;;
        anim_on)    if booster_anim_on;  then printf '{"ok":true}'; else printf '{"ok":false,"error":"settings unavailable"}'; fi ;;
        anim_off)   if booster_anim_off; then printf '{"ok":true}'; else printf '{"ok":false,"error":"settings unavailable"}'; fi ;;
        vm_on)      if booster_vm_on;   then printf '{"ok":true}'; else printf '{"ok":false,"error":"not supported"}'; fi ;;
        vm_off)     booster_vm_off;     printf '{"ok":true}' ;;
        memext_on)  if booster_memext_on;  then printf '{"ok":true}'; else printf '{"ok":false,"error":"not found on this ROM"}'; fi ;;
        memext_off) if booster_memext_off; then printf '{"ok":true}'; else printf '{"ok":false,"error":"not found on this ROM"}'; fi ;;
    esac
}

# ================================================================
# Kernel Management Platform endpoints (v1.10)
#
# Thin wrappers over the km_* functions; every write goes through the
# registry's validate -> protect -> safe_write -> log pipeline.
# ================================================================

# strict [a-z0-9] name check for anything that becomes a filename
_km_name_ok() {
    # a-z0-9_ only, 1-40 chars (no dots, no slashes - no traversal possible)
    case "$1" in
        ''|*[!a-z0-9_]*|.) return 1 ;;
    esac
    [ "${#1}" -le 40 ]
}

# ---------------------------------------------------------- km (monitoring)
api_km() {
    _kmsub=$(qs_get value)
    case "$_kmsub" in
        status)   km_mon_status ;;
        cpu)      km_mon_cpu ;;
        gpu)      km_mon_gpu ;;
        mem)      km_mon_mem ;;
        thermal)  km_mon_thermal ;;
        battery)  km_mon_batt ;;
        net)      km_mon_net ;;
        disk)     km_mon_disk ;;
        sched)    km_mon_sched ;;
        procs)    km_mon_procs ;;
        modules)  km_mon_modules ;;
        klog)
            _kln=$(qs_get n); case "$_kln" in ''|*[!0-9]*) _kln=100 ;; esac
            km_mon_klog "$_kln" "$(qs_get pat)"
            ;;
        caps)     km_caps_json ;;
        events)
            _ken=$(qs_get n); case "$_ken" in ''|*[!0-9]*) _ken=60 ;; esac
            km_events "$_ken" "$(qs_get type)"
            ;;
        health)   km_health ;;
        history)
            _khn=$(qs_get n); case "$_khn" in ''|*[!0-9]*) _khn=50 ;; esac
            # TSV -> JSON
            _kj=""
            _kf=1
            while IFS="$(printf '\t')" read -r h_ts h_id h_path h_old h_new h_src h_prof h_st h_ver; do
                [ -n "$h_ts" ] || continue
                [ "$_kf" = "1" ] || _kj="$_kj,"
                _kf=0
                _kj="$_kj{\"ts\":$h_ts,\"id\":$(jstr "$h_id"),\"path\":$(jstr "$h_path"),\"old\":$(jstr "$h_old"),\"new\":$(jstr "$h_new"),\"source\":$(jstr "$h_src"),\"profile\":$(jstr "$h_prof"),\"status\":$(jstr "$h_st"),\"verified\":$(jstr "$h_ver")}"
            done <<EOT
$(km_history "$_khn")
EOT
            printf '{"ts":%s,"entries":[%s]}\n' "$(date +%s000)" "$_kj"
            ;;
        *)        printf '{"error":"unknown km sub: %s"}' "$_kmsub" ;;
    esac
}

# ---------------------------------------------------------- kmctl (writes)
api_kmctl() {
    _kcid=$(qs_get id)
    _kcval=$(qs_get value)
    _kcsrc=$(qs_get src)
    [ -n "$_kcsrc" ] || _kcsrc="ui"
    # id/value travel in the query string; the registry re-validates
    # everything anyway (characters, ranges, enums, protected paths).
    km_ctl_set "$_kcid" "$_kcval" "$_kcsrc"
}

# ---------------------------------------------------------- kmrollback
api_kmrollback() {
    _krn=$(qs_get value)
    case "$_krn" in ''|all|[0-9]*) ;; *) printf '{"error":"bad value"}'; return 0 ;; esac
    km_rollback "$_krn"
}

# ---------------------------------------------------------- kmprof (profiles)
api_kmprof() {
    _kpv=$(qs_get value)
    case "$_kpv" in
        list)
            km_prof_list
            ;;
        show:*)
            _kp="${_kpv#show:}"
            _km_name_ok "$_kp" || { printf '{"error":"bad profile name"}'; return 0; }
            km_prof_show "$_kp"
            ;;
        compare:*)
            _kp="${_kpv#compare:}"
            _kpa="${_kp%%,*}"; _kpb="${_kp#*,}"
            _km_name_ok "$_kpa" && _km_name_ok "$_kpb" || { printf '{"error":"bad profile name"}'; return 0; }
            km_prof_compare "$_kpa" "$_kpb"
            ;;
        export:*)
            _kp="${_kpv#export:}"
            _km_name_ok "$_kp" || { printf '{"error":"bad profile name"}'; return 0; }
            km_prof_export "$_kp"
            ;;
        duplicate:*)
            _kp="${_kpv#duplicate:}"
            _kps="${_kp%%,*}"; _kpd="${_kp#*,}"
            _km_name_ok "$_kps" && _km_name_ok "$_kpd" || { printf '{"error":"bad profile name"}'; return 0; }
            km_prof_duplicate "$_kps" "$_kpd"
            ;;
        delete:*)
            _kp="${_kpv#delete:}"
            _km_name_ok "$_kp" || { printf '{"error":"bad profile name"}'; return 0; }
            km_prof_delete "$_kp"
            ;;
        import)
            _kp=$(qs_get name)
            _kb64=$(qs_get b64)
            _km_name_ok "$_kp" || { printf '{"error":"bad profile name"}'; return 0; }
            [ -n "$_kb64" ] || { printf '{"error":"no content"}'; return 0; }
            # only base64 alphabet allowed
            case "$_kb64" in
                *[!A-Za-z0-9+/=]*) printf '{"error":"bad base64"}'; return 0 ;;
            esac
            [ "${#_kb64}" -le 8192 ] || { printf '{"error":"content too large"}'; return 0; }
            _kpc=$(printf '%s' "$_kb64" | base64 -d 2>/dev/null)
            [ -n "$_kpc" ] || { printf '{"error":"bad base64 payload"}'; return 0; }
            km_prof_import "$_kp" "$_kpc"
            ;;
        *)
            printf '{"error":"unknown kmprof sub"}'
            ;;
    esac
}

# ---------------------------------------------------------- kmbench
api_kmbench() {
    _kbn=$(qs_get value)
    case "$_kbn" in
        list)
            km_bench_list
            ;;
        run:*)
            _kbname="${_kbn#run:}"
            case "$_kbname" in cpu|cpux|io|mem) ;; *) printf '{"error":"unknown benchmark"}'; return 0 ;; esac
            km_bench_run "$_kbname"
            ;;
        ab:*)
            _kb="${_kbn#ab:}"
            _kbname="${_kb%%:*}"; _kbrest="${_kb#*:}"
            _kbpa="${_kbrest%%:*}"; _kbpbb="${_kbrest#*:}"
            case "$_kbname" in cpu|cpux|io|mem) ;; *) printf '{"error":"unknown benchmark"}'; return 0 ;; esac
            _km_name_ok "$_kbpa" && _km_name_ok "$_kbpbb" || { printf '{"error":"bad profile name"}'; return 0; }
            km_bench_ab "$_kbname" "$_kbpa" "$_kbpbb"
            ;;
        *)
            printf '{"error":"unknown kmbench sub"}'
            ;;
    esac
}

# ---------------------------------------------------------- kmadvise
api_kmadvise() {
    _kav=$(qs_get value)
    case "$_kav" in
        full|"")
            km_advise
            ;;
        explain:*)
            _kae="${_kav#explain:}"
            [ -n "$_kae" ] || { printf '{"error":"missing control id"}'; return 0; }
            case "$_kae" in *[\;\&\|\$\`]*) printf '{"error":"bad id"}'; return 0 ;; esac
            km_advise_explain "$_kae"
            ;;
        *)
            printf '{"error":"unknown kmadvise sub"}'
            ;;
    esac
}

# ---------------------------------------------------------- kmreport
api_kmreport() {
    _krr=$(qs_get value)
    case "$_krr" in
        run)
            km_diag_report
            ;;
        doctor)
            printf '{"ok":1,"report":%s}\n' \
                "$(jstr "$(km_doctor 2>/dev/null | awk '{printf "%s%s", (NR>1 ? " | " : ""), $0}')")"
            ;;
        file:*)
            _krf="${_krr#file:}"
            case "$_krf" in
                report_[0-9]*_redacted.txt)
                    _krpath="/data/local/tmp/hpc_exports/$_krf"
                    [ -f "$_krpath" ] || { printf '{"error":"export not found"}'; return 0; }
                    printf '{"ok":1,"file":"%s","content":%s}\n' \
                        "$(jstr "$_krf")" "$(jstr "$(cat "$_krpath" 2>/dev/null)")"
                    ;;
                *)
                    printf '{"error":"bad export name"}'
                    ;;
            esac
            ;;
        *)
            printf '{"error":"unknown kmreport sub"}'
            ;;
    esac
}

# ---------------------------------------------------------- mgsk (magisk system)
api_mgsk() {
    _mgv=$(qs_get value)
    case "$_mgv" in
        info)
            _mgi_present=0; magisk_present 2>/dev/null && _mgi_present=1
            _mgi_ver="";  [ "$_mgi_present" = 1 ] && _mgi_ver=$(magisk_version 2>/dev/null)
            _mgi_code=""; [ "$_mgi_present" = 1 ] && _mgi_code=$(magisk_version_code 2>/dev/null)
            _mgi_tmp="";  [ "$_mgi_present" = 1 ] && _mgi_tmp=$(magisk_tmp_path 2>/dev/null)
            _mgi_z="";    [ "$_mgi_present" = 1 ] && _mgi_z=$(magisk_zygisk 2>/dev/null)
            _mgi_d="";    [ "$_mgi_present" = 1 ] && _mgi_d=$(magisk_denylist_enforced 2>/dev/null)
            _mgi_n=$(magisk_modules_count 2>/dev/null)
            _mgi_h=$(hpc_web_httpd 2>/dev/null)
            _mgi_w=0; web_running 2>/dev/null && _mgi_w=1
            printf '{"ok":1,"present":%s,"version":%s,"versionCode":%s,"tmpPath":%s,"zygisk":%s,"denylistEnforced":%s,"modules":%s,"httpdBackend":%s,"webuiRunning":%s}\n' \
                "$_mgi_present" "$(jstr "$_mgi_ver")" "$(jnum "$_mgi_code")" "$(jstr "$_mgi_tmp")" \
                "$(jnum "$_mgi_z")" "$(jnum "$_mgi_d")" "$(jnum "$_mgi_n")" \
                "$(jstr "$_mgi_h")" "$_mgi_w"
            ;;
        modules)
            _mgo='{"ok":1,"modules":['
            _mgo_first=1
            while IFS="$(printf '\t')" read -r _mgo_id _mgo_name _mgo_ver _mgo_code; do
                [ -n "$_mgo_id" ] || continue
                [ "$_mgo_first" = 1 ] || _mgo="$_mgo,"
                _mgo_first=0
                _mgo="$_mgo{\"id\":$(jstr "$_mgo_id"),\"name\":$(jstr "$_mgo_name"),\"version\":$(jstr "$_mgo_ver"),\"versionCode\":$(jnum "$_mgo_code")}"
            done <<EOF
$(magisk_modules_list 2>/dev/null)
EOF
            _mgo="$_mgo]}"
            printf '%s\n' "$_mgo"
            ;;
        denylist)
            _mgd_enf=""; magisk_present 2>/dev/null && _mgd_enf=$(magisk_denylist_enforced 2>/dev/null)
            _mgd='{"ok":1,"enforced":'
            case "$_mgd_enf" in
                1) _mgd="${_mgd}true" ;;
                0) _mgd="${_mgd}false" ;;
                *) _mgd="${_mgd}null" ;;
            esac
            _mgd="$_mgd,\"entries\":["
            _mgd_first=1
            while IFS='|' read -r _mgd_pkg _mgd_proc; do
                [ -n "$_mgd_pkg" ] || continue
                [ "$_mgd_first" = 1 ] || _mgd="$_mgd,"
                _mgd_first=0
                _mgd="$_mgd{\"pkg\":$(jstr "$_mgd_pkg"),\"proc\":$(jstr "${_mgd_proc:-}")}"
            done <<EOF
$(magisk_denylist_ls 2>/dev/null)
EOF
            _mgd="$_mgd]}"
            printf '%s\n' "$_mgd"
            ;;
        denyadd)
            _mga=$(qs_get pkg)
            magisk_denylist_add "$_mga"
            ;;
        denyrmm)
            _mgr=$(qs_get pkg)
            magisk_denylist_rm "$_mgr"
            ;;
        update)
            _mgu=$(qs_get zip)
            hpc_self_update "$_mgu"
            ;;
        *)
            printf '{"error":"unknown mgsk sub"}'
            ;;
    esac
}

# -------------------------------------------------------------- router
case "$ACTION" in
    status)        api_status ;;
    profiles)      api_profiles ;;
    profile_detail) api_profile_detail ;;
    kernel)        api_kernel ;;
    games)         api_games ;;
    setprofile)    api_set_profile ;;
    setio)         api_set_io ;;
    settcp)        api_set_tcp ;;
    tune)          api_tune ;;
    do)            api_action ;;
    log)           api_log ;;
    ping)          api_ping ;;
    clean)         api_clean ;;
    cleanrun)      api_cleanrun ;;
    ramclean)      api_ramclean ;;
    boost)         api_boost ;;
    boostset)      api_boostset ;;
    km)            api_km ;;
    kmctl)         api_kmctl ;;
    kmrollback)    api_kmrollback ;;
    kmprof)        api_kmprof ;;
    kmbench)       api_kmbench ;;
    kmadvise)      api_kmadvise ;;
    kmreport)      api_kmreport ;;
    mgsk)          api_mgsk ;;
    renderer)      api_renderer ;;
    *)             printf '{"error":"unknown action"}' ;;
esac
