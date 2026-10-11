#!/system/bin/sh
# Hamedis Performance Core (HPC) - memory management
#
# PHILOSOPHY: Android's memory manager is already good. The common
# "RAM booster" pattern - periodically writing to drop_caches and
# killing background apps - actively HURTS sustained performance: it
# throws away page cache the system just paid to populate, forcing cold
# re-reads from flash, and it makes app switching slower, not faster.
#
# This module therefore does NOT:
#   - write to /proc/sys/vm/drop_caches on any schedule
#   - run memory-clearing loops
#   - modify LMK/lmkd minfree thresholds aggressively
#   - kill applications
#
# It DOES tune VM writeback/swap behaviour conservatively and report
# zRAM state, which is the part that actually affects frame pacing.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"

apply_ram() {
    _vm=/proc/sys/vm

    [ -n "${VM_SWAPPINESS:-}" ] && \
        safe_write "$_vm/swappiness" "$VM_SWAPPINESS"
    [ -n "${VM_VFS_CACHE_PRESSURE:-}" ] && \
        safe_write "$_vm/vfs_cache_pressure" "$VM_VFS_CACHE_PRESSURE"
    [ -n "${VM_DIRTY_RATIO:-}" ] && \
        safe_write "$_vm/dirty_ratio" "$VM_DIRTY_RATIO"
    [ -n "${VM_DIRTY_BACKGROUND_RATIO:-}" ] && \
        safe_write "$_vm/dirty_background_ratio" "$VM_DIRTY_BACKGROUND_RATIO"
    [ -n "${VM_DIRTY_EXPIRE_CENTISECS:-}" ] && \
        safe_write "$_vm/dirty_expire_centisecs" "$VM_DIRTY_EXPIRE_CENTISECS"
    [ -n "${VM_DIRTY_WRITEBACK_CENTISECS:-}" ] && \
        safe_write "$_vm/dirty_writeback_centisecs" "$VM_DIRTY_WRITEBACK_CENTISECS"
    [ -n "${VM_PAGE_CLUSTER:-}" ] && \
        safe_write "$_vm/page-cluster" "$VM_PAGE_CLUSTER"
    [ -n "${VM_STAT_INTERVAL:-}" ] && \
        safe_write "$_vm/stat_interval" "$VM_STAT_INTERVAL"

    return 0
}

# --- reporting only; we do not reconfigure zRAM at runtime ------------
# Resizing zRAM requires swapoff, which can stall the whole system.
# Detect and report; leave configuration to the ROM.

ram_total_kb() {
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null
}

ram_available_kb() {
    _a=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    if [ -z "$_a" ]; then
        _a=$(awk '/^MemFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    fi
    printf '%s' "$_a"
}

ram_used_kb() {
    _tot=$(ram_total_kb); _av=$(ram_available_kb)
    case "$_tot$_av" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' $(( _tot - _av ))
}

# Human summary like "5.7 / 8.0 GB"
ram_summary() {
    _tot=$(ram_total_kb); _used=$(ram_used_kb)
    case "$_tot" in ''|*[!0-9]*) printf 'unknown'; return 1 ;; esac
    case "$_used" in ''|*[!0-9]*) printf 'unknown'; return 1 ;; esac
    # one decimal place without floating point
    _tg=$(( _tot * 10 / 1048576 ))
    _ug=$(( _used * 10 / 1048576 ))
    printf '%s.%s / %s.%s GB' \
        $(( _ug / 10 )) $(( _ug % 10 )) $(( _tg / 10 )) $(( _tg % 10 ))
}

zram_summary() {
    _z="${ZRAM_PATH:-}"
    [ -n "$_z" ] || _z=$(detect_zram 2>/dev/null)
    [ -n "$_z" ] || { printf 'none'; return 1; }
    _ds=$(read_node "$_z/disksize" 2>/dev/null)
    case "$_ds" in ''|0|*[!0-9]*) printf 'inactive'; return 0 ;; esac
    _gb=$(( _ds * 10 / 1073741824 ))
    _algo=$(read_node "$_z/comp_algorithm" 2>/dev/null | \
            sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    [ -n "$_algo" ] || _algo=$(read_node "$_z/comp_algorithm" 2>/dev/null | awk '{print $1}')
    printf '%s.%s GB (%s)' $(( _gb / 10 )) $(( _gb % 10 )) "${_algo:-?}"
}

# A single, bounded cache reclaim. NOT called on any timer - exposed only
# for the manual `reset` action, where the user explicitly asked for it.
ram_manual_reclaim() {
    if [ -w /proc/sys/vm/drop_caches ]; then
        sync 2>/dev/null
        # 1 = pagecache only. Never 2 or 3: reclaiming dentries/inodes
        # causes a long, visible stall on Android.
        printf '1' >/proc/sys/vm/drop_caches 2>/dev/null
        log_info "manual pagecache reclaim performed"
        return 0
    fi
    return 1
}
