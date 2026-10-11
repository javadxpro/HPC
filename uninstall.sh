#!/system/bin/sh
# Hamedis Performance Core (HPC) - uninstall
#
# Magisk runs this when the module is removed. Our job: put every value
# we ever changed back the way we found it. Anything we cannot restore
# is left to the next reboot, which resets sysfs to kernel defaults
# anyway - so the worst case is still clean.
# shellcheck disable=SC3043

HPC_DATA=/data/adb/hamedis
BACKUP="$HPC_DATA/state/original_values"
LOG="$HPC_DATA/logs/hpc.log"

_log() {
    printf '%s [INFO ] uninstall: %s\n' \
        "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$1" >>"$LOG" 2>/dev/null
}

_log "starting"

# --- restore every backed-up node -------------------------------------
restored=0
failed=0
if [ -f "$BACKUP" ]; then
    while IFS="$(printf '\t')" read -r path value; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        # Make writable if we can, then restore.
        [ -w "$path" ] || chmod 0644 "$path" 2>/dev/null
        if [ -w "$path" ]; then
            if printf '%s' "$value" >"$path" 2>/dev/null; then
                restored=$((restored + 1))
            else
                failed=$((failed + 1))
            fi
        else
            failed=$((failed + 1))
        fi
    done <"$BACKUP"
fi
_log "restored=$restored failed=$failed"

# --- restore graphics properties --------------------------------------
# resetprop changes are volatile (they vanish on reboot anyway), but we
# clear them explicitly so a reboot is not required to get back to stock.
GFXBAK="$HPC_DATA/state/graphics_original"
if [ -f "$GFXBAK" ] && command -v resetprop >/dev/null 2>&1; then
    while IFS="$(printf '\t')" read -r prop val; do
        [ -n "$prop" ] || continue
        if [ -z "$val" ]; then
            resetprop --delete "$prop" 2>/dev/null
        else
            resetprop "$prop" "$val" 2>/dev/null
        fi
    done <"$GFXBAK"
    _log "graphics properties restored"
fi

# --- stop the service if it is still running --------------------------
pkill -f "hamedis_performance_core/service.sh" 2>/dev/null
pkill -f "httpd.*127.0.0.1:1111" 2>/dev/null

# --- clean runtime state, KEEP the user's config and logs -------------
# Someone reinstalling should not lose their game list and tuning.
rm -rf "$HPC_DATA/state" 2>/dev/null

_log "complete - config and logs kept at $HPC_DATA"
_log "to remove everything: rm -rf $HPC_DATA"

exit 0
