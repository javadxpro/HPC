#!/system/bin/sh
# Hamedis Performance Core (HPC) - live kernel monitoring collectors
#
# Part of the Kernel Management Platform (v1.10).
#
# Read-only JSON builders for the WebUI and CLI. Honesty rules:
#   * an interface that does not exist emits null / "absent", never a
#     fake number
#   * rates (utilization, MB/s) are deltas between two real samples;
#     the first sample cannot produce a rate, so it reports null and
#     stores the sample for the next call
#   * every sample carries its timestamp so stale data is visible
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
KM_MON_DIR="$HPC_STATE/mon"

km_mon_init() {
    [ -d "$KM_MON_DIR" ] || mkdir -p "$KM_MON_DIR" 2>/dev/null
}

# ----------------------------------------------------------------------
# status / environment
# ----------------------------------------------------------------------

km_mon_status() {
    _s_prof=$(current_profile 2>/dev/null)
    _s_bootid=$(head -n1 /proc/sys/kernel/random/boot_id 2>/dev/null)
    _s_up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    _s_load=$(head -n1 /proc/loadavg 2>/dev/null)
    _s_kernel=$(uname -r 2>/dev/null)
    _s_root=$( [ -d /data/adb/magisk ] && printf 'magisk' || \
               [ -d /data/adb/kernelsu ] && printf 'kernelsu' || \
               [ -f /data/adb/ap ] && printf 'apatch' || printf 'none' )
    printf '{"ts":%s,"kernel":%s,"arch":%s,"root_env":%s,"hpc_version":%s,"uptime_s":%s,"loadavg":%s,"profile":%s,"boot_id":%s}' \
        "$(km_now_ms)" "$(km_jesc "$_s_kernel")" "$(km_jesc "$(uname -m 2>/dev/null)")" \
        "$(km_jesc "$_s_root")" "$(km_jesc "${HPC_VERSION:-?}")" \
        "$(km_jnum "$_s_up")" "$(km_jesc "$_s_load")" "$(km_jesc "$_s_prof")" "$(km_jesc "$_s_bootid")"
    printf '\n'
}

# ----------------------------------------------------------------------
# CPU - per policy freqs + utilization from /proc/stat deltas
# ----------------------------------------------------------------------

km_mon_cpu() {
    km_mon_init
    _c_prev="$KM_MON_DIR/cpu_prev"

    # per-cpu jiffies: line "cpu" aggregate + per core
    _c_stat=$(head -n 16 /proc/stat 2>/dev/null)
    _c_now_ms=$(km_now_ms)

    _c_pol_json=""
    _c_first=1
    for _c_p in $(detect_policies 2>/dev/null); do
        [ -d "$_c_p" ] || continue
        _c_cpulabel=$(read_node "$_c_p/related_cpus" 2>/dev/null)
        [ -n "$_c_cpulabel" ] || _c_cpulabel=$(printf '%s' "$_c_p" | awk -F/ '{print $NF}')
        _c_gov=$(read_node "$_c_p/scaling_governor" 2>/dev/null)
        _c_cur=$(read_node "$_c_p/scaling_cur_freq" 2>/dev/null)
        [ -n "$_c_cur" ] || _c_cur=$(read_node "$_c_p/cpuinfo_cur_freq" 2>/dev/null)
        _c_smin=$(read_node "$_c_p/scaling_min_freq" 2>/dev/null)
        _c_smax=$(read_node "$_c_p/scaling_max_freq" 2>/dev/null)
        [ "$_c_first" = "1" ] || _c_pol_json="$_c_pol_json,"
        _c_first=0
        _c_pol_json="$_c_pol_json{\"cpus\":$(km_jesc "$_c_cpulabel"),\"governor\":$(km_jesc "$_c_gov"),\"cur_khz\":$(km_jnum "$_c_cur"),\"min_khz\":$(km_jnum "$_c_smin"),\"max_khz\":$(km_jnum "$_c_smax")}"
    done

    # aggregate utilization: delta of cpu line
    _c_util="null"
    _c_cpu_line=$(printf '%s\n' "$_c_stat" | awk '$1=="cpu" {print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}')
    _c_tot=$(printf '%s' "$_c_cpu_line" | awk '{print $1}')
    _c_idle=$(printf '%s' "$_c_cpu_line" | awk '{print $2}')
    if [ -n "$_c_tot" ] && [ -n "$_c_idle" ]; then
        if [ -f "$_c_prev" ]; then
            read -r _c_ptot _c_pidle _c_pt <"$_c_prev" 2>/dev/null
            if [ -n "$_c_ptot" ] && [ -n "$_c_pt" ] && [ "$_c_tot" -gt "$_c_ptot" ] 2>/dev/null; then
                _c_dt=$(( _c_tot - _c_ptot ))
                _c_di=$(( _c_idle - _c_pidle ))
                [ "$_c_dt" -gt 0 ] && _c_util=$(( ( _c_dt - _c_di ) * 100 / _c_dt ))
            fi
        fi
        printf '%s\t%s\t%s\n' "$_c_tot" "$_c_idle" "$_c_now_ms" >"$_c_prev" 2>/dev/null
    fi

    printf '{"ts":%s,"util_pct":%s,"policies":[%s],"online":%s,"loadavg":%s}\n' \
        "$_c_now_ms" "$_c_util" "$_c_pol_json" \
        "$(km_jesc "$(cpu_online_state 2>/dev/null)")" \
        "$(km_jesc "$(head -n1 /proc/loadavg 2>/dev/null)")"
}

