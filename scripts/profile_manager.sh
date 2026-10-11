#!/system/bin/sh
# Hamedis Performance Core (HPC) - profile application engine
#
# Translates percentage-based profile hints into concrete, verified
# sysfs writes. Every write goes through safe_write(), so every change
# is backed up and reversible, and missing nodes are skipped.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_MODDIR="${HPC_MODDIR:-/data/adb/modules/hamedis_performance_core}"
HPC_CURRENT="$HPC_STATE/current_profile"
HPC_PREVIOUS="$HPC_STATE/previous_profile"

# ----------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------

# percent_of TOTAL PERCENT -> integer, no floating point in POSIX sh
percent_of() {
    _pct_total="$1"; _pct_pc="$2"
    case "$_pct_total" in ''|*[!0-9]*) return 1 ;; esac
    case "$_pct_pc"    in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' $(( _pct_total * _pct_pc / 100 ))
}

# Snap a frequency to the nearest AVAILABLE step, when the kernel
# publishes a list. Writing an unlisted value is silently rejected by
# some kernels, so this materially improves hit rate.
snap_to_available() {
    _pol="$1"; _want="$2"
    _list=$(read_node "$_pol/scaling_available_frequencies" 2>/dev/null)
    if [ -z "$_list" ]; then
        printf '%s' "$_want"
        return 0
    fi
    _best=""
    _bestd=""
    for _f in $_list; do
        case "$_f" in ''|*[!0-9]*) continue ;; esac
        if [ "$_f" -ge "$_want" ]; then _d=$(( _f - _want )); else _d=$(( _want - _f )); fi
        if [ -z "$_bestd" ] || [ "$_d" -lt "$_bestd" ]; then
            _bestd="$_d"; _best="$_f"
        fi
    done
    [ -n "$_best" ] && printf '%s' "$_best" || printf '%s' "$_want"
}

profile_file() {
    _p="$1"
    for _d in "$HPC_DATA/profiles" "$HPC_MODDIR/config/profiles"; do
        [ -f "$_d/$_p.conf" ] && { printf '%s' "$_d/$_p.conf"; return 0; }
    done
    return 1
}

current_profile() {
    [ -f "$HPC_CURRENT" ] && read_node "$HPC_CURRENT" || printf 'unknown'
}

# ----------------------------------------------------------------------
# CPU
# ----------------------------------------------------------------------

apply_cpu() {
    _gov=""
    if [ -n "${CPU_GOVERNOR_PREF:-}" ]; then
        _gov=$(pick_governor "$CPU_GOVERNOR_PREF" 2>/dev/null)
    fi

    for _pol in $(detect_policies); do
        [ -d "$_pol" ] || continue

        # --- governor
        if [ -n "$_gov" ] && [ -f "$_pol/scaling_governor" ]; then
            safe_write "$_pol/scaling_governor" "$_gov"
        fi

        # --- frequency window, derived from this policy's own hardware limits
        _hwmax=$(read_node "$_pol/cpuinfo_max_freq" 2>/dev/null)
        _hwmin=$(read_node "$_pol/cpuinfo_min_freq" 2>/dev/null)

        if [ -n "$_hwmax" ] && [ -n "$_hwmin" ]; then
            case "$_hwmax$_hwmin" in
                ''|*[!0-9]*) _hwmax=""; _hwmin="" ;;
            esac
        fi

        if [ -n "$_hwmax" ] && [ -n "$_hwmin" ]; then
            _span=$(( _hwmax - _hwmin ))

            if [ -n "${CPU_MAX_PERCENT:-}" ] && [ -f "$_pol/scaling_max_freq" ]; then
                if [ "$CPU_MAX_PERCENT" -ge 100 ]; then
                    _tmax="$_hwmax"
                else
                    _tmax=$(( _hwmin + _span * CPU_MAX_PERCENT / 100 ))
                    _tmax=$(snap_to_available "$_pol" "$_tmax")
                fi
                safe_write "$_pol/scaling_max_freq" "$_tmax"
            fi

            if [ -n "${CPU_MIN_PERCENT:-}" ] && [ -f "$_pol/scaling_min_freq" ]; then
                if [ "$CPU_MIN_PERCENT" -le 0 ]; then
                    _tmin="$_hwmin"
                else
                    _tmin=$(( _hwmin + _span * CPU_MIN_PERCENT / 100 ))
                    _tmin=$(snap_to_available "$_pol" "$_tmin")
                fi
                # Never let the floor exceed the ceiling.
                _curmax=$(read_node "$_pol/scaling_max_freq" 2>/dev/null)
                if [ -n "$_curmax" ] && [ "$_tmin" -gt "$_curmax" ] 2>/dev/null; then
                    _tmin="$_curmax"
                fi

                # scaling_min_freq is commonly held above our request by
                # something else: a vendor boost driver, the ROM's own
                # game tuner, or a thermal/perf HAL raising the floor
                # during load. That is not our write failing - it is
                # another owner winning, and it is usually harmless
                # (a HIGHER floor than asked still satisfies the intent).
                # Verify only the direction we care about.
                safe_write "$_pol/scaling_min_freq" "$_tmin" --no-verify
                _gotmin=$(read_node "$_pol/scaling_min_freq" 2>/dev/null)
                if [ -n "$_gotmin" ] && [ "$_gotmin" -lt "$_tmin" ] 2>/dev/null; then
                    log_warn "cpu floor lower than requested on ${_pol##*/}: wanted=$_tmin got=$_gotmin"
                elif [ -n "$_gotmin" ] && [ "$_gotmin" -gt "$_tmin" ] 2>/dev/null; then
                    log_debug "cpu floor held higher by another owner on ${_pol##*/}: $_gotmin"
                fi
            fi
        fi

        # --- governor tunables, only where the governor exposes them
        _gd="$_pol/${_gov:-schedutil}"
        if [ -d "$_gd" ]; then
            [ -n "${CPU_UP_RATE_LIMIT_US:-}" ] && \
                safe_write "$_gd/up_rate_limit_us" "$CPU_UP_RATE_LIMIT_US"
            [ -n "${CPU_DOWN_RATE_LIMIT_US:-}" ] && \
                safe_write "$_gd/down_rate_limit_us" "$CPU_DOWN_RATE_LIMIT_US"
            [ -n "${CPU_HISPEED_LOAD:-}" ] && \
                safe_write "$_gd/hispeed_load" "$CPU_HISPEED_LOAD"
        fi
    done
    return 0
}

