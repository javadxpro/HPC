#!/system/bin/sh
# Hamedis Performance Core (HPC) - kernel capability discovery engine
#
# Part of the Kernel Management Platform (v1.10).
#
# This engine DISCOVERS what this specific device/kernel actually exposes
# and records it with metadata. It never assumes an interface exists on
# one device and therefore exists on another, and it never presents a
# missing control as functional:
#
#   - every capability has: id, name, path, kind, rw status, risk class,
#     value type, source, confidence, current value, detail
#   - "absent" and "inaccessible" are distinct, first-class states
#   - a re-scan compares against the previous scan and records
#     interfaces that disappeared (event: cap_lost)
#
# Outputs:
#   $HPC_STATE/caps2/registry.tsv   machine-readable, for CLI/shell
#   $HPC_STATE/caps2/summary.json   for the WebUI
#   $HPC_STATE/caps2/prev.tsv       previous scan, for change detection
#
# The legacy detector.sh (run_detection -> capabilities.conf) is kept
# untouched for backwards compatibility; this file does not replace it.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
KM_CAPS_DIR="$HPC_STATE/caps2"
KM_REG_TSV="$KM_CAPS_DIR/registry.tsv"
KM_SUM_JSON="$KM_CAPS_DIR/summary.json"
KM_PREV_TSV="$KM_CAPS_DIR/prev.tsv"

# ----------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------

# Millisecond timestamp. toybox `date` supports %N on most builds, but
# not all do - fall back to second resolution instead of fabricating.
km_now_ms() {
    _kmn=$(date +%s%3N 2>/dev/null)
    case "$_kmn" in
        ''|*[!0-9]*) date +%s | awk '{print $1 * 1000}' ;;
        *) printf '%s' "$_kmn" ;;
    esac
}

# km_reg ADD ID NAME PATH KIND RW RISK TYPE CONFIDENCE VALUE DETAIL
# Appends one capability row to the in-progress registry.
_km_reg_rows=""
_km_reg_count=0

km_reg() {
    _kr_id="$1" _kr_name="$2" _kr_path="$3" _kr_kind="$4" _kr_rw="$5"
    _kr_risk="$6" _kr_type="$7" _kr_conf="$8" _kr_val="$9"
    shift 9
    _kr_det="$*"
    _km_reg_rows="${_km_reg_rows}${_kr_id}	${_kr_name}	${_kr_path}	${_kr_kind}	${_kr_rw}	${_kr_risk}	${_kr_type}	${_kr_conf}	${_kr_val}	${_kr_det}
"
    _km_reg_count=$((_km_reg_count + 1))
    return 0
}

# JSON string escaper (shell-side; the CGI has its own).
km_jesc() {
    _je=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\t' ' ' | tr -d '\000-\037\177' | tr -d '\r')
    printf "%s%s%s" "\"" "$_je" "\""
}

# JSON number (empty/non-numeric -> null, keeps the payload valid JSON)
km_jnum() {
    case "$1" in
        ''|*[!0-9-]*) printf 'null' ;;
        *) printf '%s' "$1" ;;
    esac
}

# ----------------------------------------------------------------------
# environment / root / kernel
# ----------------------------------------------------------------------

km_disc_env() {
    _ke_kernel=$(uname -r 2>/dev/null)
    _ke_arch=$(uname -m 2>/dev/null)
    _ke_abis=$(getprop ro.product.cpu.abi 2>/dev/null)
    _ke_android=$(getprop ro.build.version.release 2>/dev/null)
    _ke_device=$(getprop ro.product.device 2>/dev/null)
    _ke_model=$(getprop ro.product.model 2>/dev/null)
    _ke_bootid=$(head -n1 /proc/sys/kernel/random/boot_id 2>/dev/null)
    _ke_up=$(head -n1 /proc/uptime 2>/dev/null | awk '{print int($1)}')

    km_reg env.kernel    "Kernel version"     "/proc/version"  "procfs" "r" info   str 90 "$_ke_kernel"   "$(head -n1 /proc/version 2>/dev/null)"
    km_reg env.arch      "Architecture"       "uname -m"       "env"    "r" info   str 90 "$_ke_arch"     ""
    km_reg env.abis      "CPU ABIs"           "getprop"        "env"    "r" info   str 80 "$_ke_abis"    ""
    km_reg env.android   "Android version"    "getprop"        "env"    "r" info   str 80 "$_ke_android" ""
    km_reg env.device    "Device codename"    "getprop"        "env"    "r" info   str 80 "$_ke_device"  ""
    km_reg env.model     "Model"              "getprop"        "env"    "r" info   str 80 "$_ke_model"   ""
    km_reg env.boot_id   "Boot id"            "/proc/sys/kernel/random/boot_id" "procfs" "r" info str 85 "$_ke_bootid" "changes across reboots"
    km_reg env.uptime    "Uptime (s)"         "/proc/uptime"   "procfs" "r" info   int 90 "$_ke_up"      ""

    # Root-management environments. Detected, never assumed.
    _ke_root="none"
    [ -d /data/adb/magisk ]      && _ke_root="magisk"
    [ -d /data/adb/kernelsu ]    && _ke_root="${_ke_root:+$_ke_root+}kernelsu"
    [ -f /data/adb/ap ]          && _ke_root="${_ke_root:+$_ke_root+}apatch"
    _ke_seln=""
    [ -r /sys/fs/selinux/enforce ] && _ke_seln=$(head -n1 /sys/fs/selinux/enforce 2>/dev/null)
    case "$_ke_seln" in 1) _ke_seln="enforcing" ;; 0) _ke_seln="permissive" ;; *) _ke_seln="unknown" ;; esac
    km_reg env.root        "Root environment" "filesystem"     "env"    "r" info   str 70 "$_ke_root"     "detected by well-known paths"
    km_reg env.selinux     "SELinux"          "/sys/fs/selinux/enforce" "sysfs" "r" protected str 85 "$_ke_seln" "HPC never changes this"
}

