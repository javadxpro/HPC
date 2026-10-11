#!/system/bin/sh
# Hamedis Performance Core (HPC) - game detection
#
# COST CONTROL: `dumpsys` is expensive (tens of ms, allocates, wakes
# system_server). We avoid it entirely in the steady state.
#
# Primary mechanism: scan /proc for a matching cmdline. This is a pure
# VFS read of a few hundred small files, costs ~5-15 ms, and needs no
# IPC. We only do it once per POLL_INTERVAL (30-60 s), and once a game
# IS found we switch to checking that single PID's /proc entry, which
# is a single stat() - effectively free.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_GAME_PID="$HPC_STATE/game_pid"
HPC_GAME_PKG="$HPC_STATE/game_pkg"
HPC_PRE_GAME="$HPC_STATE/pre_game_profile"

game_is_active() {
    [ -f "$HPC_GAME_PID" ] || return 1
    _gp=$(read_node "$HPC_GAME_PID") || return 1
    case "$_gp" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_gp" ]
}

game_current_pkg() {
    [ -f "$HPC_GAME_PKG" ] && read_node "$HPC_GAME_PKG" || printf ''
}

# Cheap liveness check for an already-known game: one directory stat.
game_still_running() {
    _gsr_pid=$(read_node "$HPC_GAME_PID" 2>/dev/null) || return 1
    case "$_gsr_pid" in ''|*[!0-9]*) return 1 ;; esac

    # The directory is the authoritative liveness test.
    [ -d "/proc/$_gsr_pid" ] || return 1

    _gsr_pkg=$(game_current_pkg)
    [ -n "$_gsr_pkg" ] || return 0

    _gsr_cmd=$(tr '\0' '\n' <"/proc/$_gsr_pid/cmdline" 2>/dev/null | head -n1)

    # An EMPTY cmdline does NOT mean the process died.
    #
    # Under memory pressure, or while the app is being frozen/thawed by
    # the ROM's app-standby logic, /proc/PID/cmdline can read back empty
    # for a moment even though the process is alive. Treating that as
    # "game exited" caused a profile bounce: HPC restored the baseline,
    # then re-detected the SAME pid seconds later and re-applied the
    # gaming profile. Observed in the wild as:
    #     23:33:26 game ended: com.tencent.ig
    #     23:33:33 game detected: com.tencent.ig (pid 14557)
    # - identical pid, seven seconds apart.
    #
    # Only a cmdline that is readable AND belongs to a different package
    # counts as pid reuse.
    [ -n "$_gsr_cmd" ] || return 0

    case "$_gsr_cmd" in
        "$_gsr_pkg"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Scan /proc for any configured game package. Prints "PID PKG" on hit.
game_scan() {
    [ -n "${GAME_PACKAGES:-}" ] || return 1

    for _gs_dir in /proc/[0-9]*; do
        [ -r "$_gs_dir/cmdline" ] || continue
        _gs_cmd=$(tr '\0' '\n' <"$_gs_dir/cmdline" 2>/dev/null | head -n1)
        [ -n "$_gs_cmd" ] || continue

        for _gs_pkg in $GAME_PACKAGES; do
            case "$_gs_pkg" in ''|\#*) continue ;; esac
            # Match the main process (exact) or a subprocess (pkg:tag).
            case "$_gs_cmd" in
                "$_gs_pkg"|"$_gs_pkg":*)
                    printf '%s %s' "${_gs_dir##*/}" "$_gs_pkg"
                    return 0
                    ;;
            esac
        done
    done
    return 1
}

# Called when a game starts.
game_enter() {
    _ge_pid="$1"
    _ge_pkg="$2"

    # Remember what we were running so we can put it back.
    _ge_prev=$(current_profile)
    [ "$_ge_prev" = "unknown" ] && _ge_prev="${MODE:-balanced}"
    printf '%s' "$_ge_prev" >"$HPC_PRE_GAME" 2>/dev/null
    printf '%s' "$_ge_pid" >"$HPC_GAME_PID" 2>/dev/null
    printf '%s' "$_ge_pkg" >"$HPC_GAME_PKG" 2>/dev/null

    _ge_target="${GAME_PROFILE:-performance}"

    # Battery policy can veto or soften the gaming profile.
    if ! battery_allows_gaming; then
        log_info "game $_ge_pkg: battery too low for $_ge_target, using balanced"
        _ge_target="balanced"
    else
        _ge_target=$(battery_adjust_profile "$_ge_target")
    fi

    log_info "game detected: $_ge_pkg (pid $_ge_pid) -> profile $_ge_target"
    apply_profile "$_ge_target" quiet

    # Give the game's own processes a scheduling advantage where the ROM
    # exposes cgroup/stune. This is a hint, not a kill or a priority hack.
    game_boost_process "$_ge_pid"
    return 0
}

