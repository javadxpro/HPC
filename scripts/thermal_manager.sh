#!/system/bin/sh
# Hamedis Performance Core (HPC) - thermal management
#
# POLICY: this layer only ever REDUCES the ceiling we ourselves set.
# It never touches kernel thermal drivers, never writes to thermal
# trip points, and never disables thermal protection. The kernel's own
# thermal governor remains the authority; we simply back off early so
# the kernel has to intervene less abruptly, which is what produces
# stable sustained frame times instead of sawtooth throttling.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_THERMAL_STATE="$HPC_STATE/thermal_state"
HPC_THERMAL_STEP="$HPC_STATE/thermal_step"

# Step ladder: percentage of the profile's ceiling we allow.
# 0 = no reduction, 3 = maximum reduction.
THERMAL_STEP_0=100
THERMAL_STEP_1=90
THERMAL_STEP_2=78
THERMAL_STEP_3=65

thermal_get_state() {
    [ -f "$HPC_THERMAL_STATE" ] && read_node "$HPC_THERMAL_STATE" || printf 'NORMAL'
}

thermal_get_step() {
    _s=$([ -f "$HPC_THERMAL_STEP" ] && read_node "$HPC_THERMAL_STEP")
    case "$_s" in ''|*[!0-9]*) _s=0 ;; esac
    printf '%s' "$_s"
}

thermal_set_step() {
    printf '%s' "$1" >"$HPC_THERMAL_STEP" 2>/dev/null
}

# Read the representative SoC temperature. Returns 1 if unavailable.
thermal_read() {
    _tz="${THERMAL_ZONE:-}"
    [ -n "$_tz" ] || _tz=$(detect_cpu_thermal_zone 2>/dev/null)
    [ -n "$_tz" ] || return 1
    read_temp_c "$_tz"
}

# Classify temperature into a state using the active profile thresholds.
#
# HYSTERESIS: the thresholds to go UP are the configured values, but to
# come back DOWN the temperature must fall THERMAL_HYST degrees below
# them. Without this a phone hovering right on a boundary flaps between
# states on every poll - observed on a real device as:
#     49C NORMAL -> 50C WARM -> 48C NORMAL -> 50C WARM
# fifteen transitions in twelve minutes, each one triggering a full
# profile re-apply. The re-applies cost more than the throttling saved.
thermal_classify() {
    _tc_in="$1"
    _tc_warm="${TEMP_WARM:-46}"
    _tc_hot="${TEMP_HOT:-53}"
    _tc_crit="${TEMP_CRITICAL:-60}"
    _tc_h="${THERMAL_HYST:-4}"

    # Current state decides which edge applies.
    _tc_cur=$(thermal_get_state)

    case "$_tc_cur" in
        CRITICAL)
            # Must drop well below the critical line to de-escalate.
            if   [ "$_tc_in" -ge $(( _tc_crit - _tc_h )) ]; then printf 'CRITICAL'; return 0; fi
            ;;
        HOT)
            if   [ "$_tc_in" -ge "$_tc_crit" ];             then printf 'CRITICAL'; return 0; fi
            if   [ "$_tc_in" -ge $(( _tc_hot - _tc_h )) ];  then printf 'HOT';      return 0; fi
            ;;
        WARM)
            if   [ "$_tc_in" -ge "$_tc_crit" ];             then printf 'CRITICAL'; return 0; fi
            if   [ "$_tc_in" -ge "$_tc_hot" ];              then printf 'HOT';      return 0; fi
            if   [ "$_tc_in" -ge $(( _tc_warm - _tc_h )) ]; then printf 'WARM';     return 0; fi
            ;;
    esac

    # Rising edges (or unknown previous state): use the plain thresholds.
    if   [ "$_tc_in" -ge "$_tc_crit" ]; then printf 'CRITICAL'
    elif [ "$_tc_in" -ge "$_tc_hot" ];  then printf 'HOT'
    elif [ "$_tc_in" -ge "$_tc_warm" ]; then printf 'WARM'
    else printf 'NORMAL'
    fi
}