# ----------------------------------------------------------------------
# CPU
# ----------------------------------------------------------------------

km_disc_cpu() {
    _kc_np=0
    for _kc_pol in $(detect_policies 2>/dev/null); do
        [ -d "$_kc_pol" ] || continue
        _kc_np=$((_kc_np + 1))
        _kc_id="cpu${_kc_np}"
        _kc_cpulabel=$(read_node "$_kc_pol/related_cpus" 2>/dev/null)
        [ -n "$_kc_cpulabel" ] || _kc_cpulabel=$(read_node "$_kc_pol/affected_cpus" 2>/dev/null)
        [ -n "$_kc_cpulabel" ] || _kc_cpulabel=$(printf '%s' "$_kc_pol" | awk -F/ '{print $NF}')

        _kc_gov=$(read_node "$_kc_pol/scaling_governor" 2>/dev/null)
        _kc_govs=$(read_node "$_kc_pol/scaling_available_governors" 2>/dev/null)
        _kc_cur=$(read_node "$_kc_pol/scaling_cur_freq" 2>/dev/null)
        [ -n "$_kc_cur" ] || _kc_cur=$(read_node "$_kc_pol/cpuinfo_cur_freq" 2>/dev/null)
        _kc_smin=$(read_node "$_kc_pol/scaling_min_freq" 2>/dev/null)
        _kc_smax=$(read_node "$_kc_pol/scaling_max_freq" 2>/dev/null)
        _kc_hmin=$(read_node "$_kc_pol/cpuinfo_min_freq" 2>/dev/null)
        _kc_hmax=$(read_node "$_kc_pol/cpuinfo_max_freq" 2>/dev/null)
        _kc_freqs=$(read_node "$_kc_pol/scaling_available_frequencies" 2>/dev/null)

        case "$_kc_smin$_kc_smax" in ''|*[!0-9]*) _kc_rw=0 ;; *) _kc_rw=1 ;; esac
        if [ "$_kc_rw" = "1" ] && node_writable "$_kc_pol/scaling_governor" 2>/dev/null; then
            km_reg "$_kc_id.governor" "Governor (cluster $_kc_cpulabel)" "$_kc_pol/scaling_governor" "sysfs" "rw" low enum 95 "$_kc_gov" "available: $_kc_govs"
        else
            km_reg "$_kc_id.governor" "Governor (cluster $_kc_cpulabel)" "$_kc_pol/scaling_governor" "sysfs" "r" low enum 95 "$_kc_gov" "available: $_kc_govs"
        fi
        if [ "$_kc_rw" = "1" ] && node_writable "$_kc_pol/scaling_max_freq" 2>/dev/null; then
            km_reg "$_kc_id.max_freq" "Max freq (cluster $_kc_cpulabel)" "$_kc_pol/scaling_max_freq" "sysfs" "rw" med int 95 "$_kc_smax" "hw range: ${_kc_hmin}-${_kc_hmax} kHz; steps: ${_kc_freqs:-any}"
        else
            km_reg "$_kc_id.max_freq" "Max freq (cluster $_kc_cpulabel)" "$_kc_pol/scaling_max_freq" "sysfs" "r" med int 95 "$_kc_smax" "hw range: ${_kc_hmin}-${_kc_hmax} kHz"
        fi
        if [ "$_kc_rw" = "1" ] && node_writable "$_kc_pol/scaling_min_freq" 2>/dev/null; then
            km_reg "$_kc_id.min_freq" "Min freq (cluster $_kc_cpulabel)" "$_kc_pol/scaling_min_freq" "sysfs" "rw" med int 95 "$_kc_smin" "hw range: ${_kc_hmin}-${_kc_hmax} kHz"
        else
            km_reg "$_kc_id.min_freq" "Min freq (cluster $_kc_cpulabel)" "$_kc_pol/scaling_min_freq" "sysfs" "r" med int 95 "$_kc_smin" "hw range: ${_kc_hmin}-${_kc_hmax} kHz"
        fi
        km_reg "$_kc_id.cur_freq" "Current freq (cluster $_kc_cpulabel)" "$_kc_pol/scaling_cur_freq" "sysfs" "r" info int 80 "$_kc_cur" ""
        # vendor-specific knobs, only if they exist on THIS kernel
        for _kc_v in hispeed_freq up_rate_limit_us down_rate_limit_us hispeed_load; do
            if [ -f "$_kc_pol/$_kc_v" ]; then
                _kc_vv=$(read_node "$_kc_pol/$_kc_v" 2>/dev/null)
                km_reg "$_kc_id.$_kc_v" "vendor: $_kc_v (cluster $_kc_cpulabel)" "$_kc_pol/$_kc_v" "sysfs" "rw" low int 70 "$_kc_vv" "vendor-specific, not standard cpufreq"
            fi
        done
    done
    # core online state (one capability, aggregate)
    km_reg cpu.online "Core online/offline" "$CPU_SYS/cpu[0-9]*/online" "sysfs" "r" info str 85 "$(cpu_online_state 2>/dev/null)" "format: on/total"
}