# ----------------------------------------------------------------------
# GPU
# ----------------------------------------------------------------------

km_mon_gpu() {
    _g=$(detect_gpu_path 2>/dev/null) || {
        printf '{"ts":%s,"present":0,"reason":"no GPU sysfs interface"}\n' "$(km_now_ms)"
        return 0
    }
    _g_busy="null"; _g_clk="null"; _g_thr="absent"; _g_gov="null"
    [ -f "$_g/gpu_busy_percentage" ] && _g_busy=$(read_node "$_g/gpu_busy_percentage" 2>/dev/null)
    [ -f "$_g/gpuclk" ] && _g_clk=$(read_node "$_g/gpuclk" 2>/dev/null)
    [ -f "$_g/throttling" ] && _g_thr=$(read_node "$_g/throttling" 2>/dev/null)
    [ -f "$_g/devfreq/governor" ] && _g_gov=$(read_node "$_g/devfreq/governor" 2>/dev/null)
    [ -f "$_g/devfreq/cur_freq" ] && _g_cur=$(read_node "$_g/devfreq/cur_freq" 2>/dev/null) || _g_cur=""
    printf '{"ts":%s,"present":1,"vendor":%s,"busy_pct":%s,"clock_khz":%s,"cur_freq_khz":%s,"throttling":%s,"governor":%s}\n' \
        "$(km_now_ms)" "$(km_jesc "$(detect_gpu_vendor "$_g")")" "$(km_jnum "$_g_busy")" \
        "$(km_jnum "$_g_clk")" "$(km_jnum "$_g_cur")" "$(km_jesc "$_g_thr")" "$(km_jesc "$_g_gov")"
}

# ----------------------------------------------------------------------
# memory
# ----------------------------------------------------------------------

