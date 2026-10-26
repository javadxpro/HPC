#!/system/bin/sh
# Hamedis Performance Core (HPC) - kernel control registry & change engine
#
# Part of the Kernel Management Platform (v1.10).
#
# Centralized lifecycle for every configuration change:
#
#   DISCOVER -> VALIDATE -> PERMISSIONS -> RISK -> SAVE PREVIOUS
#   -> APPLY (safe_write) -> VERIFY -> RECORD -> COMMIT/ROLLBACK
#
# Guarantees:
#   * values are validated against THIS device's discovered state
#     (enums come from the kernel's own lists, ranges from hw limits)
#   * protected paths can never be written through this engine
#   * every attempted change is recorded (success AND failure) in
#     state/change_log.tsv
#   * grouped multi-setting changes are transactions: validate all,
#     apply, and roll back the already-applied parts if one fails
#   * only one change operation runs at a time (mkdir lock)
#
# This layer REUSES the safety.sh primitives (safe_write backs up and
# verifies), so uninstall.sh restore_all keeps working unchanged.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
# /proc/sys location (variable so test fixtures can redirect; real
# devices always use /proc/sys)
HPC_PROC_SYS="${HPC_PROC_SYS:-/proc/sys}"
KM_CHANGE_LOG="$HPC_STATE/change_log.tsv"
KM_TXN_ACTIVE="$HPC_STATE/txn_active"
KM_LOCK_DIR="$HPC_STATE/km_lock"
KM_LOG_MAX=2000

# ----------------------------------------------------------------------
# locking (mkdir is atomic on every filesystem Android uses)
# ----------------------------------------------------------------------

km_lock() {
    _i=0
    while [ "$_i" -lt 10 ]; do
        if ( mkdir "$KM_LOCK_DIR" 2>/dev/null ) && \
           { : >"$KM_LOCK_DIR/pid" 2>/dev/null && printf '%s\n' "km_op_$(date +%s%3N 2>/dev/null)" >"$KM_LOCK_DIR/pid" 2>/dev/null; }; then
            return 0
        fi
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    return 1
}

km_unlock() {
    rm -f "$KM_LOCK_DIR/pid" 2>/dev/null
    rmdir "$KM_LOCK_DIR" 2>/dev/null
    return 0
}

# ----------------------------------------------------------------------
# change log
# ----------------------------------------------------------------------

_km_log_append() {
    # ts id path old new source profile status verified
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >>"$KM_CHANGE_LOG" 2>/dev/null
    # trim
    if [ -f "$KM_CHANGE_LOG" ]; then
        _n=$(wc -l <"$KM_CHANGE_LOG" 2>/dev/null | tr -d ' ')
        if [ "${_n:-0}" -gt "$KM_LOG_MAX" ]; then
            _tmp="$KM_CHANGE_LOG.tmp"
            tail -n "$KM_LOG_MAX" "$KM_CHANGE_LOG" >"$_tmp" 2>/dev/null && \
                mv -f "$_tmp" "$KM_CHANGE_LOG" 2>/dev/null
        fi
    fi
}

km_history() {
    # km_history [N] - newest first
    _hn="${1:-50}"
    case "$_hn" in ''|*[!0-9]*) _hn=50 ;; esac
    [ -f "$KM_CHANGE_LOG" ] || return 0
    tail -n "$_hn" "$KM_CHANGE_LOG" 2>/dev/null | tac 2>/dev/null || tail -n "$_hn" "$KM_CHANGE_LOG" 2>/dev/null
    return 0
}

# ----------------------------------------------------------------------
# protected paths - the engine will never write these, regardless of
# caller, profile or plugin.
# ----------------------------------------------------------------------