# ----------------------------------------------------------------------
# GPU
# ----------------------------------------------------------------------

km_disc_gpu() {
    _kg_path=$(detect_gpu_path 2>/dev/null) || {
        km_reg gpu.path "GPU control path" "-" "sysfs" "-" info str 60 "" "no known GPU sysfs interface exposed"
        return 0
    }
    _kg_vendor=$(detect_gpu_vendor "$_kg_path")
    km_reg gpu.path "GPU control path" "$_kg_path" "sysfs" "r" info str 90 "$_kg_path" "vendor: $_kg_vendor"
    _kg_caps=$(detect_gpu_caps "$_kg_path")
    case " $_kg_caps " in
        *" governor "*)
            _kg_g=$(read_node "$_kg_path/devfreq/governor" 2>/dev/null)
            _kg_ga=$(read_node "$_kg_path/devfreq/available_governors" 2>/dev/null)
            km_reg gpu.governor "GPU governor" "$_kg_path/devfreq/governor" "sysfs" "rw" low enum 80 "$_kg_g" "available: $_kg_ga"
            ;;
    esac
    case " $_kg_caps " in
        *" min_freq "*)
            _kg_m=$(read_node "$_kg_path/devfreq/min_freq" 2>/dev/null)
            _kg_mh=$(read_node "$_kg_path/devfreq/min_freq_limit" 2>/dev/null)
            _kg_Mh=$(read_node "$_kg_path/devfreq/max_freq_limit" 2>/dev/null)
            km_reg gpu.min_freq "GPU min freq" "$_kg_path/devfreq/min_freq" "sysfs" "rw" med int 80 "$_kg_m" "hw limits: ${_kg_mh:-?}-${_kg_Mh:-?} kHz"
            ;;
    esac
    case " $_kg_caps " in
        *" max_freq "*)
            _kg_M=$(read_node "$_kg_path/devfreq/max_freq" 2>/dev/null)
            _kg_Mh=$(read_node "$_kg_path/devfreq/max_freq_limit" 2>/dev/null)
            _kg_mh=$(read_node "$_kg_path/devfreq/min_freq_limit" 2>/dev/null)
            km_reg gpu.max_freq "GPU max freq" "$_kg_path/devfreq/max_freq" "sysfs" "rw" med int 80 "$_kg_M" "hw limits: ${_kg_mh:-?}-${_kg_Mh:-?} kHz"
            ;;
    esac
    case " $_kg_caps " in
        *" busy_pct "*)
            km_reg gpu.busy "GPU busy %" "$_kg_path/gpu_busy_percentage" "sysfs" "r" info int 85 "$(read_node "$_kg_path/gpu_busy_percentage" 2>/dev/null)" ""
            ;;
    esac
    case " $_kg_caps " in
        *" gpuclk "*)
            km_reg gpu.clock "GPU clock (kHz)" "$_kg_path/gpuclk" "sysfs" "r" info int 85 "$(read_node "$_kg_path/gpuclk" 2>/dev/null)" "0 usually means clocked down to sleep"
            ;;
    esac
    case " $_kg_caps " in
        *" throttling "*)
            _kg_t=$(read_node "$_kg_path/throttling" 2>/dev/null)
            km_reg gpu.throttling "GPU thermal throttling state" "$_kg_path/throttling" "sysfs" "r" info str 85 "$_kg_t" "read-only observation; HPC never bypasses it"
            ;;
    esac
    case " $_kg_caps " in
        *" idle_timer "*)
            km_reg gpu.idle_timer "GPU idle timer (ms)" "$_kg_path/idle_timer" "sysfs" "rw" low int 70 "$(read_node "$_kg_path/idle_timer" 2>/dev/null)" "vendor kgsl"
            ;;
    esac
    case " $_kg_caps " in
        *" force_clk "*)
            km_reg gpu.force_clk "GPU force clock on/off" "$_kg_path/force_clk_on" "sysfs" "rw" low flag 70 "$(read_node "$_kg_path/force_clk_on" 2>/dev/null)" "vendor kgsl"
            ;;
    esac
}