km_mon_mem() {
    _m=""
    [ -r /proc/meminfo ] && _m=$(cat /proc/meminfo 2>/dev/null)
    _m_get() { printf '%s' "$_m" | awk -v k="$1" '$1==k":" {print $2; exit}'; }
    _m_tot=$(_m_get MemTotal); _m_free=$(_m_get MemFree)
    _m_avail=$(_m_get MemAvailable); [ -n "$_m_avail" ] || _m_avail="$_m_free"
    _m_cached=$(_m_get Cached); _m_buffers=$(_m_get Buffers)
    _m_swt=$(_m_get SwapTotal); _m_swf=$(_m_get SwapFree)
    _m_used=$(( ${_m_tot:-0} - ${_m_avail:-0} ))

    _m_z_used="null"; _m_z_orig="null"
    _m_z=$(detect_zram 2>/dev/null)
    if [ -n "$_m_z" ]; then
        _m_zu=$(read_node "$_m_z/mm_used" 2>/dev/null)
        [ -n "$_m_zu" ] || _m_zu=$(read_node "$_m_z/mem_used_total" 2>/dev/null)
        [ -n "$_m_zu" ] && _m_z_used="$_m_zu"
        _m_zo=$(read_node "$_m_z/orig_data_size" 2>/dev/null)
        [ -n "$_m_zo" ] && _m_z_orig="$_m_zo"
    fi

    _m_psi="null"
    [ -r /proc/pressure/memory ] && _m_psi=$(head -n 1 /proc/pressure/memory 2>/dev/null | sed 's/^some://')

    printf '{"ts":%s,"total_kb":%s,"used_kb":%s,"available_kb":%s,"cached_kb":%s,"buffers_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s,"zram_used_kb":%s,"zram_orig_kb":%s,"psi_some":%s}\n' \
        "$(km_now_ms)" "$(km_jnum "$_m_tot")" "$(km_jnum "$_m_used")" "$(km_jnum "$_m_avail")" \
        "$(km_jnum "$_m_cached")" "$(km_jnum "$_m_buffers")" "$(km_jnum "$_m_swt")" "$(km_jnum "$_m_swf")" \
        "$(km_jnum "$_m_z_used")" "$(km_jnum "$_m_z_orig")" "$(km_jesc "$_m_psi")"
}

# ----------------------------------------------------------------------
# thermal
# ----------------------------------------------------------------------

km_mon_thermal() {
    _t_now=$(km_now_ms)
    _t_json=""
    _t_first=1
    _t_hottest=""
    _t_hottest_v=-999
    for _t_line in $(detect_thermal_zones 2>/dev/null); do
        [ -n "$_t_line" ] || continue
        _t_z="${_t_line%%:*}"
        _t_type="${_t_line#*:}"
        _t_c=$(read_temp_c "$_t_z" 2>/dev/null) || continue
        [ "$_t_first" = "1" ] || _t_json="$_t_json,"
        _t_first=0
        _t_json="$_t_json{\"type\":$(km_jesc "$_t_type"),\"temp_c\":${_t_c:-null}}"
        [ "$_t_c" -gt "$_t_hottest_v" ] && { _t_hottest_v=$_t_c; _t_hottest=$_t_type; }
    done
    _t_state=$(detect_thermal_throttling 2>/dev/null)
    printf '{"ts":%s,"zones":[%s],"hottest":%s,"throttling_state":%s}\n' \
        "$_t_now" "$_t_json" "$(km_jesc "$_t_hottest")" "$(km_jesc "${_t_state:-absent}")"
}

# ----------------------------------------------------------------------
# battery
# ----------------------------------------------------------------------

km_mon_batt() {
    _b=$(detect_battery_path 2>/dev/null) || {
        printf '{"ts":%s,"present":0}\n' "$(km_now_ms)"
        return 0
    }
    _b_get() { read_node "$_b/$1" 2>/dev/null; }
    _b_cap=$(_b_get capacity); _b_status=$(_b_get status)
    _b_volt=$(_b_get voltage_now); _b_curr=$(_b_get current_now)
    _b_temp=$(_b_get temp); _b_health=$(_b_get health)
    _b_cycles=$(_b_get cycle_count)
    _b_full=$(_b_get charge_full); _b_des=$(_b_get charge_full_design)
    case "$_b_temp" in
        ''|*[!0-9-]*) _b_temp_c="null" ;;
        *) [ "$_b_temp" -gt 200 ] && _b_temp_c=$(( _b_temp / 10 )) || _b_temp_c="$_b_temp" ;;
    esac
    printf '{"ts":%s,"present":1,"capacity_pct":%s,"status":%s,"voltage_uv":%s,"current_ua":%s,"temp_c":%s,"health":%s,"cycle_count":%s,"charge_full_uah":%s,"charge_design_uah":%s}\n' \
        "$(km_now_ms)" "$(km_jnum "$_b_cap")" "$(km_jesc "$_b_status")" "$(km_jnum "$_b_volt")" \
        "$(km_jnum "$_b_curr")" "$(km_jnum "$_b_temp_c")" "$(km_jesc "${_b_health:-unknown}")" \
        "$(km_jnum "$_b_cycles")" "$(km_jnum "$_b_full")" "$(km_jnum "$_b_des")"
}