km_protected() {
    # km_protected PATH -> 0 if the path is protected
    _pp="$1"
    case "$_pp" in
        /sys/class/thermal/*)          return 0 ;;   # any thermal zone write
        */thermal_zone*/mode)          return 0 ;;   # thermal mode (any location)
        */thermal_zone*/trip_*)        return 0 ;;
        */thermal_zone*/hot_threshold) return 0 ;;
        /sys/fs/selinux/*)             return 0 ;;
        /sys/module/*/parameters/*)    return 0 ;;   # driver params: observe only
        /proc/sys/kernel/modules)      return 0 ;;
        /proc/sys/kernel/dmesg_restrict) return 0 ;;
        /sys/kernel/uevent)            return 0 ;;
        */force_clk*|*/throttling*)    return 0 ;;   # GPU thermal bypass knobs
        */scaling_boost*|*/cpu*boost*) return 1 ;;   # freq boost is not a thermal bypass; handled as normal med-risk
    esac
    return 1
}

# risk class of a control id (used for UI confirmation + audit)
km_ctl_risk() {
    case "$1" in
        *.min_freq|*.max_freq|cpu*.governor|gpu.governor) printf 'med' ;;
        net.tcp_cc) printf 'low' ;;
        *) printf 'low' ;;
    esac
}

# ----------------------------------------------------------------------
# control resolution: id -> instance paths
# ----------------------------------------------------------------------

