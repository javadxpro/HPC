#!/system/bin/sh
# Hamedis Performance Core (HPC) - kernel manager
#
# Exposes the kernel tunables that HPC did not already cover:
#   - I/O scheduler and block queue
#   - TCP congestion control
#   - zRAM parameters (read + safe writes only)
#   - battery health, charge rate and wear reporting (read-only)
#
# Everything routes through safe_write(), so every change is backed up,
# verified and reversible, and any node this kernel does not expose is
# skipped and logged rather than causing an error.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"

# ======================================================================
# I/O scheduler
# ======================================================================
#
# On UFS/eMMC the scheduler choice matters less than people claim, but
# read_ahead_kb genuinely affects app launch and texture streaming.
# We never pick a scheduler that is not in the kernel's own list.

km_block_devices() {
    # Physical backing devices only.
    #
    # dm-* are device-mapper virtual layers (dm-verity, dm-crypt on an
    # encrypted /data). Their queue knobs are owned by the mapper and are
    # never writable, so touching them produced a wall of SELinux
    # warnings with no benefit. Same for loop and zram.
    for _kb in /sys/block/sd? /sys/block/mmcblk[0-9] /sys/block/nvme[0-9]n[0-9]; do
        [ -d "$_kb/queue" ] && printf '%s\n' "$_kb"
    done
}

km_io_available() {
    # Prefer a device whose node still lists MULTIPLE schedulers. Some
    # kernels (and some vendor patches) collapse the list to just the
    # active name after a write, which would make us think only one
    # scheduler exists and refuse every subsequent change.
    _kia_best=""
    for _kia_d in $(km_block_devices); do
        _kl=$(read_node "$_kia_d/queue/scheduler" 2>/dev/null)
        [ -n "$_kl" ] || continue
        _kl=$(printf '%s' "$_kl" | tr -d '[]')
        _kia_n=$(printf '%s' "$_kl" | wc -w | tr -d ' ')
        if [ "${_kia_n:-0}" -gt 1 ]; then
            printf '%s' "$_kl"
            return 0
        fi
        [ -z "$_kia_best" ] && _kia_best="$_kl"
    done
    [ -n "$_kia_best" ] && { printf '%s' "$_kia_best"; return 0; }
    return 1
}