# ----------------------------------------------------------------------
# network - counters + rates (delta)
# ----------------------------------------------------------------------

km_mon_net() {
    km_mon_init
    _n_prev="$KM_MON_DIR/net_prev"
    _n_now=$(km_now_ms)
    _n_json=""
    _n_first=1
    for _n_if in /sys/class/net/*; do
        [ -d "$_n_if" ] || continue
        _n_name="${_n_if##*/}"
        _n_line=$(awk -v n="$_n_name" -F': *' '$1==n {print}' /proc/net/dev 2>/dev/null)
        [ -n "$_n_line" ] || continue
        _n_rx=$(printf '%s' "$_n_line" | awk '{print $2}')
        _n_rxp=$(printf '%s' "$_n_line" | awk '{print $4}')
        _n_rxe=$(printf '%s' "$_n_line" | awk '{print $5}')
        _n_rxd=$(printf '%s' "$_n_line" | awk '{print $6}')
        _n_tx=$(printf '%s' "$_n_line" | awk '{print $10}')
        _n_txp=$(printf '%s' "$_n_line" | awk '{print $12}')
        _n_txe=$(printf '%s' "$_n_line" | awk '{print $13}')
        _n_txd=$(printf '%s' "$_n_line" | awk '{print $14}')

        _n_rxr="null"; _n_txr="null"
        if [ -f "$_n_prev" ]; then
            _n_pline=$(printf '%s\n' "$_n_now" > /dev/null; grep "^$_n_name	" "$_n_prev" 2>/dev/null | head -n1)
            _n_prx=$(printf '%s' "$_n_pline" | awk -F '\t' '{print $2}')
            _n_ptx=$(printf '%s' "$_n_pline" | awk -F '\t' '{print $3}')
            _n_pts=$(printf '%s' "$_n_pline" | awk -F '\t' '{print $4}')
            if [ -n "$_n_prx" ] && [ -n "$_n_pts" ]; then
                _n_age=$(( _n_now - _n_pts ))
                if [ "$_n_age" -ge 1000 ] && [ "$_n_age" -le 300000 ] && [ "$_n_rx" -ge "$_n_prx" ] 2>/dev/null; then
                    _n_rxr=$(( ( _n_rx - _n_prx ) / 1024 / ( _n_age / 1000 ) ))   # KB/s
                    _n_txr=$(( ( _n_tx - _n_ptx ) / 1024 / ( _n_age / 1000 ) ))
                fi
            fi
        fi
        [ "$_n_first" = "1" ] || _n_json="$_n_json,"
        _n_first=0
        _n_json="$_n_json{\"if\":$(km_jesc "$_n_name"),\"rx_bytes\":$(_n_rx),\"tx_bytes\":$(_n_tx),\"rx_pps\":$(_n_rxp),\"tx_pps\":$(_n_txp),\"rx_err\":$(_n_rxe),\"rx_drop\":$(_n_rxd),\"tx_err\":$(_n_txe),\"tx_drop\":$(_n_txd),\"rx_kbps\":$(_n_rxr),\"tx_kbps\":$(_n_txr)}"
        printf '%s\t%s\t%s\t%s\n' "$_n_name" "$_n_rx" "$_n_tx" "$_n_now"
    done >"$KM_MON_DIR/net_cur" 2>/dev/null
    mv -f "$KM_MON_DIR/net_cur" "$_n_prev" 2>/dev/null

    _n_tcp=$(read_node /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    printf '{"ts":%s,"ifs":[%s],"tcp_cc":%s}\n' "$_n_now" "$_n_json" "$(km_jesc "${_n_tcp:-absent}")"
}

# ----------------------------------------------------------------------
# storage - diskstats rates (delta)
# ----------------------------------------------------------------------

