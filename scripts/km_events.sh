#!/system/bin/sh
# Hamedis Performance Core (HPC) - unified kernel event timeline
#
# Part of the Kernel Management Platform (v1.10).
#
# A bounded ring of timestamped, typed events the service loop and the
# change engine append to. The UI shows the recent history so a user
# can inspect what happened around a problem.
#
# Types emitted today:
#   boot            new boot detected (boot_id changed)
#   boot_audit      effective configuration snapshot after boot
#   profile_change  active profile changed
#   thermal_high    hottest CPU sensor crossed a warning threshold
#   thermal_ok      temperature dropped back under the threshold
#   batt_low        battery below the configured warning level
#   game_start / game_end
#   cap_lost        a capability disappeared between scans
#   bench           a benchmark session finished
#   config_restore  a rollback/restore ran
#
# The file is plain TSV so it can be inspected with adb as well.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
KM_EVENTS="$HPC_STATE/events"
KM_EVENTS_MAX="${KM_EVENTS_MAX:-500}"
KM_EV_KV="$HPC_STATE/event_kv"   # key<TAB>value (reuses safety.sh _kv_*)

km_event() {
    # km_event TYPE DETAIL
    [ -n "$1" ] || return 0
    printf '%s\t%s\t%s\n' "$(km_now_ms 2>/dev/null || date +%s000)" "$1" "$2" >>"$KM_EVENTS" 2>/dev/null
    _ev_n=$(wc -l <"$KM_EVENTS" 2>/dev/null | tr -d ' ')
    if [ "${_ev_n:-0}" -gt "$KM_EVENTS_MAX" ]; then
        _tmp="$KM_EVENTS.tmp"
        tail -n "$KM_EVENTS_MAX" "$KM_EVENTS" >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$KM_EVENTS" 2>/dev/null
    fi
    return 0
}

# km_events [N] [TYPE] -> JSON array, newest first
km_events() {
    _en="${1:-60}"
    _etype="${2:-}"
    case "$_en" in ''|*[!0-9]*) _en=60 ;; esac
    [ -f "$KM_EVENTS" ] || { printf '{"ts":%s,"events":[]}\n' "$(km_now_ms)"; return 0; }
    _ej=""
    _efirst=1
    _ecount=0
    # line-by-line (a for-loop would word-split the multi-line log)
    while IFS= read -r _el; do
        [ -n "$_el" ] || continue
        _et=$(printf '%s' "$_el" | awk -F '\t' '{print $2}')
        [ -n "$_etype" ] && [ "$_et" != "$_etype" ] && continue
        _ets=$(printf '%s' "$_el" | awk -F '\t' '{print $1}')
        _ed=$(printf '%s' "$_el" | awk -F '\t' '{print $3}')
        [ "$_efirst" = "1" ] || _ej="$_ej,"
        _efirst=0
        _ej="${_ej}$(printf '{"ts":%s,"type":%s,"detail":%s}' "$_ets" "$(km_jesc "$_et")" "$(km_jesc "$_ed")")"
        _ecount=$((_ecount + 1))
        [ "$_ecount" -ge "$_en" ] && break
    done <<_HPEOF
$(tac "$KM_EVENTS" 2>/dev/null || cat "$KM_EVENTS")
_HPEOF
    printf '{"ts":%s,"events":[%s]}\n' "$(km_now_ms)" "$_ej"
}

# ----------------------------------------------------------------------
# service-loop tick: samples state, emits transition events only.
# Cheap: a handful of reads per call.
# ----------------------------------------------------------------------