# ----------------------------------------------------------------------
# GPU
# ----------------------------------------------------------------------

apply_gpu() {
    _gpu="${GPU_PATH:-}"
    [ -n "$_gpu" ] || _gpu=$(detect_gpu_path 2>/dev/null)
    if [ -z "$_gpu" ] || [ ! -d "$_gpu" ]; then
        log_debug "gpu: no interface, skipping"
        return 0
    fi

    _df="$_gpu/devfreq"

    # --- governor
    if [ -n "${GPU_GOVERNOR_PREF:-}" ] && [ -f "$_df/governor" ]; then
        _avail=$(read_node "$_df/available_governors" 2>/dev/null)
        _pick=""
        for _g in $GPU_GOVERNOR_PREF; do
            if [ -z "$_avail" ]; then
                _pick="$_g"; break
            fi
            for _a in $_avail; do
                [ "$_g" = "$_a" ] && { _pick="$_g"; break; }
            done
            [ -n "$_pick" ] && break
        done
        [ -n "$_pick" ] && safe_write "$_df/governor" "$_pick"
    fi

    # --- frequency window from available_frequencies when published
    _list=$(read_node "$_df/available_frequencies" 2>/dev/null)
    [ -n "$_list" ] || _list=$(read_node "$_gpu/gpu_available_frequencies" 2>/dev/null)

    if [ -n "$_list" ]; then
        _gmax=""; _gmin=""
        for _f in $_list; do
            case "$_f" in ''|*[!0-9]*) continue ;; esac
            [ -z "$_gmax" ] && { _gmax="$_f"; _gmin="$_f"; continue; }
            [ "$_f" -gt "$_gmax" ] && _gmax="$_f"
            [ "$_f" -lt "$_gmin" ] && _gmin="$_f"
        done

        if [ -n "$_gmax" ] && [ -n "$_gmin" ]; then
            _span=$(( _gmax - _gmin ))
            if [ -n "${GPU_MAX_PERCENT:-}" ] && [ -f "$_df/max_freq" ]; then
                if [ "$GPU_MAX_PERCENT" -ge 100 ]; then _gtarget="$_gmax"
                else _gtarget=$(( _gmin + _span * GPU_MAX_PERCENT / 100 )); fi
                safe_write "$_df/max_freq" "$_gtarget"
            fi
            if [ -n "${GPU_MIN_PERCENT:-}" ] && [ -f "$_df/min_freq" ]; then
                if [ "$GPU_MIN_PERCENT" -le 0 ]; then _gtarget="$_gmin"
                else _gtarget=$(( _gmin + _span * GPU_MIN_PERCENT / 100 )); fi
                safe_write "$_df/min_freq" "$_gtarget"
            fi
        fi
    fi

    # --- Adreno-specific extras, each guarded
    # idle_timer: the Adreno driver silently clamps this to its own
    # supported range (commonly 80 ms with msm-adreno-tz). Asking for 200
    # and reading back 80 is the driver enforcing a limit, not a failure -
    # so write without verification and note the clamp once, rather than
    # emitting a WARN on every single profile change.
    if [ -n "${GPU_IDLE_TIMER:-}" ] && [ -f "$_gpu/idle_timer" ]; then
        _gpu_it_before=$(read_node "$_gpu/idle_timer" 2>/dev/null)
        safe_write "$_gpu/idle_timer" "$GPU_IDLE_TIMER" --no-verify
        _gpu_it_after=$(read_node "$_gpu/idle_timer" 2>/dev/null)
        if [ "$_gpu_it_after" != "$GPU_IDLE_TIMER" ]; then
            if [ "$_gpu_it_after" = "$_gpu_it_before" ]; then
                log_unsupported "$_gpu/idle_timer" "driver holds it at $_gpu_it_after"
            else
                log_debug "gpu idle_timer clamped: asked $GPU_IDLE_TIMER got $_gpu_it_after"
            fi
        fi
    fi

    # Throttling is only ever written as 1 (enabled). Refuse 0 outright:
    # disabling kernel GPU thermal throttling is exactly what this module
    # promises never to do.
    if [ -f "$_gpu/throttling" ]; then
        if [ "${GPU_THROTTLING:-1}" = "0" ]; then
            log_warn "refusing to disable GPU throttling (safety policy)"
        fi
        safe_write "$_gpu/throttling" 1
    fi

    [ -n "${GPU_FORCE_CLK:-}" ] && [ -f "$_gpu/force_clk_on" ] && \
        safe_write "$_gpu/force_clk_on" "$GPU_FORCE_CLK"

    return 0
}