# ----------------------------------------------------------------------
# memory / zram
# ----------------------------------------------------------------------

km_disc_mem() {
    _km_tot=0; _km_free=0; _km_avail=0; _km_cache=0; _km_swap=0; _km_swapfree=0
    if [ -r /proc/meminfo ]; then
        _km_tot=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
        _km_free=$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)
        _km_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
        _km_cache=$(awk '/^Cached:/{print $2}' /proc/meminfo 2>/dev/null)
        _km_swap=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)
        _km_swapfree=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)
    fi
    km_reg mem.ram "RAM total/free/available" "/proc/meminfo" "procfs" "r" info str 95 "${_km_tot:-0}/${_km_free:-0}/${_km_avail:-0} kB" "total/free/available"
    km_reg mem.swap "Swap total/free" "/proc/meminfo" "procfs" "r" info str 95 "${_km_swap:-0}/${_km_swapfree:-0} kB" "total/free"
    [ -r /proc/pressure/memory ] && km_reg mem.psi "Memory pressure (PSI)" "/proc/pressure/memory" "procfs" "r" info str 80 "" "some/full average pressure" || \
        km_reg mem.psi "Memory pressure (PSI)" "/proc/pressure/memory" "procfs" "-" info str 60 "" "not exposed by this kernel"

    _km_z=$(detect_zram 2>/dev/null) || {
        km_reg zram.path "zRAM device" "-" "sysfs" "-" info str 70 "" "no zram block device present"
        return 0
    }
    _km_zs=$(read_node "$_km_z/disksize" 2>/dev/null)
    _km_za=$(read_node "$_km_z/compr_alg" 2>/dev/null)
    km_reg zram.path "zRAM device" "$_km_z" "sysfs" "r" info str 90 "$_km_z" "disksize: ${_km_zs:-0} B, algorithm: ${_km_za:-?}"
    [ -f "$_km_z/mem_swappiness" ] && \
        km_reg zram.swappiness "zRAM mem_swappiness" "$_km_z/mem_swappiness" "sysfs" "rw" low int 85 "$(read_node "$_km_z/mem_swappiness" 2>/dev/null)" "0-200"
    [ -f "$_km_z/init_state" ] || km_reg zram.active "zRAM active" "$_km_z/init_state" "sysfs" "r" info str 80 "$(read_node "$_km_z/init_state" 2>/dev/null)" ""
}

# ----------------------------------------------------------------------
# thermal
# ----------------------------------------------------------------------

km_disc_thermal() {
    _kt_n=0
    for _kt_line in $(detect_thermal_zones 2>/dev/null); do
        [ -n "$_kt_line" ] || continue
        _kt_n=$((_kt_n + 1))
        _kt_z="${_kt_line%%:*}"
        _kt_t="${_kt_line#*:}"
        _kt_c=$(read_temp_c "$_kt_z" 2>/dev/null)
        _kt_mode=$(read_node "$_kt_z/mode" 2>/dev/null)
        if [ -n "$_kt_mode" ] && node_writable "$_kt_z/mode" 2>/dev/null; then
            _kt_rw=rw; _kt_risk=protected
        else
            _kt_rw=r; _kt_risk=protected
        fi
        km_reg "thermal.t${_kt_n}" "sensor: $_kt_t" "$_kt_z/temp" "sysfs" "$_kt_rw" "$_kt_risk" int 90 "${_kt_c} C" "mode: ${_kt_mode:-?}; writing mode/thresholds is protected by HPC policy"
    done
    [ "$_kt_n" -eq 0 ] && km_reg thermal.none "No thermal zones" "-" "sysfs" "-" info str 70 "" "/sys/class/thermal empty or unreadable"
    _kt_th=$(detect_thermal_throttling 2>/dev/null)
    if [ -n "$_kt_th" ]; then
        km_reg thermal.state "Kernel thermal throttling state" "msm_thermal" "sysfs" "r" info str 75 "$_kt_th" "vendor msm_thermal"
    fi
}