km_mon_disk() {
    km_mon_init
    _d_prev="$KM_MON_DIR/disk_prev"
    _d_now=$(km_now_ms)
    _d_json=""
    _d_first=1
    _d_tmp="$KM_MON_DIR/disk_cur"
    : >"$_d_tmp" 2>/dev/null
    for _d_d in $(km_block_devices 2>/dev/null); do
        [ -d "$_d_d" ] || continue
        _d_name="${_d_d##*/}"
        _d_ds=$(awk -v n="$_d_name" '$9==n {print $4, $8, $12, $13; exit}' /proc/diskstats 2>/dev/null)
        [ -n "$_d_ds" ] || continue
        set -- $_d_ds
        _d_r=$1; _d_w=$2; _d_ioq=$3; _d_iot=$4
        _d_rps="null"; _d_wps="null"
        if [ -f "$_d_prev" ]; then
            _d_pline=$(grep "^$_d_name	" "$_d_prev" 2>/dev/null | head -n1)
            _d_pr=$(printf '%s' "$_d_pline" | awk -F '\t' '{print $2}')
            _d_pw=$(printf '%s' "$_d_pline" | awk -F '\t' '{print $3}')
            _d_pts=$(printf '%s' "$_d_pline" | awk -F '\t' '{print $4}')
            if [ -n "$_d_pr" ] && [ -n "$_d_pts" ]; then
                _d_age=$(( _d_now - _d_pts ))
                if [ "$_d_age" -ge 1000 ] && [ "$_d_age" -le 300000 ] && [ "$_d_r" -ge "$_d_pr" ] 2>/dev/null; then
                    _d_rps=$(( ( _d_r - _d_pr ) / ( _d_age / 1000 ) ))
                    _d_wps=$(( ( _d_w - _d_pw ) / ( _d_age / 1000 ) ))
                fi
            fi
        fi
        [ "$_d_first" = "1" ] || _d_json="$_d_json,"
        _d_first=0
        _d_json="$_d_json{\"dev\":$(km_jesc "$_d_name"),\"reads\":$(_d_r),\"writes\":$(_d_w),\"io_ms\":$(_d_iot),\"rps\":$(_d_rps),\"wps\":$(_d_wps)}"
        printf '%s\t%s\t%s\t%s\n' "$_d_name" "$_d_r" "$_d_w" "$_d_now" >>"$_d_tmp" 2>/dev/null
    done
    mv -f "$_d_tmp" "$_d_prev" 2>/dev/null
    printf '{"ts":%s,"devices":[%s]}\n' "$_d_now" "$_d_json"
}

# ----------------------------------------------------------------------
# scheduler
# ----------------------------------------------------------------------

km_mon_sched() {
    _s_json=""
    _s_first=1
    _s_idle="null"
    if [ -r /proc/stat ]; then
        _s_stat=$(head -n 16 /proc/stat 2>/dev/null)
        for _s_c in $(printf '%s\n' "$_s_stat" | awk '$1 ~ /^cpu[0-9]+/ {print $1}'); do
            _s_line=$(printf '%s\n' "$_s_stat" | awk -v c="$_s_c" '$1==c {print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}')
            _s_t=$(printf '%s' "$_s_line" | awk '{print $1}')
            _s_i=$(printf '%s' "$_s_line" | awk '{print $2}')
            [ "$_s_first" = "1" ] || _s_json="$_s_json,"
            _s_first=0
            _s_json="$_s_json\"${_s_c#cpu}:${_s_t}/${_s_i}\""
        done
    fi
    _s_feat="null"
    [ -r /sys/kernel/debug/sched_features ] && _s_feat=$(read_node /sys/kernel/debug/sched_features 2>/dev/null)
    _s_cfs=""
    [ -r /proc/sys/kernel/sched_min_granularity_ns ] && _s_cfs=$(read_node /proc/sys/kernel/sched_min_granularity_ns 2>/dev/null)
    _s_walt="absent"
    [ -d /proc/sys/walt ] && _s_walt=$(ls /proc/sys/walt 2>/dev/null | wc -l | tr -d ' ')
    printf '{"ts":%s,"cpu_jiffies":[%s],"sched_features":%s,"cfs_min_granularity_ns":%s,"walt_keys":%s}\n' \
        "$(km_now_ms)" "$_s_json" "$(km_jesc "$_s_feat")" "$(km_jnum "$_s_cfs")" "$(km_jesc "$_s_walt")"
}

# ----------------------------------------------------------------------
# processes - top by memory, top by CPU (delta, reuses last snapshot)
# ----------------------------------------------------------------------

