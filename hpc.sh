#!/system/bin/sh
# Hamedis Performance Core (HPC) - manual control / Magisk action
#
# Usage:
#   sh /data/adb/modules/hamedis_performance_core/hpc.sh [command]
#
# Commands:
#   status        show current state (default)
#   cool          switch to COOL profile
#   balanced      switch to BALANCED profile
#   performance   switch to PERFORMANCE profile
#   gaming120     switch to GAMING120 profile (high-refresh gaming)
#   kernel        show kernel tunables and battery health
#   webui         start the web interface on port 1111
#   webstop       stop the web interface
#   game          force gaming profile now
#   stop-game     leave gaming profile, restore previous
#   reload        re-read config.conf and re-apply
#   reset         restore every original value and re-apply baseline
#   monitor [min] start recording a gaming session (default 20 min)
#   sessions      list saved sessions
#   clean [scan|quick|deep]  scan or run the cleaner (deep = + ART cache)
#   ramclean      clear logcat buffers and drop clean page caches
#   boost [action] speed booster status/actions:
#                   (none)=status, speed_on, speed_off,
#                   anim_on, anim_off, vm_on, vm_off,
#                   memext_on, memext_off
#   save NAME     save the current session under a name
#   compare A B   compare two saved sessions side by side
#   report        summarise the recorded session
#   stopmon       stop recording early
#   log           show recent log lines
#   caps          show detected hardware capabilities
#   km [sub]      kernel management platform:
#                   status|cpu|gpu|mem|thermal|battery|net|disk|sched|
#                   procs|modules|klog|caps|events|health|history|
#                   rollback|set ID VAL|get ID|prof ...|bench ...|
#                   advise|report
#   help          this text
# shellcheck disable=SC3043

MODDIR="${0%/*}"
# If invoked as a bare filename (no directory component), ${0%/*} yields
# the filename itself. Fall back to the current directory in that case.
[ "$MODDIR" = "$0" ] && MODDIR="."
case "$MODDIR" in
    /*) ;;                                   # already absolute
    *)  MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" || MODDIR="${0%/*}" ;;
esac
export HPC_MODDIR="$MODDIR"

# shellcheck source=/dev/null
. "$MODDIR/scripts/common.sh"

hpc_bootstrap

CMD="${1:-status}"

# ----------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------

_module_active() {
    [ -f "$HPC_MODDIR/disable" ] && { printf 'DISABLED'; return; }
    if pgrep -f "$HPC_MODDIR/service.sh" >/dev/null 2>&1; then
        printf 'ACTIVE'
    elif [ -f "$HPC_STATE/current_profile" ]; then
        printf 'APPLIED (service not running)'
    else
        printf 'INACTIVE'
    fi
}

_pretty_game() {
    _pg=$(game_current_pkg)
    if [ -z "$_pg" ]; then
        printf 'none'
        return
    fi
    # Friendly names for the common ones; fall back to the package.
    case "$_pg" in
        com.mojang.minecraftpe)              printf 'Minecraft' ;;
        com.tencent.ig|com.pubg.krmobile|com.vng.pubgmobile|com.rekoo.pubgm)
                                             printf 'PUBG Mobile' ;;
        com.activision.callofduty.shooter|com.garena.game.codm)
                                             printf 'Call of Duty Mobile' ;;
        com.dts.freefireth|com.dts.freefiremax) printf 'Free Fire' ;;
        com.miHoYo.GenshinImpact|com.miHoYo.Yuanshen) printf 'Genshin Impact' ;;
        com.roblox.client)                   printf 'Roblox' ;;
        com.riotgames.league.wildrift)       printf 'Wild Rift' ;;
        *)                                   printf '%s' "$_pg" ;;
    esac
}

_switch() {
    _target="$1"
    _eff=$(battery_adjust_profile "$_target")
    apply_profile "$_eff"
    # Persist as the new baseline so it survives the next service tick.
    # Handle the key per-line: if MODE= is missing from the config, the
    # sed would no-op and the service's hot-reload would bounce the
    # profile back to the built-in default on the next tick.
    if [ -f "$HPC_CONFIG" ]; then
        if grep -q '^MODE=' "$HPC_CONFIG" 2>/dev/null; then
            _tmp="$HPC_CONFIG.tmp.$$"
            sed "s/^MODE=.*/MODE=$_target/" "$HPC_CONFIG" >"$_tmp" 2>/dev/null && \
                mv -f "$_tmp" "$HPC_CONFIG" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
        else
            printf 'MODE=%s\n' "$_target" >>"$HPC_CONFIG" 2>/dev/null
        fi
    fi
    if [ "$_eff" != "$_target" ]; then
        printf 'Profile: %s  (battery policy adjusted from %s)\n' \
            "$(printf '%s' "$_eff" | tr '[:lower:]' '[:upper:]')" \
            "$(printf '%s' "$_target" | tr '[:lower:]' '[:upper:]')"
    else
        printf 'Profile: %s\n' "$(printf '%s' "$_eff" | tr '[:lower:]' '[:upper:]')"
    fi
}