# ----------------------------------------------------------------------
# battery / power
# ----------------------------------------------------------------------

# km_battery_supplies - the set of power-supply dirs to probe.
# (helper, so device adapters / test fixtures can point it elsewhere)
km_battery_supplies() { printf '%s\n' /sys/class/power_supply/*; }

km_disc_battery() {
    for _kb_ps in $(km_battery_supplies); do
        [ -d "$_kb_ps" ] || continue
        _kb_name="${_kb_ps##*/}"
        _kb_type=$(read_node "$_kb_ps/type" 2>/dev/null)
        case "$_kb_type" in
            Battery|battery) _kb_main=1 ;;
            *) [ -n "${_kb_main:-}" ] && continue ;;   # after the battery, stop adding supplies
        esac
        _kb_cap=$(read_node "$_kb_ps/capacity" 2>/dev/null)
        _kb_stat=$(read_node "$_kb_ps/status" 2>/dev/null)
        _kb_volt=$(read_node "$_kb_ps/voltage_now" 2>/dev/null)
        _kb_curr=$(read_node "$_kb_ps/current_now" 2>/dev/null)
        _kb_temp=$(read_node "$_kb_ps/temp" 2>/dev/null)
        _kb_health=$(read_node "$_kb_ps/health" 2>/dev/null)
        _kb_cycles=$(read_node "$_kb_ps/cycle_count" 2>/dev/null)
        km_reg "battery.$_kb_name" "power supply: $_kb_name" "$_kb_ps" "sysfs" "r" info str 90 \
            "cap=${_kb_cap:-?}% status=${_kb_stat:-?}" \
            "voltage=${_kb_volt:-?}uV current=${_kb_curr:-?}uA temp=${_kb_temp:-?} health=${_kb_health:-?} cycles=${_kb_cycles:-?}"
        # Charging LIMIT is only a real capability when the hardware/ROM
        # actually exposes a writable limit node. Probed, never assumed.
        for _kb_l in charge_control_limit charge_limit battery_charge_control charge_term; do
            if [ -f "$_kb_ps/$_kb_l" ] && node_writable "$_kb_ps/$_kb_l" 2>/dev/null; then
                km_reg "battery.$_kb_name.limit" "charge limit ($_kb_l)" "$_kb_ps/$_kb_l" "sysfs" "rw" med int 60 "$(read_node "$_kb_ps/$_kb_l" 2>/dev/null)" "vendor-provided; semantics differ per ROM"
            fi
        done
    done
    [ -n "${_kb_main:-}" ] || km_reg battery.none "No battery supply" "-" "sysfs" "-" info str 60 "" "no readable power supply"
}

# ----------------------------------------------------------------------
# storage / IO
# ----------------------------------------------------------------------