km_io_current() {
    for _kc in $(km_block_devices); do
        _kl=$(read_node "$_kc/queue/scheduler" 2>/dev/null)
        _sel=$(printf '%s' "$_kl" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
        [ -n "$_sel" ] && { printf '%s' "$_sel"; return 0; }
    done
    printf 'unknown'
}

# km_set_io SCHEDULER - only applies if the kernel lists it
# Accepts either a single name or a space-separated preference list.
# Kernels differ wildly: older ones expose noop/deadline/cfq, newer ones
# mq-deadline/kyber/bfq/none. A single hardcoded name silently does
# nothing on half of them.
km_set_io() {
    _sio_pref="$1"
    _sio_avail=$(km_io_available) || {
        log_unsupported "block scheduler" "no queue exposed"
        return 1
    }
    _sio_want=""
    for _sio_p in $_sio_pref; do
        for _sio_a in $_sio_avail; do
            [ "$_sio_p" = "$_sio_a" ] && { _sio_want="$_sio_p"; break; }
        done
        [ -n "$_sio_want" ] && break
    done
    if [ -z "$_sio_want" ]; then
        log_warn "no io scheduler from '$_sio_pref' available (have: $_sio_avail)"
        return 1
    fi
    _sio_ok=0
    for _sio_d in $(km_block_devices); do
        safe_write "$_sio_d/queue/scheduler" "$_sio_want" && _sio_ok=1
    done
    [ "$_sio_ok" -eq 1 ] && return 0
    return 1
}

km_apply_block() {
    [ -n "${IO_SCHEDULER:-}" ] && km_set_io "$IO_SCHEDULER"

    for _kq in $(km_block_devices); do
        [ -n "${IO_READ_AHEAD_KB:-}" ] && \
            safe_write "$_kq/queue/read_ahead_kb" "$IO_READ_AHEAD_KB"
        [ -n "${IO_NR_REQUESTS:-}" ] && \
            safe_write "$_kq/queue/nr_requests" "$IO_NR_REQUESTS"
        # iostats costs a little CPU per request; off is fine on a phone.
        [ -n "${IO_STATS:-}" ] && \
            safe_write "$_kq/queue/iostats" "$IO_STATS"
        # add_random drains entropy for no benefit on flash.
        [ -n "${IO_ADD_RANDOM:-}" ] && \
            safe_write "$_kq/queue/add_random" "$IO_ADD_RANDOM"
    done
    return 0
}

# ======================================================================
# Network
# ======================================================================

km_tcp_available() {
    read_node /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

km_tcp_current() {
    read_node /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
}

km_apply_tcp() {
    [ -n "${TCP_CONGESTION:-}" ] || return 0
    _avail=$(km_tcp_available) || return 1
    for _t in $_avail; do
        if [ "$_t" = "$TCP_CONGESTION" ]; then
            safe_write /proc/sys/net/ipv4/tcp_congestion_control "$TCP_CONGESTION"
            return 0
        fi
    done
    log_warn "tcp congestion '$TCP_CONGESTION' not available (have: $_avail)"
    return 1
}

# ======================================================================
# zRAM
# ======================================================================
#
# We READ zRAM config and report it. We do not resize it at runtime:
# that requires swapoff, which can stall the entire device for seconds.

km_zram_info() {
    _kz="${ZRAM_PATH:-}"
    [ -n "$_kz" ] || _kz=$(detect_zram 2>/dev/null)
    [ -n "$_kz" ] || return 1

    _ds=$(read_node "$_kz/disksize" 2>/dev/null)
    _orig=$(read_node "$_kz/orig_data_size" 2>/dev/null)
    _compr=$(read_node "$_kz/compr_data_size" 2>/dev/null)
    _algo=$(read_node "$_kz/comp_algorithm" 2>/dev/null | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    [ -n "$_algo" ] || _algo=$(read_node "$_kz/comp_algorithm" 2>/dev/null | awk '{print $1}')

    printf 'size=%s algo=%s' "${_ds:-0}" "${_algo:-?}"
    if [ -n "$_orig" ] && [ -n "$_compr" ] && [ "$_compr" -gt 0 ] 2>/dev/null; then
        printf ' ratio=%s.%sx' $(( _orig / _compr )) $(( (_orig * 10 / _compr) % 10 ))
    fi
    return 0
}

# ======================================================================
# Battery: read-only reporting
# ======================================================================
#
# We READ the battery's health and charge state and report it. We do
# NOT limit charging current or cap the charge level: that machinery
# was built for a heat-stressed, damaged cell. A healthy cell charges
# fine at its vendor default, and the SoC thermal management handles
# the rest.

km_charge_nodes() {
    _kb=$(detect_battery_path 2>/dev/null) || return 1
    printf '%s' "$_kb"
}

# Current charging rate in mA (negative = discharging)
km_charge_rate_ma() {
    _kb=$(km_charge_nodes) || return 1
    _cn=$(read_node "$_kb/current_now" 2>/dev/null)
    case "$_cn" in ''|*[!0-9-]*) return 1 ;; esac
    # Usually microamps
    if [ "$_cn" -gt 100000 ] || [ "$_cn" -lt -100000 ]; then
        printf '%s' $(( _cn / 1000 ))
    else
        printf '%s' "$_cn"
    fi
}

# Battery wear: full charge capacity vs design capacity
km_battery_health() {
    _kb=$(km_charge_nodes) || return 1
    _full=$(read_node "$_kb/charge_full" 2>/dev/null)
    _design=$(read_node "$_kb/charge_full_design" 2>/dev/null)
    _health=$(read_node "$_kb/health" 2>/dev/null)
    _cycles=$(read_node "$_kb/cycle_count" 2>/dev/null)

    printf 'health=%s' "${_health:-unknown}"
    [ -n "$_cycles" ] && printf ' cycles=%s' "$_cycles"

    case "$_full$_design" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$_design" -gt 0 ] 2>/dev/null || return 0
    _pct=$(( _full * 100 / _design ))
    printf ' capacity=%s%%' "$_pct"
    return 0
}

# ======================================================================
# Apply hook
# ======================================================================

apply_kernel() {
    km_apply_block
    km_apply_tcp
    return 0
}

# ======================================================================
# Reporting
# ======================================================================

km_report() {
    printf '  I/O sched    : %s\n' "$(km_io_current)"
    _av=$(km_io_available 2>/dev/null)
    [ -n "$_av" ] && printf '                 available: %s\n' "$_av"

    for _kr in $(km_block_devices); do
        _ra=$(read_node "$_kr/queue/read_ahead_kb" 2>/dev/null)
        [ -n "$_ra" ] && { printf '  Read-ahead   : %s KB (%s)\n' "$_ra" "${_kr##*/}"; break; }
    done

    printf '  TCP          : %s\n' "$(km_tcp_current)"
    _zi=$(km_zram_info 2>/dev/null) && printf '  zRAM         : %s\n' "$_zi"

    printf '\n'
    printf '  BATTERY\n'
    _bh=$(km_battery_health 2>/dev/null) && printf '  Condition    : %s\n' "$_bh"
    _rate=$(km_charge_rate_ma 2>/dev/null)
    if [ -n "$_rate" ]; then
        if [ "$_rate" -gt 0 ] 2>/dev/null; then
            printf '  Charge rate  : %s mA (charging)\n' "$_rate"
        else
            printf '  Draw         : %s mA\n' "$_rate"
        fi
    fi
    _kb=$(km_charge_nodes 2>/dev/null)
    if [ -n "$_kb" ] && [ -f "$_kb/constant_charge_current_max" ]; then
        _cl=$(read_node "$_kb/constant_charge_current_max")
        case "$_cl" in
            ''|*[!0-9]*) ;;
            *) printf '  Current cap  : %s mA (vendor default)\n' $(( _cl / 1000 )) ;;
        esac
    fi
    return 0
}
