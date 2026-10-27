#!/bin/sh
# HPC test harness - simulates the device environment under tests/fake
#
# The point is to test the REAL production code (safety.sh, detector.sh,
# kernel_manager.sh, km_*.sh) against a fake sysfs tree and stubbed
# Android-only commands - NOT a parallel reimplementation.
# shellcheck disable=SC3043

T="${T:-$(mktemp -d /tmp/hpctest.XXXXXX)}"
MOD="$(cd "$(dirname "$0")/.." && pwd)"
export HPC_DATA="$T/data"
export HPC_STATE="$T/data/state"
export HPC_MODDIR="$T/mod"
HPC_SCRIPTS="$MOD/scripts"

mkdir -p "$HPC_STATE" "$T/data/logs" "$T/mod/config/profiles" "$T/mod/plugins" "$T/mod/webroot/cgi-bin"
chmod 0700 "$HPC_DATA" 2>/dev/null
# minimal WebUI assets so read-only integrity checks (km_doctor) can run
: >"$T/mod/webroot/index.html" 2>/dev/null
: >"$T/mod/webroot/cgi-bin/api.sh" 2>/dev/null

# ---------------------------------------------------------------- stubs
# Android-only commands / environment
getprop() {
    case "$1" in
        ro.product.device)  printf 'vayu' ;;
        ro.product.model)   printf 'POCO X3 Pro' ;;
        ro.build.version.release) printf '13' ;;
        ro.product.cpu.abi) printf 'arm64-v8a' ;;
        ro.serialno)        printf 'FAKESERIAL123' ;;
        sys.boot_completed) printf '1' ;;
        *) printf '' ;;
    esac
}
log_info()      { [ "${HPC_TEST_VERBOSE:-0}" = "1" ] && printf 'INFO  %s\n' "$*" >&2; return 0; }
log_debug()     { return 0; }
log_warn()      { [ "${HPC_TEST_VERBOSE:-0}" = "1" ] && printf 'WARN  %s\n' "$*" >&2; return 0; }
log_unsupported() { return 0; }
hpc_log_init()  { return 0; }
# dmesg: a FUNCTION always wins over the binary in PATH, so the fake
# kernel log is deterministic in every test environment.
dmesg() {
    printf '[123.456] msm_thermal: thermal error detected (simulated)\n'
    printf '[124.001] kgsl-3d0: GPU shader error detected (simulated)\n'
    printf '[124.500] mmcblk0: I/O error while writing (simulated)\n'
}