km_disc_storage() {
    _ks_n=0
    for _ks_d in $(km_block_devices 2>/dev/null); do
        [ -d "$_ks_d" ] || continue
        _ks_n=$((_ks_n + 1))
        _ks_name="${_ks_d##*/}"
        _ks_sched=$(read_node "$_ks_d/queue/scheduler" 2>/dev/null)
        _ks_sched_cur=$(printf '%s' "$_ks_sched" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
        if node_writable "$_ks_d/queue/scheduler" 2>/dev/null; then
            km_reg "io.${_ks_name}.scheduler" "IO scheduler ($_ks_name)" "$_ks_d/queue/scheduler" "sysfs" "rw" low enum 90 "${_ks_sched_cur:-?}" "available: $(printf '%s' "$_ks_sched" | tr -d '[]')"
        else
            km_reg "io.${_ks_name}.scheduler" "IO scheduler ($_ks_name)" "$_ks_d/queue/scheduler" "sysfs" "r" low enum 90 "${_ks_sched_cur:-?}" "available: $(printf '%s' "$_ks_sched" | tr -d '[]')"
        fi
        for _ks_q in read_ahead_kb nr_requests add_random iostats; do
            [ -f "$_ks_d/queue/$_ks_q" ] || continue
            _ks_qv=$(read_node "$_ks_d/queue/$_ks_q" 2>/dev/null)
            case "$_ks_q" in
                read_ahead_kb) _ks_risk=low; _ks_type=int ;;
                nr_requests)   _ks_risk=low; _ks_type=int ;;
                add_random)    _ks_risk=low; _ks_type=flag ;;
                iostats)       _ks_risk=low; _ks_type=flag ;;
            esac
            if node_writable "$_ks_d/queue/$_ks_q" 2>/dev/null; then
                km_reg "io.${_ks_name}.$_ks_q" "queue: $_ks_q ($_ks_name)" "$_ks_d/queue/$_ks_q" "sysfs" "rw" "$_ks_risk" "$_ks_type" 85 "$_ks_qv" ""
            else
                km_reg "io.${_ks_name}.$_ks_q" "queue: $_ks_q ($_ks_name)" "$_ks_d/queue/$_ks_q" "sysfs" "r" "$_ks_risk" "$_ks_type" 85 "$_ks_qv" ""
            fi
        done
        # /proc/diskstats: fields 3,4 (reads completed), 7,8 (writes completed),
        # 12 (io time in ms). Present on all Linux kernels - but read it,
        # don't assume.
        if [ -r /proc/diskstats ]; then
            _ks_ds=$(awk -v n="$_ks_name" '$9==n {print $4, $8, $13; exit}' /proc/diskstats 2>/dev/null)
            [ -n "$_ks_ds" ] && km_reg "io.${_ks_name}.stats" "IO counters ($_ks_name)" "/proc/diskstats" "procfs" "r" info str 90 "$_ks_ds" "reads, writes, io_time_ms (cumulative)"
        fi
    done
    [ "$_ks_n" -eq 0 ] && km_reg io.none "No block devices" "-" "sysfs" "-" info str 60 "" "no sd/mmcblk/nvme devices found"
}

# ----------------------------------------------------------------------
# network
# ----------------------------------------------------------------------

km_disc_net() {
    _kn_n=0
    for _kn_if in /sys/class/net/*; do
        [ -d "$_kn_if" ] || continue
        _kn_n=$((_kn_n + 1))
        _kn_name="${_kn_if##*/}"
        _kn_mtu=$(read_node "$_kn_if/mtu" 2>/dev/null)
        _kn_state=$(read_node "$_kn_if/operstate" 2>/dev/null)
        km_reg "net.${_kn_name}" "interface: $_kn_name" "$_kn_if" "sysfs" "r" info str 90 "mtu=${_kn_mtu:-?} state=${_kn_state:-?}" ""
    done
    [ "$_kn_n" -eq 0 ] && km_reg net.none "No network interfaces" "-" "sysfs" "-" info str 50 "" ""
    # TCP congestion control
    _kn_tcp_avail=$(read_node /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
    if [ -n "$_kn_tcp_avail" ]; then
        _kn_tcp_def=$(read_node /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
        if node_writable /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
            km_reg net.tcp_cc "TCP congestion control" "/proc/sys/net/ipv4/tcp_congestion_control" "procfs" "rw" low enum 85 "${_kn_tcp_def:-?}" "available: $_kn_tcp_avail"
        else
            km_reg net.tcp_cc "TCP congestion control" "/proc/sys/net/ipv4/tcp_congestion_control" "procfs" "r" low enum 85 "${_kn_tcp_def:-?}" "available: $_kn_tcp_avail"
        fi
    else
        km_reg net.tcp_cc "TCP congestion control" "-" "procfs" "-" info str 60 "" "not exposed"
    fi
    [ -r /proc/net/sockstat ] && km_reg net.sockstat "Socket stats" "/proc/net/sockstat" "procfs" "r" info str 85 "" "TCP/UDP socket counts"
    # queueing disciplines only when tc exists - never fake it
    if command -v tc >/dev/null 2>&1; then
        _kn_q=$(tc qdisc show 2>/dev/null | head -n 8 | tr '\n' ' ')
        km_reg net.qdisc "Queueing disciplines" "tc qdisc show" "tool" "r" info str 80 "$_kn_q" "requires tc"
    else
        km_reg net.qdisc "Queueing disciplines" "tc" "tool" "-" info str 50 "" "tc not available"
    fi
}

# ----------------------------------------------------------------------
# scheduler
# ----------------------------------------------------------------------

km_disc_sched() {
    if [ -r /sys/kernel/debug/sched_features ]; then
        km_reg sched.features "Scheduler features" "/sys/kernel/debug/sched_features" "sysfs" "rw" med str 80 "$(read_node /sys/kernel/debug/sched_features 2>/dev/null)" "toggle format: [NO]FEATURE; debugfs"
    else
        km_reg sched.features "Scheduler features" "/sys/kernel/debug/sched_features" "sysfs" "-" med str 50 "" "debugfs not readable (normal on many Android builds)"
    fi
    _kn_walt=""
    for _kn_w in /proc/sys/walt/*; do
        [ -f "$_kn_w" ] || continue
        _kn_walt="${_kn_walt} ${_kn_w##*/}"
    done
    if [ -n "$_kn_walt" ]; then
        km_reg sched.walt "WALT (vendor) parameters" "/proc/sys/walt" "procfs" "rw" low str 75 "$(printf '%s' "$_kn_walt" | wc -w | tr -d ' ') keys" "Qualcomm WALT; vendor-specific semantics"
    fi
    _kn_st=$(detect_stune 2>/dev/null)
    [ -n "$_kn_st" ] && km_reg sched.stune "cgroup schedtune" "$_kn_st" "cgroup" "r" low str 85 "$_kn_st" "per-app CPU weight control"
    for _kn_c in sched_min_granularity_ns sched_wakeup_granularity_ns sched_migration_cost_ns; do
        [ -f "/proc/sys/kernel/$_kn_c" ] && \
            km_reg "sched.$_kn_c" "sched: $_kn_c" "/proc/sys/kernel/$_kn_c" "procfs" "rw" med int 80 "$(read_node "/proc/sys/kernel/$_kn_c" 2>/dev/null)" "CFS tuning; vendor kernels may override"
    done
}