km_mon_procs() {
    km_mon_init
    _p_prev="$KM_MON_DIR/procs_prev"
    _p_now=$(km_now_ms)
    _p_cur="$KM_MON_DIR/procs_cur"
    : >"$_p_cur" 2>/dev/null

    for _p_d in /proc/[0-9]*; do
        [ -d "$_p_d" ] || continue
        _p_pid="${_p_d##*/}"
        _p_stat=$(head -n 1 "$_p_d/stat" 2>/dev/null) || continue
        _p_comm=$(printf '%s' "$_p_stat" | sed -n 's/^[0-9]* \(.*\)) [a-zA-Z].*/\1/p')
        _p_state=$(printf '%s' "$_p_stat" | awk -F') ' '{print $2}' | awk '{print $1}')
        # utime+stime = fields 14,15 after "comm)"
        _p_cpu=$(printf '%s' "$_p_stat" | sed 's/^.*) //' | awk '{print $12 + $13}')
        _p_rss=$(awk '/^VmRSS:/ {print $2}' "$_p_d/status" 2>/dev/null)
        _p_uid=$(awk '/^Uid:/ {print $2}' "$_p_d/status" 2>/dev/null)
        [ -n "$_p_cpu" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_p_pid" "$_p_comm" "$_p_state" "$_p_cpu" "${_p_rss:-0}" "${_p_uid:-0}" >>"$_p_cur" 2>/dev/null
        [ "$(wc -l <"$_p_cur" 2>/dev/null | tr -d ' ')" -ge 400 ] && break
    done

    _p_mem_top=$(sort -t "$(printf '\t')" -k5 -rn "$_p_cur" 2>/dev/null | head -n 12)
    _p_json_mem=""
    _p_first=1
    # line-by-line: process names may contain spaces
    while IFS= read -r _p_l; do
        [ -n "$_p_l" ] || continue
        _p_f1=$(printf '%s' "$_p_l" | awk -F '\t' '{print $1}')
        _p_f2=$(printf '%s' "$_p_l" | awk -F '\t' '{print $2}')
        _p_f3=$(printf '%s' "$_p_l" | awk -F '\t' '{print $3}')
        _p_f5=$(printf '%s' "$_p_l" | awk -F '\t' '{print $5}')
        [ "$_p_first" = "1" ] || _p_json_mem="$_p_json_mem,"
        _p_first=0
        _p_json_mem="$_p_json_mem{\"pid\":$_p_f1,\"comm\":$(km_jesc "$_p_f2"),\"state\":$(km_jesc "$_p_f3"),\"rss_kb\":${_p_f5:-0}}"
    done <<_PMEMEOF
$_p_mem_top
_PMEMEOF


    # CPU delta: only when a previous snapshot exists (>=2s old)
    _p_cpu_top=""
    if [ -f "$_p_prev" ]; then
        _p_prev_ts=$(head -n1 "$_p_prev" 2>/dev/null)
        if [ -n "$_p_prev_ts" ] && [ "$_p_now" -gt "$_p_prev_ts" ] 2>/dev/null; then
            _p_age=$(( _p_now - _p_prev_ts ))
            if [ "$_p_age" -ge 1500 ] && [ "$_p_age" -le 300000 ]; then
                _p_cpu_top=$(awk -F '\t' '
                    NR==FNR { if (FNR>1) old[$1]=$4; next }
                    FNR>1 && ($1 in old) && ($4 >= old[$1]) {
                        u = ($4 - old[$1]) * 100 / (ARGV[2]/100)
                        if (u > 0.5) print $0 "\t" u
                    }' "$_p_prev" "$_p_cur" "$_p_age" 2>/dev/null | sort -t "$(printf '\t')" -k7 -rn | head -n 12)
            fi
        fi
    fi
    printf '%s\n' "$_p_now" >"$_p_prev.tmp" 2>/dev/null
    cat "$_p_cur" >>"$_p_prev.tmp" 2>/dev/null
    mv -f "$_p_prev.tmp" "$_p_prev" 2>/dev/null
    rm -f "$_p_cur" 2>/dev/null

    _p_json_cpu=""
    _p_first=1
    if [ -n "$_p_cpu_top" ]; then
        _p_first=1
        while IFS= read -r _p_l; do
            [ -n "$_p_l" ] || continue
            _p_f1=$(printf '%s' "$_p_l" | awk -F '\t' '{print $1}')
            _p_f2=$(printf '%s' "$_p_l" | awk -F '\t' '{print $2}')
            _p_f7=$(printf '%s' "$_p_l" | awk -F '\t' '{print $7}')
            [ "$_p_first" = "1" ] || _p_json_cpu="$_p_json_cpu,"
            _p_first=0
            _p_json_cpu="$_p_json_cpu{\"pid\":$_p_f1,\"comm\":$(km_jesc "$_p_f2"),\"cpu_pct\":$_p_f7}"
        done <<_PCPUEOF
$_p_cpu_top
_PCPUEOF
    fi

    printf '{"ts":%s,"by_memory":[%s],"by_cpu":[%s],"note":"by_cpu needs two samples >=1.5s apart; empty on first view"}\n' \
        "$_p_now" "$_p_json_mem" "$_p_json_cpu"
}

# ----------------------------------------------------------------------
# kernel modules
# ----------------------------------------------------------------------

km_mon_modules() {
    _m_count=0
    _m_json=""
    _m_first=1
    if [ -r /proc/modules ]; then
        _m_count=$(wc -l </proc/modules 2>/dev/null | tr -d ' ')
        _m_count=${_m_count:-0}
        if [ "$_m_count" -gt 0 ]; then
            while read -r _m_name _m_size _m_rest; do
                [ -n "$_m_name" ] || continue
                [ "$_m_first" = "1" ] || _m_json="$_m_json,"
                _m_first=0
                _m_json="$_m_json{\"name\":$(km_jesc "$_m_name"),\"size\":$(km_jnum "${_m_size:-0}")}"
                [ "$(printf '%s' "$_m_json" | wc -c)" -gt 4000 ] && break
            done </proc/modules 2>/dev/null
        fi
    fi
    _m_magisk="absent"
    [ -d /data/adb/modules ] && _m_magisk=$(find /data/adb/modules -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    printf '{"ts":%s,"count":%s,"modules":[%s],"magisk_modules":%s,"note":%s}\n' \
        "$(km_now_ms)" "$(km_jnum "$_m_count")" "$_m_json" "$(km_jnum "$_m_magisk")" \
        "$( [ "$_m_count" = "0" ] && km_jesc 'list hidden on this Android build - count 0 is expected, not an error' || km_jesc ' ' )"
}

# ----------------------------------------------------------------------
# kernel log
# ----------------------------------------------------------------------

km_mon_klog() {
    # km_mon_klog [N] [grep-pattern]
    _k_n="${1:-100}"
    _k_pat="${2:-}"
    case "$_k_n" in ''|*[!0-9]*) _k_n=100 ;; esac
    if ! dmesg >/dev/null 2>&1; then
        printf '{"ts":%s,"readable":0,"lines":[],"reason":"dmesg restricted in this context"}\n' "$(km_now_ms)"
        return 0
    fi
    _k_errs=0
    _k_json=""
    _k_first=1
    _k_lines=$(dmesg 2>/dev/null | tail -n "$_k_n")
    if [ -n "$_k_pat" ]; then
        _k_lines=$(printf '%s\n' "$_k_lines" | grep -i "$_k_pat" | tail -n "$_k_n")
    fi
    while IFS= read -r _k_l; do
        [ -n "$_k_l" ] || continue
        case "$_k_l" in
            *"[E"*|*error*|*fail*|*crash*|*panic*|*BUG*|*watchdog*|*thermal*) _k_errs=$((_k_errs + 1)) ;;
        esac
        [ "$_k_first" = "1" ] || _k_json="$_k_json,"
        _k_first=0
        _k_json="$_k_json$(km_jesc "$_k_l")"
        [ "$(printf '%s' "$_k_json" | wc -c)" -gt 16000 ] && break
    done <<EOF
$_k_lines
EOF
    printf '{"ts":%s,"readable":1,"error_hint_count":%s,"lines":[%s]}\n' "$(km_now_ms)" "$_k_errs" "$_k_json"
}