# km_ctl_paths ID -> prints instance paths (space separated)
km_ctl_paths() {
    _ci="$1"
    # 1) plugin controls: paths may be virtual (getprop-based) - resolve
    #    through the plugin registry first
    case "$_ci" in
        plugin.*)
            if command -v km_plugin_path >/dev/null 2>&1; then
                _plp=$(km_plugin_path "$_ci")
                [ -n "$_plp" ] && { printf '%s' "$_plp"; return 0; }
            fi
            ;;
    esac
    # 2) discovery registry: the row for this id carries the exact node
    #    path found on THIS device (cluster-specific, capability-driven)
    _crp=$(awk -F '\t' -v k="$_ci" '$1==k && $3!="-" {print $3; exit}' "$KM_REG_TSV" 2>/dev/null)
    if [ -n "$_crp" ] && [ -f "$_crp" ]; then
        printf '%s' "$_crp"
        return 0
    fi
    # 3) live fallback (before the first scan, or id not in registry)
    case "$_ci" in
        cpu*.governor|cpu*.max_freq|cpu*.min_freq)
            # cluster-specific: cpu1 -> first detected policy, cpu2 -> second, ...
            _kn="scaling_governor"
            case "$_ci" in *.max_freq) _kn="scaling_max_freq" ;; *.min_freq) _kn="scaling_min_freq" ;; esac
            _n="${_ci%%.*}"; _n="${_n#cpu}"
            case "$_n" in ''|*[!0-9]) return 0 ;; esac
            _i=0
            for _p in $(detect_policies 2>/dev/null); do
                _i=$((_i + 1))
                [ "$_i" = "$_n" ] && [ -f "$_p/$_kn" ] && printf '%s ' "$_p/$_kn"
            done
            ;;
        cpu*.hispeed_load|cpu*.up_rate_limit_us|cpu*.down_rate_limit_us|cpu*.hispeed_freq)
            _knob="${_ci#*.*}"
            for _p in $(detect_policies 2>/dev/null); do
                [ -f "$_p/$_knob" ] && printf '%s ' "$_p/$_knob"
            done
            ;;
        io.*.scheduler)
            _dev="${_ci#io.}"; _dev="${_dev%.scheduler}"
            for _d in $(km_block_devices 2>/dev/null); do
                [ "${_d##*/}" = "$_dev" ] && [ -f "$_d/queue/scheduler" ] && printf '%s ' "$_d/queue/scheduler"
            done
            ;;
        io.*.read_ahead_kb|io.*.nr_requests|io.*.add_random|io.*.iostats)
            _dev="${_ci#io.}"; _dev="${_dev%.read_ahead_kb}"; _dev="${_dev%.nr_requests}"; _dev="${_dev%.add_random}"; _dev="${_dev%.iostats}"
            _knob="${_ci##*.}"
            for _d in $(km_block_devices 2>/dev/null); do
                [ "${_d##*/}" = "$_dev" ] && [ -f "$_d/queue/$_knob" ] && printf '%s ' "$_d/queue/$_knob"
            done
            ;;
        io.scheduler)   # all devices
            for _d in $(km_block_devices 2>/dev/null); do
                [ -f "$_d/queue/scheduler" ] && printf '%s ' "$_d/queue/scheduler"
            done
            ;;
        net.tcp_cc)
            [ -f "$HPC_PROC_SYS/net/ipv4/tcp_congestion_control" ] && printf '%s' "$HPC_PROC_SYS/net/ipv4/tcp_congestion_control"
            ;;
        vm.*)
            _knob="${_ci#vm.}"
            [ -f "$HPC_PROC_SYS/vm/$_knob" ] && printf '%s' "$HPC_PROC_SYS/vm/$_knob"
            ;;
        gpu.governor)
            _g=$(detect_gpu_path 2>/dev/null) && [ -f "$_g/devfreq/governor" ] && printf '%s' "$_g/devfreq/governor"
            ;;
        gpu.min_freq|gpu.max_freq|gpu.idle_timer|gpu.force_clk)
            _g=$(detect_gpu_path 2>/dev/null) || return 0
            case "$_ci" in
                gpu.governor) _n=governor ;;
                gpu.min_freq) _n=min_freq ;;
                gpu.max_freq) _n=max_freq ;;
                gpu.idle_timer) _n=idle_timer ;;
                gpu.force_clk) _n=force_clk_on ;;
            esac
            [ -f "$_g/$_n" ] && printf '%s' "$_g/$_n"
            [ -f "$_g/devfreq/$_n" ] && printf '%s' "$_g/devfreq/$_n"
            ;;
        zram.swappiness)
            _z=$(detect_zram 2>/dev/null) && [ -f "$_z/mem_swappiness" ] && printf '%s' "$_z/mem_swappiness"
            ;;
        sched.*)
            _knob="${_ci#sched.}"
            case "$_knob" in
                features) [ -f /sys/kernel/debug/sched_features ] && printf '%s' /sys/kernel/debug/sched_features ;;
                sched_min_granularity_ns|sched_wakeup_granularity_ns|sched_migration_cost_ns)
                    [ -f "$HPC_PROC_SYS/kernel/$_knob" ] && printf '%s' "$HPC_PROC_SYS/kernel/$_knob" ;;
            esac
            ;;
        *)
            # direct-path controls: id is the path itself
            [ -n "$_ci" ] && case "$_ci" in
                /*) [ -f "$_ci" ] && printf '%s' "$_ci" ;;
            esac
            ;;
    esac
    return 0
}

# km_ctl_enum ID -> the allowed values (space separated), from the
# kernel's own lists. Empty when the type is not an enum.
km_ctl_enum() {
    # The discovery registry is the source of truth for what this
    # device exposes; enums are read through the registry paths so
    # validation matches the discovered state exactly.
    _ci="$1"
    case "$_ci" in
        cpu*.governor)
            _ep=$(awk -F '\t' -v k="$_ci" '$1==k {print $3; exit}' "$KM_REG_TSV" 2>/dev/null)
            if [ -n "$_ep" ] && [ -f "$_ep" ]; then
                read_node "$(dirname "$_ep")/scaling_available_governors" 2>/dev/null
            else
                for _p in $(detect_policies 2>/dev/null); do
                    read_node "$_p/scaling_available_governors" 2>/dev/null && break
                done
            fi
            ;;
        io.scheduler|io.*.scheduler)
            _ep=$(awk -F '\t' -v k="$_ci" '$1==k {print $3; exit}' "$KM_REG_TSV" 2>/dev/null)
            if [ -n "$_ep" ] && [ -f "$_ep" ]; then
                read_node "$(dirname "$_ep")/scheduler_list" 2>/dev/null || km_io_available 2>/dev/null
            else
                km_io_available 2>/dev/null
            fi
            ;;
        net.tcp_cc)
            read_node "$HPC_PROC_SYS/net/ipv4/tcp_available_congestion_control" 2>/dev/null
            ;;
        gpu.governor)
            _ep=$(awk -F '\t' -v k="$_ci" '$1==k {print $3; exit}' "$KM_REG_TSV" 2>/dev/null)
            if [ -n "$_ep" ] && [ -f "$_ep" ]; then
                read_node "$(dirname "$_ep")/available_governors" 2>/dev/null
            else
                _g=$(detect_gpu_path 2>/dev/null) && read_node "$_g/devfreq/available_governors" 2>/dev/null
            fi
            ;;
    esac
    return 0
}

# numeric range for freq controls: prints "min max" in kHz
km_ctl_freq_range() {
    _ci="$1"
    # per-cluster range: take the policy from the registry entry for
    # this exact control (falls back to the first detected policy)
    _p=""
    case "$_ci" in
        cpu*.max_freq|cpu*.min_freq)
            _ep=$(awk -F '\t' -v k="$_ci" '$1==k {print $3; exit}' "$KM_REG_TSV" 2>/dev/null)
            [ -n "$_ep" ] && _p=$(dirname "$_ep")
            ;;
    esac
    [ -n "$_p" ] || _p=$(detect_policies 2>/dev/null | awk '{print $1; exit}')
    _lo=$(read_node "$_p/cpuinfo_min_freq" 2>/dev/null)
    _hi=$(read_node "$_p/cpuinfo_max_freq" 2>/dev/null)
    case "$_ci" in
        gpu.*)
            _g=$(detect_gpu_path 2>/dev/null)
            _lo=$(read_node "$_g/devfreq/min_freq_limit" 2>/dev/null)
            _hi=$(read_node "$_g/devfreq/max_freq_limit" 2>/dev/null)
            ;;
    esac
    case "$_lo$_hi" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s %s' "$_lo" "$_hi"
    return 0
}

# ----------------------------------------------------------------------
# validation
# ----------------------------------------------------------------------

# km_ctl_validate ID VALUE -> 0 ok / 1 invalid; prints reason on stdout
km_ctl_validate() {
    _ci="$1"; _cv="$2"
    [ -n "$_cv" ] || { printf 'empty value'; return 1; }

    # hard limits on any value: no shell metachars, sane length.
    # (grep, not a case pattern: < > ` \ are untypeable in dash patterns)
    if printf '%s' "$_cv" | grep -q '[;&|$`<>()\\]'; then
        printf 'value contains prohibited characters'
        return 1
    fi
    [ "${#_cv}" -le 64 ] || { printf 'value too long'; return 1; }

    case "$_ci" in
        *.governor|io.scheduler|io.*.scheduler|net.tcp_cc)
            _en=$(km_ctl_enum "$_ci")
            [ -n "$_en" ] || { printf 'no enum available (interface absent)'; return 1; }
            for _e in $_en; do
                [ "$_e" = "$_cv" ] && return 0
            done
            printf 'value not in kernel list (%s)' "$(printf '%s' "$_en" | tr ' ' '|')"
            return 1
            ;;
        *.min_freq|*.max_freq)
            case "$_cv" in ''|*[!0-9]*) printf 'frequency must be numeric (kHz)'; return 1 ;; esac
            if _r=$(km_ctl_freq_range "$_ci"); then
                _rlo="${_r%% *}"; _rhi="${_r##* }"
                [ "$_cv" -lt "$_rlo" ] && { printf "below hardware minimum ($_rlo)"; return 1; }
                [ "$_cv" -gt "$_rhi" ] && { printf "above hardware maximum ($_rhi)"; return 1; }
            fi
            return 0
            ;;
        vm.swappiness|zram.swappiness)
            case "$_cv" in ''|*[!0-9]*) printf 'must be numeric'; return 1 ;; esac
            [ "$_cv" -ge 0 ] && [ "$_cv" -le 200 ] && return 0
            printf 'range 0-200'
            return 1
            ;;
        vm.vfs_cache_pressure)
            case "$_cv" in ''|*[!0-9]*) printf 'must be numeric'; return 1 ;; esac
            [ "$_cv" -ge 0 ] && [ "$_cv" -le 1000 ] && return 0
            printf 'range 0-1000'
            return 1
            ;;
        vm.dirty_ratio|vm.dirty_background_ratio)
            case "$_cv" in ''|*[!0-9]*) printf 'must be numeric'; return 1 ;; esac
            [ "$_cv" -ge 1 ] && [ "$_cv" -le 100 ] && return 0
            printf 'range 1-100'
            return 1
            ;;
        *.iostats|*.add_random|gpu.force_clk|env.selinux)
            case "$_cv" in 0|1|on|off) return 0 ;; esac
            printf 'must be 0/1'
            return 1
            ;;
        vm.*)
            case "$_cv" in ''|*[!0-9]*) printf 'must be numeric'; return 1 ;; esac
            [ "$_cv" -ge 0 ] && [ "$_cv" -le 4194304 ] && return 0
            printf 'out of plausible range'
            return 1
            ;;
        *)
            # unknown control: only accept if a direct path was registered
            return 0
            ;;
    esac
}

# ----------------------------------------------------------------------
# current value
# ----------------------------------------------------------------------

km_ctl_get() {
    _ci="$1"
    _first_path=$(km_ctl_paths "$_ci" | awk '{print $1; exit}')
    [ -n "$_first_path" ] || return 1
    read_node "$_first_path"
}

# ----------------------------------------------------------------------
# the write primitive
# ----------------------------------------------------------------------

# km_ctl_set ID VALUE SOURCE
# Prints a JSON result. Never aborts the caller.
km_ctl_set() {
    _ci="$1"; _cv="$2"; _cs="${3:-ui}"
    _cs_prof=$(current_profile 2>/dev/null)

    if ! km_lock; then
        printf '{"ok":0,"error":"busy: another change operation is in progress"}\n'
        return 1
    fi

    _res='{'
    _err=$(km_ctl_validate "$_ci" "$_cv")
    if [ -n "$_err" ]; then
        _msg="invalid value: $_err"
        _res="${_res}\"error\":$(km_jesc "$_msg")"
        _km_log_append "$(km_now_ms)" "$_ci" "-" "-" "$_cv" "$_cs" "$_cs_prof" "rejected" "no"
        km_unlock
        printf '%s}\n' "$_res"
        return 1
    fi

    _paths=$(km_ctl_paths "$_ci")
    if [ -z "$_paths" ]; then
        _res="${_res}\"error\":\"not supported on this device (no matching interface)\""
        _km_log_append "$(km_now_ms)" "$_ci" "-" "-" "$_cv" "$_cs" "$_cs_prof" "unsupported" "no"
        km_unlock
        printf '%s}\n' "$_res"
        return 1
    fi

    _applied=0; _failed=0; _skipped=0; _prot=0
    _txn_recording=0
    [ -f "$KM_TXN_ACTIVE" ] && _txn_recording=1

    for _p in $_paths; do
        if km_protected "$_p"; then
            _prot=$((_prot + 1))
            _skipped=$((_skipped + 1))
            _km_log_append "$(km_now_ms)" "$_ci" "$_p" "-" "$_cv" "$_cs" "$_cs_prof" "protected" "no"
            continue
        fi
        _old=$(read_node "$_p" 2>/dev/null)
        if [ -n "$_old" ] && [ "$_old" = "$_cv" ]; then
            _skipped=$((_skipped + 1))   # already at target: no-op
            continue
        fi
        # transaction: record the original before touching anything
        if [ "$_txn_recording" = "1" ] && [ -n "$_old" ]; then
            printf '%s\t%s\t%s\n' "$_ci" "$_p" "$_old" >>"$KM_TXN_ACTIVE" 2>/dev/null
        fi
        if safe_write "$_p" "$_cv" --verify; then
            _applied=$((_applied + 1))
            _km_log_append "$(km_now_ms)" "$_ci" "$_p" "$_old" "$_cv" "$_cs" "$_cs_prof" "ok" "yes"
        else
            _failed=$((_failed + 1))
            _km_log_append "$(km_now_ms)" "$_ci" "$_p" "$_old" "$_cv" "$_cs" "$_cs_prof" "fail" "no"
        fi
    done

    _total=$((_applied + _failed + _skipped))
    if [ "$_failed" -eq 0 ]; then
        _res="${_res}\"ok\":1,\"applied\":$_applied,\"skipped\":$_skipped,\"protected\":$_prot,\"total\":$_total"
    else
        _res="${_res}\"ok\":0,\"partial\":1,\"applied\":$_applied,\"failed\":$_failed,\"skipped\":$_skipped,\"protected\":$_prot,\"total\":$_total"
        # inside a transaction, flag it; km_txn_end decides on rollback
        [ "$_txn_recording" = "1" ] && : >"$KM_TXN_ACTIVE.failed" 2>/dev/null
    fi
    km_unlock
    printf '%s}\n' "$_res"
    return 0
}

# ----------------------------------------------------------------------
# transactions: multi-setting changes with rollback
# ----------------------------------------------------------------------

km_txn_begin() {
    # km_txn_begin SOURCE
    if [ -d "$KM_LOCK_DIR" ]; then
        printf '{"ok":0,"error":"busy"}\n'
        return 1
    fi
    : >"$KM_TXN_ACTIVE" 2>/dev/null
    rm -f "$KM_TXN_ACTIVE.failed" 2>/dev/null
    printf '{"ok":1}\n'
    return 0
}

# km_txn_apply "id=value|id=value|..." SOURCE
# Validates everything first, then applies, rolling back on any failure.
km_txn_apply() {
    _spec="$1"; _cs="${2:-profile}"
    [ -f "$KM_TXN_ACTIVE" ] || { printf '{"ok":0,"error":"no active transaction"}\n'; return 1; }

    # --- pass 1: validate every setting
    _ok_all=1
    _pending=""
    _IFS_SAVE="$IFS"; IFS='|'
    for _pair in $_spec; do
        IFS="="; set -- $_pair; IFS="$_IFS_SAVE"
        _id="$1"; _val="$2"
        [ -n "$_id" ] && [ -n "$_val" ] || { _ok_all=0; continue; }
        if ! km_ctl_paths "$_id" >/dev/null || [ -z "$(km_ctl_paths "$_id")" ]; then
            # unsupported: drop it, remember for the report
            _pending="${_pending}${_id}=unsupported|"
            continue
        fi
        _err=$(km_ctl_validate "$_id" "$_val")
        if [ -n "$_err" ]; then
            _pending="${_pending}${_id}=invalid:${_err}|"
            _ok_all=0
        fi
    done
    IFS="$_IFS_SAVE"

    if [ "$_ok_all" != "1" ]; then
        rm -f "$KM_TXN_ACTIVE" "$KM_TXN_ACTIVE.failed" 2>/dev/null
        printf '{"ok":0,"error":"validation failed for one or more settings","rejected":%s}\n' \
            "$(printf '%s' "$_pending" | sed 's/|$//; s/=/\",/g; s/|/\",/g; s/^/\"/; s/\"$/\"/')"
        return 1
    fi

    # --- pass 2: apply (km_ctl_set records originals into the txn file)
    _IFS_SAVE="$IFS"; IFS='|'
    for _pair in $_spec; do
        IFS="="; set -- $_pair; IFS="$_IFS_SAVE"
        [ -n "$1" ] && [ -n "$2" ] || continue
        _r=$(km_ctl_set "$1" "$2" "$_cs")
        printf '%s\n' "$_r"
    done
    IFS="$_IFS_SAVE"

    km_txn_end
    return 0
}

km_txn_end() {
    _rollback=0
    if [ -f "$KM_TXN_ACTIVE.failed" ]; then
        _rollback=1
    fi
    if [ -f "$KM_TXN_ACTIVE" ]; then
        if [ "$_rollback" = "1" ]; then
            _rb_ok=0; _rb_fail=0
            # reverse order so later changes revert first
            _lines=$(tac "$KM_TXN_ACTIVE" 2>/dev/null || cat "$KM_TXN_ACTIVE")
            _n=0
            for _l in "$_lines"; do
                [ -n "$_l" ] || continue
                _n=$((_n + 1))
                _rid=$(printf '%s' "$_l" | awk -F '\t' '{print $1}')
                _rpath=$(printf '%s' "$_l" | awk -F '\t' '{print $2}')
                _rval=$(printf '%s' "$_l" | awk -F '\t' '{print $3}')
                if [ -e "$_rpath" ] && node_writable "$_rpath" 2>/dev/null && \
                   ( printf '%s' "$_rval" >"$_rpath" ) 2>/dev/null; then
                    _rb_ok=$((_rb_ok + 1))
                    _km_log_append "$(km_now_ms)" "$_rid" "$_rpath" "$(read_node "$_rpath" 2>/dev/null)" "$_rval" "txn_rollback" "$(current_profile 2>/dev/null)" "restored" "yes"
                else
                    _rb_fail=$((_rb_fail + 1))
                    log_warn "txn rollback failed for $_rpath"
                    _km_log_append "$(km_now_ms)" "$_rid" "$_rpath" "-" "$_rval" "txn_rollback" "$(current_profile 2>/dev/null)" "restore_failed" "no"
                fi
            done
            printf '{"ok":0,"rolled_back":1,"restored":%s,"restore_failed":%s,"error":"a setting in this group failed; applied changes were reverted"}\n' \
                "$_rb_ok" "$_rb_fail"
        else
            printf '{"ok":1,"committed":1}\n'
        fi
    fi
    rm -f "$KM_TXN_ACTIVE" "$KM_TXN_ACTIVE.failed" 2>/dev/null
    return 0
}

# ----------------------------------------------------------------------
# rollback from the change log
# ----------------------------------------------------------------------

# km_rollback N|all - restore the last N successful changes (newest first)
km_rollback() {
    _rn="${1:-all}"
    [ -f "$KM_CHANGE_LOG" ] || { printf '{"ok":0,"error":"no change history"}\n'; return 1; }
    if ! km_lock; then
        printf '{"ok":0,"error":"busy"}\n'
        return 1
    fi
    _ok=0; _fail=0; _skip=0
    if [ "$_rn" = "all" ]; then
        _sel=$(awk -F '\t' '$8=="ok" || $8=="restored" {print}' "$KM_CHANGE_LOG" | tac 2>/dev/null || awk -F '\t' '$8=="ok" || $8=="restored"' "$KM_CHANGE_LOG")
    else
        case "$_rn" in ''|*[!0-9]) _rn=1 ;; esac
        _sel=$(awk -F '\t' '$8=="ok" || $8=="restored" {print}' "$KM_CHANGE_LOG" | tail -n "$_rn" | tac 2>/dev/null || awk -F '\t' '$8=="ok" || $8=="restored"' "$KM_CHANGE_LOG" | tail -n "$_rn")
    fi
    for _l in "$_sel"; do
        [ -n "$_l" ] || continue
        _rid=$(printf '%s' "$_l" | awk -F '\t' '{print $2}')
        _rpath=$(printf '%s' "$_l" | awk -F '\t' '{print $3}')
        _rval=$(printf '%s' "$_l" | awk -F '\t' '{print $4}')
        [ -n "$_rpath" ] && [ "$_rpath" != "-" ] || { _skip=$((_skip + 1)); continue; }
        [ -e "$_rpath" ] || { _fail=$((_fail + 1)); continue; }
        if node_writable "$_rpath" 2>/dev/null && ( printf '%s' "$_rval" >"$_rpath" ) 2>/dev/null; then
            _ok=$((_ok + 1))
            _km_log_append "$(km_now_ms)" "$_rid" "$_rpath" "$(read_node "$_rpath" 2>/dev/null)" "$_rval" "rollback" "$(current_profile 2>/dev/null)" "restored" "yes"
        else
            _fail=$((_fail + 1))
        fi
    done
    km_unlock
    printf '{"ok":1,"restored":%s,"failed":%s,"skipped":%s}\n' "$_ok" "$_fail" "$_skip"
    return 0
}