# ----------------------------------------------------------------------
# kernel modules / kernel log
# ----------------------------------------------------------------------

km_disc_modules() {
    if [ -r /proc/modules ]; then
        _km_mods=$(wc -l < /proc/modules 2>/dev/null | tr -d ' ')
        _km_mods=${_km_mods:-0}
        if [ "$_km_mods" -gt 0 ]; then
            km_reg mods.list "Loaded kernel modules" "/proc/modules" "procfs" "r" info int 80 "$_km_mods" "visible to this container"
        else
            km_reg mods.list "Loaded kernel modules" "/proc/modules" "procfs" "r" info str 70 "restricted" "file readable but empty - Android commonly hides the module list"
        fi
    else
        km_reg mods.list "Loaded kernel modules" "/proc/modules" "procfs" "-" info str 60 "" "not readable"
    fi
    # root-management module visibility
    if [ -d /data/adb/modules ]; then
        _km_nm=$(find /data/adb/modules -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        km_reg mods.magisk "Magisk modules" "/data/adb/modules" "fs" "r" info int 90 "${_km_nm:-0}" "directories present"
    fi
    if [ -r /proc/dmesg_restrict ]; then
        km_reg klog.restrict "dmesg_restrict" "/proc/sys/kernel/dmesg_restrict" "procfs" "rw" protected flag 85 "$(read_node /proc/dmesg_restrict 2>/dev/null)" "controlled by the kernel; HPC will not relax it"
    fi
    if dmesg >/dev/null 2>&1 && dmesg 2>/dev/null | head -n 1 | grep -q .; then
        km_reg klog.dmesg "Kernel log (dmesg)" "dmesg" "tool" "r" info str 90 "readable" "recent lines available for diagnostics"
    else
        km_reg klog.dmesg "Kernel log (dmesg)" "dmesg" "tool" "-" info str 80 "restricted" "dmesg not readable from this context - kernel diagnostics will be limited"
    fi
}

# ----------------------------------------------------------------------
# main entry
# ----------------------------------------------------------------------

km_caps_scan() {
    [ -d "$KM_CAPS_DIR" ] || mkdir -p "$KM_CAPS_DIR" 2>/dev/null
    _km_reg_rows=""
    _km_reg_count=0

    km_disc_env
    # Magisk environment (version/zygisk/denylist/backend); no-op under
    # other root environments or when magisk_sys.sh is not loaded.
    km_magisk_scan 2>/dev/null
    km_disc_cpu
    km_disc_gpu
    km_disc_mem
    km_disc_thermal
    km_disc_battery
    km_disc_storage
    km_disc_net
    km_disc_sched
    km_disc_modules

    # --- merge plugin-registered capabilities (id name path risk type det)
    if [ -f "$HPC_STATE/plugin_caps.tsv" ]; then
        while IFS="$(printf '\t')" read -r pc_id pc_name pc_path pc_risk pc_type pc_det; do
            [ -n "$pc_id" ] || continue
            _pc_rw="-"
            [ -e "$pc_path" ] && { [ -r "$pc_path" ] && _pc_rw="r"; [ -w "$pc_path" ] && _pc_rw="rw"; }
            _pc_val=""
            [ "$_pc_rw" != "-" ] && _pc_val=$(head -n1 "$pc_path" 2>/dev/null)
            km_reg "$pc_id" "$pc_name" "$pc_path" "plugin" "$_pc_rw" "$pc_risk" "$pc_type" 65 "$_pc_val" "$pc_det"
        done <"$HPC_STATE/plugin_caps.tsv"
    fi

    # --- persist (atomic-ish)
    printf '%s' "$_km_reg_rows" >"$KM_REG_TSV.tmp" 2>/dev/null
    mv -f "$KM_REG_TSV.tmp" "$KM_REG_TSV" 2>/dev/null || rm -f "$KM_REG_TSV.tmp" 2>/dev/null

    # --- change detection vs previous scan
    # a capability is "lost" when it had an interface last scan (rw != "-")
    # and now has none (row gone or rw back to "-")
    if [ -f "$KM_PREV_TSV" ] && [ -s "$KM_PREV_TSV" ]; then
        _km_lost=$(awk -F '\t' '
            NR==FNR { if ($5 != "-") prev[$1] = 1; next }
            $5 != "-" { keep[$1] = 1 }
            END { for (id in prev) if (!(id in keep)) print id }
        ' "$KM_PREV_TSV" "$KM_REG_TSV" 2>/dev/null)
        if [ -n "$_km_lost" ]; then
            for _l in $_km_lost; do
                [ -n "$_l" ] && km_event cap_lost "capability disappeared: $_l" 2>/dev/null
            done
        fi
    fi
    cp -f "$KM_REG_TSV" "$KM_PREV_TSV" 2>/dev/null

    # --- JSON summary for the WebUI
    km_caps_json >"$KM_SUM_JSON" 2>/dev/null
    chmod 0700 "$KM_CAPS_DIR" 2>/dev/null
    chmod 0600 "$KM_REG_TSV" "$KM_PREV_TSV" "$KM_SUM_JSON" 2>/dev/null

    log_debug "km caps scan: $_km_reg_count capabilities"
    return 0
}

# km_caps_json - emit the full capability registry as JSON.
# Fields per control: id name path kind rw risk type conf value detail
# Performance note: the old version forked km_jesc (a sed+tr pipeline)
# 10x per row - ~2000 process spawns per scan on a real device, which
# made every capability scan take seconds and, via the WebUI poll
# cadence, made the UI feel slow. Now the whole TSV is escaped in ONE
# tr + ONE sed pass; the row loop is pure printf (no forks).
km_caps_json() {
    _kj_ts=$(km_now_ms)
    _kj_kernel=$(km_jesc "$(uname -r 2>/dev/null)")
    _kj_arch=$(km_jesc "$(uname -m 2>/dev/null)")
    _kj_root=$( [ -d /data/adb/magisk ] && printf 'magisk' || \
                [ -d /data/adb/kernelsu ] && printf 'kernelsu' || \
                [ -f /data/adb/ap ] && printf 'apatch' || printf 'none' )
    printf '{"ts":%s,"count":%s,"kernel":%s,"arch":%s,"root_env":%s,"controls":[' \
        "$_kj_ts" "$_km_reg_count" "$_kj_kernel" "$_kj_arch" "$(km_jesc "$_kj_root")"

    _first=1
    if [ -f "$KM_REG_TSV" ]; then
        # strip control chars (keep \t and \n: field/line separators),
        # then escape backslashes and quotes for JSON - one pipeline.
        _kj_esc="${KM_REG_TSV}.jesc"
        tr -d '\000\001-\010\013-\037\177' <"$KM_REG_TSV" 2>/dev/null | \
            sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' >"$_kj_esc" 2>/dev/null
        while IFS="$(printf '\t')" read -r c_id c_name c_path c_kind c_rw c_risk c_type c_conf c_val c_det; do
            [ -n "$c_id" ] || continue
            [ "$_first" = "1" ] || printf ','
            _first=0
            printf '{"id":"%s","name":"%s","path":"%s","kind":"%s","rw":"%s","risk":"%s","type":"%s","conf":%s,"value":"%s","detail":"%s"}' \
                "$c_id" "$c_name" "$c_path" "$c_kind" "$c_rw" "$c_risk" "$c_type" \
                "${c_conf:-null}" "$c_val" "$c_det"
        done <"$_kj_esc"
        rm -f "$_kj_esc" 2>/dev/null
    fi
    printf ']}\n'
}

# shell convenience: print one control's value from the registry
km_caps_get() {
    # km_caps_get ID -> value (field 9) or empty
    [ -f "$KM_REG_TSV" ] || return 1
    awk -F '\t' -v k="$1" '$1==k {print $9; exit}' "$KM_REG_TSV" 2>/dev/null
    return 0
}