# ---------------------------------------------------------------- fake tree
fake_tree() {
    # two CPU policies
    for spec in "pol0:0-3:300000:1804800" "pol1:4-7:300000:2841600"; do
        _n="${spec%%:*}"; _rest="${spec#*:}"
        _cpus="${_rest%%:*}"; _rest="${_rest#*:}"
        _lo="${_rest%%:*}"; _hi="${_rest#*:}"
        _d="$T/sys/cpu/cpufreq/$_n"
        mkdir -p "$_d"
        printf 'schedutil\n'        >"$_d/scaling_governor"
        printf 'schedutil performance powersave ondemand\n' >"$_d/scaling_available_governors"
        printf '%s\n' "$(( (_hi + _lo) / 2 ))" >"$_d/scaling_cur_freq"
        printf '%s\n' "$_lo"      >"$_d/scaling_min_freq"
        printf '%s\n' "$_hi"      >"$_d/scaling_max_freq"
        printf '%s\n' "$_lo"      >"$_d/cpuinfo_min_freq"
        printf '%s\n' "$_hi"      >"$_d/cpuinfo_max_freq"
        printf '%s\n' "$(( (_hi + _lo) / 2 ))" >"$_d/scaling_available_frequencies"
        printf '%s\n' "$_cpus"    >"$_d/related_cpus"
    done
    # block device
    _b="$T/sys/block/mmcblk0/queue"
    mkdir -p "$_b"
    printf '[mq-deadline] cfq none\n' >"$_b/scheduler"
    printf '128\n' >"$_b/read_ahead_kb"
    printf '128\n' >"$_b/nr_requests"
    printf '0\n'   >"$_b/add_random"
    # /proc fixtures (vm + net knobs, redirected via HPC_PROC_SYS)
    _pr="$T/proc/sys"
    mkdir -p "$_pr/vm" "$_pr/net/ipv4"
    printf '10\n'   >"$_pr/vm/swappiness"
    printf '100\n'  >"$_pr/vm/vfs_cache_pressure"
    printf 'cubic\n' >"$_pr/net/ipv4/tcp_congestion_control"
    printf 'cubic reno\n' >"$_pr/net/ipv4/tcp_available_congestion_control"
    # GPU (kgsl)
    _g="$T/sys/kgsl/kgsl-3d0"
    mkdir -p "$_g/devfreq"
    printf '500000\n' >"$_g/gpuclk"
    printf '12\n'     >"$_g/gpu_busy_percentage"
    printf '1\n'      >"$_g/throttling"
    printf 'msm-adreno-tz\n' >"$_g/devfreq/governor"
    printf 'msm-adreno-tz performance simple_ondemand powersave\n' >"$_g/devfreq/available_governors"
    printf '300000\n'  >"$_g/devfreq/min_freq"
    printf '550000\n'  >"$_g/devfreq/min_freq"
    printf '750000\n'  >"$_g/devfreq/max_freq"
    printf '300000\n'  >"$_g/devfreq/min_freq_limit"
    printf '750000\n'  >"$_g/devfreq/max_freq_limit"
    printf '100\n'     >"$_g/idle_timer"
    printf '0\n'       >"$_g/force_clk_on"
    # zram
    _z="$T/sys/block/zram0"
    mkdir -p "$_z"
    printf '2147483648\n' >"$_z/disksize"
    printf 'lzo-rle\n'    >"$_z/compr_alg"
    printf '100\n'        >"$_z/mem_swappiness"
    printf '1048576\n'    >"$_z/mm_used"
    printf '5242880\n'    >"$_z/orig_data_size"
    # thermal zones (mode is READ-ONLY: protected)
    _tz="$T/sys/thermal/thermal_zone0"
    mkdir -p "$_tz"
    printf 'cpu-0-0-usr\n' >"$_tz/type"
    printf '45000\n'       >"$_tz/temp"
    printf 'enabled\n'     >"$_tz/mode"
    chmod 0444 "$_tz/mode"
    # battery
    _bt="$T/sys/power_supply/battery"
    mkdir -p "$_bt"
    printf 'Battery\n' >"$_bt/type"
    printf '80\n'      >"$_bt/capacity"
    printf 'Discharging\n' >"$_bt/status"
    printf '4000000\n' >"$_bt/voltage_now"
    printf '%s\n' -250000 >"$_bt/current_now"
    printf '350\n'     >"$_bt/temp"
    printf 'Good\n'    >"$_bt/health"
    printf '4200000\n' >"$_bt/charge_full"
    printf '4500000\n' >"$_bt/charge_full_design"
}

