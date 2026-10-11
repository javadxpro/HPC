#!/system/bin/sh
# Hamedis Performance Core (HPC) - logger
# POSIX sh. Lightweight, size-capped, rotation-based logging.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_LOG_DIR="${HPC_LOG_DIR:-$HPC_DATA/logs}"
HPC_LOG="$HPC_LOG_DIR/hpc.log"
HPC_LOG_OLD="$HPC_LOG_DIR/hpc.log.1"

# Hard ceiling so a runaway loop can never fill /data.
HPC_LOG_MAX_BYTES="${HPC_LOG_MAX_BYTES:-262144}"   # 256 KiB
HPC_LOG_KEEP=1

# LOGGING: 1 = on, 0 = off (errors still recorded)
HPC_LOGGING="${LOGGING:-1}"

hpc_log_init() {
    [ -d "$HPC_LOG_DIR" ] || mkdir -p "$HPC_LOG_DIR" 2>/dev/null
    [ -f "$HPC_LOG" ] || : >"$HPC_LOG" 2>/dev/null
    chmod 0600 "$HPC_LOG" 2>/dev/null
}

# Cheap size check. stat is not guaranteed; fall back to wc -c.
_hpc_log_size() {
    _s=$(stat -c %s "$HPC_LOG" 2>/dev/null)
    if [ -z "$_s" ]; then
        _s=$(wc -c <"$HPC_LOG" 2>/dev/null)
    fi
    [ -n "$_s" ] || _s=0
    printf '%s' "$_s"
}

_hpc_log_rotate_if_needed() {
    [ -f "$HPC_LOG" ] || return 0
    _sz=$(_hpc_log_size)
    # Guard against non-numeric output from odd toybox builds.
    case "$_sz" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "$_sz" -ge "$HPC_LOG_MAX_BYTES" ]; then
        if [ "$HPC_LOG_KEEP" -ge 1 ]; then
            mv -f "$HPC_LOG" "$HPC_LOG_OLD" 2>/dev/null
        fi
        : >"$HPC_LOG" 2>/dev/null
        chmod 0600 "$HPC_LOG" 2>/dev/null
        printf '%s [INFO ] log rotated\n' "$(_hpc_ts)" >>"$HPC_LOG" 2>/dev/null
    fi
}

_hpc_ts() {
    date '+%m-%d %H:%M:%S' 2>/dev/null || printf 'no-date'
}

# hpc_log LEVEL MESSAGE...
hpc_log() {
    _lvl="$1"
    shift
    # ERROR and WARN always recorded; INFO/DEBUG respect LOGGING=0.
    case "$_lvl" in
        ERROR|WARN) ;;
        *) [ "$HPC_LOGGING" = "1" ] || return 0 ;;
    esac
    [ -d "$HPC_LOG_DIR" ] || mkdir -p "$HPC_LOG_DIR" 2>/dev/null
    _hpc_log_rotate_if_needed
    printf '%s [%-5s] %s\n' "$(_hpc_ts)" "$_lvl" "$*" >>"$HPC_LOG" 2>/dev/null
    return 0
}

log_info()  { hpc_log INFO  "$@"; }
log_warn()  { hpc_log WARN  "$@"; }
log_error() { hpc_log ERROR "$@"; }
log_debug() { [ "${HPC_DEBUG:-0}" = "1" ] && hpc_log DEBUG "$@"; return 0; }

# Unsupported kernel interfaces are expected on some devices/kernels.
# Record once per boot per path to avoid log spam.
HPC_UNSUP_SEEN="$HPC_DATA/state/unsupported.seen"
log_unsupported() {
    _path="$1"
    _why="${2:-not present}"
    [ -d "$HPC_DATA/state" ] || mkdir -p "$HPC_DATA/state" 2>/dev/null
    [ -f "$HPC_UNSUP_SEEN" ] || : >"$HPC_UNSUP_SEEN" 2>/dev/null
    if ! grep -qxF "$_path" "$HPC_UNSUP_SEEN" 2>/dev/null; then
        printf '%s\n' "$_path" >>"$HPC_UNSUP_SEEN" 2>/dev/null
        hpc_log WARN "unsupported: $_path ($_why)"
    fi
    return 0
}