_status() {
    _prof=$(current_profile | tr '[:lower:]' '[:upper:]')
    _temp=$(thermal_read 2>/dev/null)
    _tstate=$(thermal_get_state)
    _tstep=$(thermal_get_step)
    _cap=$(battery_capacity 2>/dev/null)
    _btemp=$(battery_temp_c 2>/dev/null)
    _chg="no"; battery_charging 2>/dev/null && _chg="yes"
    _ram=$(ram_summary 2>/dev/null)
    _zram=$(zram_summary 2>/dev/null)

    printf '\n'
    printf '  %s\n' "$HPC_NAME"
    printf '  %s\n' '─────────────────────────────────────────'
    printf '  Profile      : %s\n' "$_prof"
    printf '  Game         : %s\n' "$(_pretty_game)"
    if [ -n "$_temp" ]; then
        printf '  CPU Temp     : %s°C\n' "$_temp"
    else
        printf '  CPU Temp     : unavailable\n'
    fi
    printf '  Thermal State: %s' "$_tstate"
    [ "$_tstep" != "0" ] && printf ' (step %s/3)' "$_tstep"
    printf '\n'
    printf '  Battery      : %s%%  %s°C  charging=%s\n' \
        "${_cap:-?}" "${_btemp:-?}" "$_chg"
    printf '  RAM          : %s\n' "${_ram:-unknown}"
    printf '  zRAM         : %s\n' "${_zram:-none}"
    printf '  Module       : %s\n' "$(_module_active)"
    printf '  %s\n' '─────────────────────────────────────────'
    printf '  CPU cores    : %s  (%s online)\n' "${CPU_COUNT:-?}" "$(cpu_online_state)"
    printf '  Clusters     : %s\n' "${CLUSTERS:-?}"
    printf '  Governor     : %s\n' "$(_current_gov)"
    printf '  GPU          : %s\n' "${GPU_VENDOR:-none}"
    command -v gfx_report >/dev/null 2>&1 && gfx_report
    printf '\n'
}

_current_gov() {
    for _p in $(detect_policies); do
        _g=$(read_node "$_p/scaling_governor" 2>/dev/null)
        [ -n "$_g" ] && { printf '%s' "$_g"; return 0; }
    done
    printf 'unknown'
}

# ----------------------------------------------------------------------
# dispatch
# ----------------------------------------------------------------------