# ---------------------------------------------------------------- point the
# discovery functions at the fake tree (they normally scan /sys)
point_at_fake() {
    detect_cpu_count()    { printf '8'; }
    detect_policies()     { printf '%s %s' "$T/sys/cpu/cpufreq/pol0" "$T/sys/cpu/cpufreq/pol1"; }
    detect_clusters()     { printf '0 4'; }
    detect_governors()    { read_node "$T/sys/cpu/cpufreq/pol0/scaling_available_governors"; }
    cpu_online_state()    { printf '8/8'; }
    detect_gpu_path()     { printf '%s' "$T/sys/kgsl/kgsl-3d0"; }
    detect_gpu_vendor()   { printf 'adreno'; }
    detect_gpu_caps()     { printf ' governor min_freq max_freq avail_gov force_clk idle_timer throttling busy_pct gpuclk'; }
    detect_thermal_zones() {
        printf '%s:%s\n' "$T/sys/thermal/thermal_zone0" "cpu-0-0-usr"
    }
    detect_cpu_thermal_zone() { printf '%s' "$T/sys/thermal/thermal_zone0"; }
    detect_thermal_throttling() { printf '1'; }
    read_temp_c() {
        _raw=$(read_node "$1/temp") || return 1
        case "$_raw" in ''|*[!0-9-]*) return 1 ;; esac
        [ "$_raw" -gt 1000 ] && printf '%s' $(( _raw / 1000 )) || printf '%s' "$_raw"
    }
    detect_zram()         { printf '%s' "$T/sys/block/zram0"; }
    zram_active()         { return 0; }
    detect_battery_path() { printf '%s' "$T/sys/power_supply/battery"; }
    # pure permission-bit probe (real node_writable tries an actual
    # append, which would chmod the fake files)
    node_writable() { [ -e "$1" ] && [ -w "$1" ]; }
    HPC_PROC_SYS="$T/proc/sys"
    KM_EXPORT_DIR="$T/exports"
    km_battery_supplies() { printf '%s\n' "$T/sys/power_supply/"*; }
    battery_capacity()    { read_node "$T/sys/power_supply/battery/capacity"; }
    battery_charging()    { return 1; }
    battery_temp_c()      { printf '35'; }
    detect_vm_knobs()     { printf 'swappiness vfs_cache_pressure'; }
    detect_sched_knobs()  { printf ''; }
    detect_stune()        { return 1; }
    km_block_devices()    { printf '%s\n' "$T/sys/block/mmcblk0"; }
    km_io_available()     { printf 'mq-deadline cfq none'; }
    km_io_current()       { printf 'mq-deadline'; }
    run_detection()       { return 0; }
    load_capabilities()   { return 0; }
    current_profile()     { printf 'balanced'; }
    # built-in profiles come from the real module dir (read-only in tests;
    # deleting a builtin must be refused by the engine, not the fixture)
    KM_PROF_BUILTIN="$MOD/config/profiles"
    apply_profile()       { _cur_prof="$1"; return 0; }
    game_is_active()      { return 1; }
    game_current_pkg()    { printf ''; }
    web_start()           { return 0; }
    game_tick()           { return 0; }
    game_recover_stale()  { return 0; }
    thermal_tick()        { return 0; }
}

# ---------------------------------------------------------------- source the
# production code under test (skip the heavy Android-only bootstrap)
source_hpc() {
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/safety.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/detector.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/kernel_manager.sh"
    hpc_safety_init
    # the km_* layers
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_discover.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_registry.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_events.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_monitor.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_bench.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_diag.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_advise.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/km_profiles.sh"
    # shellcheck source=/dev/null
    . "$HPC_SCRIPTS/plugin_loader.sh"
}

# _reg_get ID FIELD(1-10) -> field value from the capability registry
_reg_get() {
    awk -F '\t' -v k="$1" -v f="$2" '$1==k {print $f; exit}' "$KM_REG_TSV" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- assertions
PASS=0
FAIL=0
FAILS=""

check() {  # check NAME CONDITION(0/1)
    if [ "$2" = "0" ]; then
        PASS=$((PASS + 1))
        printf '  ok  %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        FAILS="$FAILS $1"
        printf '  FAIL %s\n' "$1"
    fi
}

check_eq() {  # check_eq NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        printf '  ok  %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        FAILS="$FAILS $1"
        printf '  FAIL %s (expected [%s] got [%s])\n' "$1" "$2" "$3"
    fi
}

check_json() {  # check_json NAME JSONSTRING  (valid JSON via python)
    if printf '%s' "$2" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        check "$1 (valid JSON)" 0
    else
        check "$1 (valid JSON)" 1
    fi
}

test_result() {
    printf '\n%s: %d passed, %d failed\n' "${1:-test}" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}