# Apply a ceiling reduction as a percentage of each policy's hardware max.
# This only ever lowers scaling_max_freq; it never raises it above what
# the active profile allows, and never touches thermal driver nodes.
thermal_apply_step() {
    _step="$1"
    case "$_step" in
        0) _pct="$THERMAL_STEP_0" ;;
        1) _pct="$THERMAL_STEP_1" ;;
        2) _pct="$THERMAL_STEP_2" ;;
        3) _pct="$THERMAL_STEP_3" ;;
        *) _pct=100 ;;
    esac

    # Step 0 means "hand control back to the profile".
    #
    # Only the frequency CEILING needs restoring - that is the only thing
    # thermal_apply_step ever touched. Calling reapply_current() here
    # re-wrote the governor, every scheduler knob, every VM knob, the GPU
    # settings and the charge limit, on every single recovery. On a device
    # oscillating around a threshold that fired constantly and produced
    # dozens of redundant sysfs writes plus a wall of log noise.
    if [ "$_step" -eq 0 ]; then
        for _pol in $(detect_policies); do
            [ -f "$_pol/scaling_max_freq" ] || continue
            _hwmax=$(read_node "$_pol/cpuinfo_max_freq" 2>/dev/null)
            _hwmin=$(read_node "$_pol/cpuinfo_min_freq" 2>/dev/null)
            case "$_hwmax" in ''|*[!0-9]*) continue ;; esac
            case "$_hwmin" in ''|*[!0-9]*) continue ;; esac
            _pmax="${CPU_MAX_PERCENT:-100}"
            if [ "$_pmax" -ge 100 ]; then
                _target="$_hwmax"
            else
                _target=$(( _hwmin + (_hwmax - _hwmin) * _pmax / 100 ))
                _target=$(snap_to_available "$_pol" "$_target")
            fi
            safe_write "$_pol/scaling_max_freq" "$_target"
        done

        # Restore the GPU ceiling too, if we lowered it at step 2+.
        _gpu="${GPU_PATH:-}"
        [ -n "$_gpu" ] || _gpu=$(detect_gpu_path 2>/dev/null)
        if [ -n "$_gpu" ] && [ -f "$_gpu/devfreq/max_freq" ]; then
            _list=$(read_node "$_gpu/devfreq/available_frequencies" 2>/dev/null)
            if [ -n "$_list" ]; then
                _gmax=""
                for _f in $_list; do
                    case "$_f" in ''|*[!0-9]*) continue ;; esac
                    [ -z "$_gmax" ] && { _gmax="$_f"; continue; }
                    [ "$_f" -gt "$_gmax" ] && _gmax="$_f"
                done
                [ -n "$_gmax" ] && safe_write "$_gpu/devfreq/max_freq" "$_gmax"
            fi
        fi

        thermal_set_step 0
        return 0
    fi

    _profile_max="${CPU_MAX_PERCENT:-100}"
    # Effective ceiling = profile ceiling scaled by the thermal step.
    _eff=$(( _profile_max * _pct / 100 ))
    [ "$_eff" -lt 30 ] && _eff=30      # never strangle the device

    for _pol in $(detect_policies); do
        [ -f "$_pol/scaling_max_freq" ] || continue
        _hwmax=$(read_node "$_pol/cpuinfo_max_freq" 2>/dev/null)
        _hwmin=$(read_node "$_pol/cpuinfo_min_freq" 2>/dev/null)
        case "$_hwmax" in ''|*[!0-9]*) continue ;; esac
        case "$_hwmin" in ''|*[!0-9]*) continue ;; esac
        _span=$(( _hwmax - _hwmin ))
        _target=$(( _hwmin + _span * _eff / 100 ))
        _target=$(snap_to_available "$_pol" "$_target")
        safe_write "$_pol/scaling_max_freq" "$_target"
    done

    # Also ease the GPU ceiling at the harsher steps.
    if [ "$_step" -ge 2 ]; then
        _gpu="${GPU_PATH:-}"
        [ -n "$_gpu" ] || _gpu=$(detect_gpu_path 2>/dev/null)
        if [ -n "$_gpu" ] && [ -f "$_gpu/devfreq/max_freq" ]; then
            _list=$(read_node "$_gpu/devfreq/available_frequencies" 2>/dev/null)
            if [ -n "$_list" ]; then
                _gmax=""; _gmin=""
                for _f in $_list; do
                    case "$_f" in ''|*[!0-9]*) continue ;; esac
                    [ -z "$_gmax" ] && { _gmax="$_f"; _gmin="$_f"; continue; }
                    [ "$_f" -gt "$_gmax" ] && _gmax="$_f"
                    [ "$_f" -lt "$_gmin" ] && _gmin="$_f"
                done
                if [ -n "$_gmax" ]; then
                    _gt=$(( _gmin + (_gmax - _gmin) * _eff / 100 ))
                    safe_write "$_gpu/devfreq/max_freq" "$_gt"
                fi
            fi
        fi
    fi

    thermal_set_step "$_step"
    return 0
}

# Main thermal tick. Called from the service loop at POLL_INTERVAL.
# Gradual: moves at most one step per tick in either direction, which
# prevents oscillation between full power and heavy throttling.
thermal_tick() {
    [ "${THERMAL_PROTECTION:-1}" = "1" ] || return 0

    _tt_temp=$(thermal_read) || {
        log_debug "thermal: no readable zone, skipping"
        return 0
    }

    _tt_state=$(thermal_classify "$_tt_temp")
    _tt_prev=$(thermal_get_state)
    _tt_step=$(thermal_get_step)
    _tt_new="$_tt_step"

    case "$_tt_state" in
        CRITICAL) _tt_new=3 ;;                                     # drop hard, immediately
        HOT)      [ "$_tt_step" -lt 3 ] && _tt_new=$(( _tt_step + 1 )) || _tt_new="$_tt_step" ;;
        WARM)     [ "$_tt_step" -lt 1 ] && _tt_new=1 || _tt_new="$_tt_step" ;;
        NORMAL)   [ "$_tt_step" -gt 0 ] && _tt_new=$(( _tt_step - 1 )) || _tt_new=0 ;;
    esac

    # Record the state transition BEFORE acting, so the log reads in
    # causal order when someone is debugging a throttling complaint.
    if [ "$_tt_state" != "$_tt_prev" ]; then
        printf '%s' "$_tt_state" >"$HPC_THERMAL_STATE" 2>/dev/null
        log_info "thermal state: $_tt_prev -> $_tt_state (${_tt_temp}C)"
    fi

    if [ "$_tt_new" != "$_tt_step" ]; then
        log_info "thermal: ${_tt_temp}C state=$_tt_state step ${_tt_step}->${_tt_new}"
        thermal_apply_step "$_tt_new"
    fi

    return 0
}