# ----------------------------------------------------------------------
# Scheduler
# ----------------------------------------------------------------------

apply_sched() {
    # NOTE: use a distinctive variable name. POSIX sh has no local scope by
    # default, and short names like _k collide with loop accumulators in
    # detector.sh, silently corrupting every path built from them.
    _sched_dir=/proc/sys/kernel

    [ -n "${SCHED_MIN_GRANULARITY_NS:-}" ] && \
        safe_write "$_sched_dir/sched_min_granularity_ns" "$SCHED_MIN_GRANULARITY_NS"
    [ -n "${SCHED_WAKEUP_GRANULARITY_NS:-}" ] && \
        safe_write "$_sched_dir/sched_wakeup_granularity_ns" "$SCHED_WAKEUP_GRANULARITY_NS"
    [ -n "${SCHED_MIGRATION_COST_NS:-}" ] && \
        safe_write "$_sched_dir/sched_migration_cost_ns" "$SCHED_MIGRATION_COST_NS"
    [ -n "${SCHED_LATENCY_NS:-}" ] && \
        safe_write "$_sched_dir/sched_latency_ns" "$SCHED_LATENCY_NS"
    [ -n "${SCHED_CHILD_RUNS_FIRST:-}" ] && \
        safe_write "$_sched_dir/sched_child_runs_first" "$SCHED_CHILD_RUNS_FIRST"
    [ -n "${SCHED_AUTOGROUP:-}" ] && \
        safe_write "$_sched_dir/sched_autogroup_enabled" "$SCHED_AUTOGROUP"
    return 0
}

# ----------------------------------------------------------------------
# Profile application
# ----------------------------------------------------------------------

apply_profile() {
    _name="$1"
    _quiet="${2:-}"

    _f=$(profile_file "$_name") || {
        log_error "profile not found: $_name"
        return 1
    }

    # HARDENING (v1.8.1): a profile file is sourced, so it executes as
    # shell code. That is fine for the files we ship, but a profile
    # copied from elsewhere could carry arbitrary commands. Rather than
    # replace the parser wholesale - which risks misreading a value and
    # breaking a working setup - refuse to source a file that contains
    # anything other than comments, blanks and KEY=VALUE lines.
    if grep -qvE '^[[:space:]]*(#|$|[A-Za-z_][A-Za-z0-9_]*=)' "$_f" 2>/dev/null; then
        log_error "profile $_name contains non-assignment lines, refusing to load"
        return 1
    fi

    # shellcheck source=/dev/null
    . "$_f"

    log_info "applying profile: $_name"

    apply_cpu
    apply_gpu
    apply_sched
    # RAM tuning lives in ram_manager.sh; call if available.
    command -v apply_ram >/dev/null 2>&1 && apply_ram
    command -v apply_graphics >/dev/null 2>&1 && apply_graphics
    command -v apply_kernel  >/dev/null 2>&1 && apply_kernel

    _prev=$(current_profile)
    [ "$_prev" != "$_name" ] && printf '%s' "$_prev" >"$HPC_PREVIOUS" 2>/dev/null
    printf '%s' "$_name" >"$HPC_CURRENT" 2>/dev/null

    [ "$_quiet" = "quiet" ] || log_info "profile active: $_name"
    return 0
}

# Re-apply the profile that is already current (used after thermal recovery).
reapply_current() {
    _c=$(current_profile)
    [ "$_c" = "unknown" ] && _c="${MODE:-balanced}"
    apply_profile "$_c" quiet
}
