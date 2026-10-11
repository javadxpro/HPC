#!/system/bin/sh
# Hamedis Performance Core (HPC) - late_start service
#
# Runs once at boot, then loops at POLL_INTERVAL. Designed to be
# essentially free: one /proc scan and one thermal read per wakeup,
# no dumpsys, no subprocess storms, no busy waiting.
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

log_info "=============================================="
log_info "$HPC_NAME v$HPC_VERSION starting"

# ----------------------------------------------------------------------
# Wait for boot to complete. Applying CPU policy while init is still
# bringing up services is a good way to fight with the ROM's own tuner
# and lose. We wait, with a hard cap so we never hang forever.
# ----------------------------------------------------------------------
_waited=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 2
    _waited=$(( _waited + 2 ))
    [ "$_waited" -ge 120 ] && break
done
log_info "boot_completed after ${_waited}s"

# Let the ROM's own boot-time tuning settle before we apply ours.
sleep 20

# Fresh capability scan each boot: kernel/ROM may have changed.
run_detection
load_capabilities

# Clear any session left behind by a crash or reboot.
game_recover_stale

# Apply the baseline profile, honouring battery policy.
_startup_profile=$(battery_adjust_profile "$MODE")
apply_profile "$_startup_profile"
log_info "startup profile: $_startup_profile (requested $MODE)"

# Start the WebUI so the Magisk Action button (and the browser) can
# reach it immediately. Costs nothing while idle - busybox httpd only
# wakes on a request.
if [ "${WEBUI_AUTOSTART:-1}" = "1" ]; then
    web_start >/dev/null 2>&1
fi

if [ "${SERVICE_ENABLED:-1}" != "1" ]; then
    log_info "SERVICE_ENABLED=0, exiting (profile stays applied)"
    exit 0
fi

# ----------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------
# Config is re-read each cycle but only acted on when it actually
# changed, so `reload` works without a restart and costs nothing.
_last_cfg_mtime=""
_cfg_mtime() {
    stat -c %Y "$HPC_CONFIG" 2>/dev/null || printf '0'
}
_last_cfg_mtime=$(_cfg_mtime)

_tick=0
while true; do
    _tick=$(( _tick + 1 ))

    # --- config hot-reload
    _now_mtime=$(_cfg_mtime)
    if [ "$_now_mtime" != "$_last_cfg_mtime" ]; then
        _last_cfg_mtime="$_now_mtime"
        hpc_load_config
        log_info "config reloaded (MODE=$MODE POLL=$POLL_INTERVAL)"
        if ! game_is_active; then
            apply_profile "$(battery_adjust_profile "$MODE")" quiet
        fi
    fi

    # --- game detection (cheap fast path when a game is known)
    game_tick

    # --- thermal management
    thermal_tick

    # --- periodic heartbeat, deliberately infrequent
    if [ $(( _tick % 20 )) -eq 0 ]; then
        log_info "heartbeat: profile=$(current_profile) thermal=$(thermal_get_state) game=$(game_current_pkg)"
    fi

    # Profiles may define their own interval; gaming polls a bit faster.
    _sleep="${POLL_INTERVAL:-45}"
    if game_is_active; then
        _sleep=$(( _sleep / 2 ))
        [ "$_sleep" -lt 15 ] && _sleep=15
    fi
    sleep "$_sleep"
done