km_event_tick() {
    [ -d "$HPC_STATE" ] || mkdir -p "$HPC_STATE" 2>/dev/null
    [ -f "$KM_EV_KV" ] || : >"$KM_EV_KV" 2>/dev/null

    # --- boot detection
    _et_bootid=$(head -n1 /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$_et_bootid" ]; then
        _et_lastboot=$(_kv_get "$KM_EV_KV" bootid 2>/dev/null)
        if [ "$_et_bootid" != "$_et_lastboot" ]; then
            km_event boot "new boot detected (boot_id changed)"
            _et_bootlines=0
            if [ -f "$HPC_APPLIED" ]; then
                _et_bootlines=$(wc -l <"$HPC_APPLIED" 2>/dev/null | tr -d ' ')
                cp -f "$HPC_APPLIED" "$HPC_STATE/boot_applied_$(date +%s)" 2>/dev/null
            fi
            km_event boot_audit "applied settings after boot: ${_et_bootlines:-0} node(s); profile=$(current_profile 2>/dev/null)"
            _kv_set "$KM_EV_KV" bootid "$_et_bootid"
            _kv_set "$KM_EV_KV" t_flag 0
            _kv_set "$KM_EV_KV" b_flag 0
            _kv_set "$KM_EV_KV" g_flag 0
            _kv_del "$KM_EV_KV" last_prof 2>/dev/null
        fi
    fi

    # --- thermal transitions (CPU-ish sensor)
    _et_tz=$(detect_cpu_thermal_zone 2>/dev/null)
    if [ -n "$_et_tz" ]; then
        _et_t=$(read_temp_c "$_et_tz" 2>/dev/null)
        if [ -n "$_et_t" ]; then
            _kv_set "$KM_EV_KV" last_t "$_et_t"
            _et_warn=45
            _et_flag=$(_kv_get "$KM_EV_KV" t_flag 2>/dev/null)
            if [ "${_et_flag:-0}" != "1" ] && [ "$_et_t" -ge "$_et_warn" ] 2>/dev/null; then
                km_event thermal_high "CPU sensor at ${_et_t}C (warning >= ${_et_warn}C)"
                _kv_set "$KM_EV_KV" t_flag 1
            elif [ "${_et_flag:-0}" = "1" ] && [ "$_et_t" -lt "$((_et_warn - 5))" ] 2>/dev/null; then
                km_event thermal_ok "CPU sensor back to ${_et_t}C"
                _kv_set "$KM_EV_KV" t_flag 0
            fi
        fi
    fi

    # --- profile change
    _et_prof=$(current_profile 2>/dev/null)
    if [ -n "$_et_prof" ] && [ "$_et_prof" != "unknown" ]; then
        _et_lastprof=$(_kv_get "$KM_EV_KV" last_prof 2>/dev/null)
        if [ "$_et_prof" != "$_et_lastprof" ]; then
            km_event profile_change "active profile -> $_et_prof (was: ${_et_lastprof:-boot})"
            _kv_set "$KM_EV_KV" last_prof "$_et_prof"
        fi
    fi

    # --- battery low crossing
    _et_bcap=$(battery_capacity 2>/dev/null)
    if [ -n "$_et_bcap" ]; then
        _et_bflag=$(_kv_get "$KM_EV_KV" b_flag 2>/dev/null)
        if [ "${_et_bflag:-0}" != "1" ] && [ "$_et_bcap" -le "${BATT_LOW:-20}" ] 2>/dev/null; then
            km_event batt_low "battery at ${_et_bcap}%"
            _kv_set "$KM_EV_KV" b_flag 1
        elif [ "${_et_bflag:-0}" = "1" ] && [ "$_et_bcap" -gt "$(( ${BATT_LOW:-20} + 5 ))" ] 2>/dev/null; then
            _kv_set "$KM_EV_KV" b_flag 0
        fi
    fi

    # --- game transitions
    if command -v game_is_active >/dev/null 2>&1; then
        _et_g="0"; game_is_active && _et_g="1"
        _et_gflag=$(_kv_get "$KM_EV_KV" g_flag 2>/dev/null)
        if [ "$_et_g" = "1" ] && [ "${_et_gflag:-0}" != "1" ]; then
            km_event game_start "$(game_current_pkg 2>/dev/null)"
            _kv_set "$KM_EV_KV" g_flag 1
        elif [ "$_et_g" = "0" ] && [ "${_et_gflag:-0}" = "1" ]; then
            km_event game_end "$(game_current_pkg 2>/dev/null)"
            _kv_set "$KM_EV_KV" g_flag 0
        fi
    fi
    return 0
}
