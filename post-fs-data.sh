#!/system/bin/sh
# Hamedis Performance Core (HPC) - post-fs-data stage
#
# Runs very early, before Android services start. Kept deliberately
# minimal: this stage blocks boot, so anything slow or clever here risks
# a bootloop. We only prepare directories and record that boot began.
# No CPU/GPU/thermal writes happen at this stage.
# shellcheck disable=SC3043

MODDIR="${0%/*}"
HPC_DATA=/data/adb/hamedis

# /data is mounted at post-fs-data, so this is safe.
mkdir -p "$HPC_DATA/logs" "$HPC_DATA/state" "$HPC_DATA/profiles" 2>/dev/null
chmod 0700 "$HPC_DATA" 2>/dev/null

# Per-boot state that must not leak across reboots.
rm -f "$HPC_DATA/state/unsupported.seen" 2>/dev/null

# A stale PID from before the reboot is meaningless and would otherwise
# make the service think a game is running.
rm -f "$HPC_DATA/state/game_pid" 2>/dev/null

# Thermal state is a live measurement, not a setting. Carrying it across
# a reboot means the device starts throttled at whatever step it reached
# during the previous session - so a phone that shut down hot comes back
# up limited, and needs several poll cycles to climb out of it even
# though it is now cold.
rm -f "$HPC_DATA/state/thermal_step" \
      "$HPC_DATA/state/thermal_state" 2>/dev/null

# Record boot for the log, without loading the whole framework.
{
    printf '%s [INFO ] ---- boot: post-fs-data ----\n' \
        "$(date '+%m-%d %H:%M:%S' 2>/dev/null)"
} >>"$HPC_DATA/logs/hpc.log" 2>/dev/null

exit 0