# Conservative, reversible scheduling hint for the game process.
game_boost_process() {
    _gb_pid="$1"
    [ -d "/proc/$_gb_pid" ] || return 1

    # schedtune/stune boost group, if the ROM has one.
    _gb_st="${STUNE_PATH:-}"
    [ -n "$_gb_st" ] || _gb_st=$(detect_stune 2>/dev/null)
    if [ -n "$_gb_st" ] && [ -d "$_gb_st/top-app" ] && [ -w "$_gb_st/top-app/cgroup.procs" ]; then
        printf '%s' "$_gb_pid" >"$_gb_st/top-app/cgroup.procs" 2>/dev/null && \
            log_debug "game pid $_gb_pid moved to top-app"
    fi

    # Modest niceness improvement. We do NOT use RT priority: starving
    # system_server or surfaceflinger causes stutter and can wedge the UI.
    if command -v renice >/dev/null 2>&1; then
        renice -n -5 -p "$_gb_pid" >/dev/null 2>&1
    fi
    return 0
}

# Called when the game exits (or the user runs `stop-game`).
game_exit() {
    _gx_pkg=$(game_current_pkg)
    _gx_prev=""
    [ -f "$HPC_PRE_GAME" ] && _gx_prev=$(read_node "$HPC_PRE_GAME")
    [ -n "$_gx_prev" ] || _gx_prev="${MODE:-balanced}"

    rm -f "$HPC_GAME_PID" "$HPC_GAME_PKG" 2>/dev/null

    log_info "game ended: ${_gx_pkg:-unknown} -> restoring profile $_gx_prev"
    apply_profile "$_gx_prev" quiet
    rm -f "$HPC_PRE_GAME" 2>/dev/null
    return 0
}

# One tick of game detection. Cheap in both branches.
game_tick() {
    [ "${AUTO_GAME_MODE:-1}" = "1" ] || return 0

    # Do we have a tracked game session on record?
    if [ -f "$HPC_GAME_PID" ]; then
        if game_still_running; then
            # Fast path: single stat, game alive, nothing to do.
            return 0
        fi

        # The tracked PID is gone. Before restoring, check whether the
        # game simply respawned under a new PID (common: the game
        # restarts its renderer, or Android restarts the activity).
        _gt_hit=$(game_scan)
        if [ -n "$_gt_hit" ]; then
            _gt_pid="${_gt_hit%% *}"
            _gt_pkg="${_gt_hit#* }"
            if [ "$_gt_pkg" = "$(game_current_pkg)" ]; then
                printf '%s' "$_gt_pid" >"$HPC_GAME_PID" 2>/dev/null
                log_debug "game $_gt_pkg re-pid -> $_gt_pid"
                game_boost_process "$_gt_pid"
                return 0
            fi
            # A DIFFERENT game started: hand over without bouncing the profile.
            game_exit
            game_enter "$_gt_pid" "$_gt_pkg"
            return 0
        fi

        # Genuinely gone: restore the pre-game profile.
        game_exit
        return 0
    fi

    # No session on record. Slow path: full /proc scan, once per interval.
    _gt_hit=$(game_scan) || return 0
    [ -n "$_gt_hit" ] || return 0
    _gt_pid="${_gt_hit%% *}"
    _gt_pkg="${_gt_hit#* }"
    [ -n "$_gt_pid" ] && [ -n "$_gt_pkg" ] && game_enter "$_gt_pid" "$_gt_pkg"
    return 0
}

# Called once at boot: if a stale session survived a reboot or crash,
# clear it so the device does not silently stay in the gaming profile.
game_recover_stale() {
    [ -f "$HPC_GAME_PID" ] || return 0
    if game_still_running; then
        log_info "game session survived: $(game_current_pkg)"
        return 0
    fi
    log_warn "stale game session found at startup, clearing"
    rm -f "$HPC_GAME_PID" "$HPC_GAME_PKG" 2>/dev/null
    _gr_prev=""
    [ -f "$HPC_PRE_GAME" ] && _gr_prev=$(read_node "$HPC_PRE_GAME")
    rm -f "$HPC_PRE_GAME" 2>/dev/null
    return 0
}