case "$CMD" in
    status|"")
        _status
        ;;

    cool|balanced|performance|gaming90|gaming120)
        _switch "$CMD"
        ;;

    game)
        _hit=$(game_scan)
        if [ -n "$_hit" ]; then
            game_enter "${_hit%% *}" "${_hit#* }"
            printf 'Gaming profile active for: %s\n' "$(_pretty_game)"
        else
            # No game running: apply the gaming profile anyway, as asked.
            apply_profile "$(battery_adjust_profile "${GAME_PROFILE:-performance}")"
            printf 'No game detected. Gaming profile applied manually.\n'
        fi
        ;;

    stop-game)
        if [ -f "$HPC_STATE/game_pid" ]; then
            game_exit
            printf 'Gaming profile cleared. Restored: %s\n' \
                "$(current_profile | tr '[:lower:]' '[:upper:]')"
        else
            apply_profile "$(battery_adjust_profile "$MODE")"
            printf 'No game session. Baseline applied: %s\n' \
                "$(current_profile | tr '[:lower:]' '[:upper:]')"
        fi
        ;;

    reload)
        hpc_load_config
        run_detection
        load_capabilities
        apply_profile "$(battery_adjust_profile "$MODE")"
        printf 'Config reloaded. Profile: %s\n' \
            "$(current_profile | tr '[:lower:]' '[:upper:]')"
        ;;

    reset)
        printf 'Restoring all original values...\n'
        restore_all
        command -v gfx_restore_props >/dev/null 2>&1 && gfx_restore_props
        rm -f "$HPC_STATE/game_pid" "$HPC_STATE/game_pkg" \
              "$HPC_STATE/pre_game_profile" "$HPC_STATE/thermal_step" \
              "$HPC_STATE/thermal_state" 2>/dev/null
        : >"$HPC_BACKUP" 2>/dev/null
        run_detection
        load_capabilities
        apply_profile "$(battery_adjust_profile "$MODE")"
        printf 'Reset complete. Profile: %s\n' \
            "$(current_profile | tr '[:lower:]' '[:upper:]')"
        ;;

    monitor)
        _mins="${2:-20}"
        case "$_mins" in
            ''|*[!0-9]*) _mins=20 ;;
        esac
        [ "$_mins" -lt 1 ] && _mins=1
        [ "$_mins" -gt 120 ] && _mins=120

        if monitor_running; then
            printf 'A session is already recording. Stop it with: stopmon\n'
            exit 1
        fi

        # Archive the previous run first. Starting a new recording used
        # to silently destroy the old one, which made an A/B comparison
        # between two profiles impossible.
        _arch=$(monitor_archive "")
        [ -n "$_arch" ] && printf '  Previous session saved as: %s\n' \
            "$(basename "$_arch" .csv)"

        # Fresh file with a header row.
        printf 'time,soc_c,state,step,cpu_max_mhz,cpu_cur_mhz,gpu_pct,gpu_mhz,batt_pct,batt_c,profile,game\n' \
            >"$HPC_SESSION" 2>/dev/null

        monitor_loop "$_mins" "${MON_DEFAULT_INTERVAL:-5}" >/dev/null 2>&1 &
        _mpid=$!
        printf '%s' "$_mpid" >"$HPC_MON_PID" 2>/dev/null

        printf '\n'
        printf '  Recording for %s minutes.\n' "$_mins"
        printf '\n'
        printf '  Now: start your game and play normally.\n'
        printf '  Recording stops by itself - you can close this terminal.\n'
        printf '\n'
        printf '  When you are done:\n'
        printf '    sh %s report\n' "$0"
        printf '\n'
        log_info "monitor: started for ${_mins}m"
        ;;

    stopmon)
        if monitor_running; then
            monitor_stop
            printf 'Recording stopped.\n'
        else
            printf 'No recording in progress.\n'
        fi
        ;;

    report)
        printf '\n  %s - Session Report\n' "$HPC_NAME"
        printf '  ─────────────────────────────────────────\n'
        if monitor_running; then
            printf '  (recording still in progress)\n\n'
        fi
        monitor_report "${2:-}"
        ;;

    sessions)
        printf '\n  %s - Saved Sessions\n' "$HPC_NAME"
        printf '  ─────────────────────────────────────────\n'
        monitor_list || printf '  (none)\n'
        printf '\n  Report one:  sh %s report NAME\n' "$0"
        printf '  Compare:     sh %s compare A B\n' "$0"
        ;;

    save)
        _sv_name="${2:-}"
        case "$_sv_name" in
            '') printf 'Usage: save NAME   (e.g. save gaming90-run1)\n'; exit 1 ;;
        esac
        _sv_dest=$(monitor_archive "$_sv_name")
        if [ -n "$_sv_dest" ]; then
            printf 'Session saved as: %s\n' "$(basename "$_sv_dest" .csv)"
        else
            printf 'Nothing to save - no recorded session with data found.\n'
        fi
        ;;

    compare)
        _cmp_a="${2:-}"
        _cmp_b="${3:-}"
        if [ -z "$_cmp_a" ] || [ -z "$_cmp_b" ]; then
            printf 'Usage: compare A B   (session names, see: sessions)\n'
            exit 1
        fi
        monitor_compare "$_cmp_a" "$_cmp_b"
        ;;

    kernel)
        printf '\n  %s - Kernel\n' "$HPC_NAME"
        printf '  ─────────────────────────────────────────\n'
        km_report
        printf '\n'
        ;;

    webui)
        if web_start; then
            printf 'WebUI: http://127.0.0.1:%s\n' "${WEBUI_PORT:-1111}"
            web_open >/dev/null 2>&1
        else
            printf 'Failed to start WebUI.\n'
            exit 1
        fi
        ;;

    webstop)
        web_stop
        printf 'WebUI stopped.\n'
        ;;

    log)
        _n="${2:-40}"
        if [ -f "$HPC_LOG_DIR/hpc.log" ]; then
            tail -n "$_n" "$HPC_LOG_DIR/hpc.log"
        else
            printf 'No log file yet.\n'
        fi
        ;;

    caps)
        if [ -f "$HPC_STATE/capabilities.conf" ]; then
            cat "$HPC_STATE/capabilities.conf"
        else
            run_detection && cat "$HPC_STATE/capabilities.conf"
        fi
        ;;

    # ── Kernel Management Platform ─────────────────────────────────
    km)
        _km_sub="${2:-status}"
        case "$_km_sub" in
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
            klog)     km_mon_klog "${3:-100}" "${4:-}" ;;
            caps)     km_caps_scan; km_caps_json ;;
            events)   km_events "${3:-40}" "${4:-}" ;;
            health)   km_health ;;
            history)  km_history "${3:-50}" ;;
            rollback) km_rollback "${3:-all}" ;;
            set)
                [ -n "${3:-}" ] && [ -n "${4:-}" ] || { printf 'usage: hpc.sh km set <control-id> <value>\n'; break 2; }
                km_ctl_set "$3" "$4" "cli"
                ;;
            get)      [ -n "${3:-}" ] && km_ctl_get "$3" && printf '\n' || printf 'control not found\n' ;;
            prof)
                case "${3:-list}" in
                    list)     km_prof_list ;;
                    show:*)   km_prof_show "${3#show:}" ;;
                    compare:*) km_prof_compare "${3#compare:%%,*}" "${3#compare:*,*}" ;;
                    export:*) km_prof_export "${3#export:}" ;;
                    duplicate:*) km_prof_duplicate "${3#duplicate:%%,*}" "${3#duplicate:*,*}" ;;
                    delete:*) km_prof_delete "${3#delete:}" ;;
                    *)        printf 'usage: hpc.sh km prof list|show:P|compare:A,B|export:P|duplicate:A,B|delete:P\n' ;;
                esac
                ;;
            bench)
                case "${3:-list}" in
                    list)   km_bench_list 10 ;;
                    run:*)  km_bench_run "${3#run:}" "${4:-3000}" ;;
                    ab:*)   _kba="${3#ab:}"; km_bench_ab "${_kba%%:*}" "${_kba#*:%%:*}" "${_kba#*:#*:}" "${4:-3000}" ;;
                    *)      printf 'usage: hpc.sh km bench list|run:NAME|ab:NAME:PA:PB\n' ;;
                esac
                ;;
            advise)   [ "${3:-}" = "explain" ] && km_advise_explain "${4:-}" || km_advise ;;
            report)   km_diag_report ;;
            *)
                printf 'usage: hpc.sh km [status|cpu|gpu|mem|thermal|battery|net|disk|sched|procs|modules|klog|caps|events|health|history|rollback|set|get|prof|bench|advise|report]\n'
                ;;
        esac
        ;;

    clean)
        _clean_mode="${2:-scan}"
        case "$_clean_mode" in
            scan)
                printf '%-28s %10s\n' 'TARGET' 'SIZE'
                # shellcheck disable=SC2086
                for _clean_e in $CLEANER_QUICK_TARGETS $CLEANER_DEEP_TARGETS; do
                    [ -n "$_clean_e" ] || continue
                    printf '%-28s %10s KiB\n' "${_clean_e%%|*}" \
                        "$(cleaner_dir_kb "${_clean_e%%|*}")"
                done
                printf '\nfree /data: %s KiB\n' "$(cleaner_storage_free_kb /data)"
                ;;
            quick|deep)
                _clean_kb=$(cleaner_run "$_clean_mode")
                printf 'Cleaned (%s): %s KiB freed\n' "$_clean_mode" "$_clean_kb"
                ;;
            *)
                printf 'usage: hpc.sh clean [scan|quick|deep]\n'
                ;;
        esac
        ;;

    ramclean)
        cleaner_ram >/dev/null 2>&1
        printf 'RAM housekeeping done (logcat cleared, clean caches dropped)\n'
        ;;

    boost)
        _boost_act="${2:-status}"
        case "$_boost_act" in
            status|"")
                printf 'active:     %s\n' "$(booster_active && echo yes || echo no)"
                printf 'profile:    %s\n' "$(current_profile)"
                printf 'governor:   %s\n' "$(for _bp in $(detect_policies); do read_node "$_bp/scaling_governor" && break; done)"
                printf 'io:         %s\n' "$(km_io_current)"
                printf 'animations: %s\n' "$(booster_anim_value)"
                printf 'swappiness: %s\n' "$(read_node /proc/sys/vm/swappiness)"
                printf 'virt ram:   %s\n' "$(booster_memext_state)"
                ;;
            speed_on)   booster_speed_on;  printf 'Speed mode ON\n' ;;
            speed_off)  booster_speed_off; printf 'Speed mode OFF (restored)\n' ;;
            anim_on)    booster_anim_on && printf 'Animations on\n' ;;
            anim_off)   booster_anim_off && printf 'Animations off\n' ;;
            vm_on)      booster_vm_on && printf 'VM speed tuning on\n' ;;
            vm_off)     booster_vm_off; printf 'VM speed tuning off (restored)\n' ;;
            memext_on)  booster_memext_on && printf 'MIUI virtual RAM on\n' || printf 'not found on this ROM\n' ;;
            memext_off) booster_memext_off && printf 'MIUI virtual RAM off\n' || printf 'not found on this ROM\n' ;;
            *)
                printf 'usage: hpc.sh boost [status|speed_on|speed_off|anim_on|anim_off|vm_on|vm_off|memext_on|memext_off]\n'
                ;;
        esac
        ;;

    help|-h|--help)
        sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
        ;;

    *)
        printf 'Unknown command: %s\n' "$CMD"
        printf "Try: status | cool | balanced | performance | gaming90 | gaming120 | kernel | webui | game | stop-game | monitor | report | sessions | save | compare | stopmon | reload | reset | log | caps\n"
        exit 1
        ;;
esac

exit 0
