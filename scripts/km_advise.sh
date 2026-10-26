#!/system/bin/sh
# Hamedis Performance Core (HPC) - kernel assistant (rule-based engine)
#
# Part of the Kernel Management Platform (v1.10).
#
# The assistant produces findings from REAL recorded device data:
#   * every finding is either "observed" (a measured fact with its
#     source) or "inferred" (a rule applied to observed facts)
#   * machine-applicable suggestions are validated against the control
#     registry before being marked valid - an invalid/unsupported
#     suggestion is never presented as actionable
#   * nothing here executes anything; applying a suggestion always goes
#     through km_ctl_set with user confirmation in the UI
#
# Optional remote AI backend:
#   The engine can POST its evidence payload to an endpoint configured
#   in config.conf (HPC_AI_ENDPOINT) - OFF by default. No credentials
#   live in source code; if no endpoint is configured, the local rule
#   engine runs alone. The payload contract is stable (see README,
#   docs/kernel_platform.md) so a future service can consume it.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"

# ----------------------------------------------------------------------
# small knowledge base: plain-language explanations for known controls.
# Explicitly GENERAL documentation, distinct from observed device state.
# ----------------------------------------------------------------------

km_explain_text() {
    case "$1" in
        *.governor) printf 'A governor decides how the kernel picks CPU frequency for a core. Common ones: schedutil (uses scheduler load, default on modern kernels), performance (always max), powersave (always min), ondemand/interactive (legacy dynamic). Changing it changes responsiveness vs battery - effects are workload-dependent.' ;;
        *.max_freq) printf 'The ceiling the governor may use for this cluster. Lowering it saves power and heat but caps peak performance. The hardware maximum is reported from the kernel, not assumed.' ;;
        *.min_freq) printf 'The floor the governor sits at when idle. A higher floor removes low-clock dips (less micro-stutter) at the cost of power. A floor can never exceed the max.' ;;
        io.*.scheduler) printf 'Chooses how disk requests are queued. On UFS the difference between schedulers is small; "none"/"mq-deadline" are the usual choices. Only kernels expose the list they actually support.' ;;
        io.*.read_ahead_kb) printf 'How many KiB the kernel reads ahead of position. Higher helps sequential reads (streaming, app launch), costs a little memory.' ;;
        net.tcp_cc) printf 'The TCP congestion-control algorithm. Choices like cubic, bbr, westwood trade latency vs throughput depending on network - no single one is "fastest everywhere".' ;;
        vm.swappiness) printf 'Kernel preference for swapping anonymous memory vs dropping file cache. Lower keeps more app memory in RAM; the right value depends on how much RAM the device has.' ;;
        vm.vfs_cache_pressure) printf 'How quickly the kernel reclaims file cache. Lower keeps more file cache (faster re-opens), higher frees memory sooner.' ;;
        gpu.governor) printf 'GPU frequency governor (vendor-specific, e.g. Adreno). "performance" holds clocks high; "powersave"/"msm-adreno-tz" let them drop. Available list comes from the kernel.' ;;
        gpu.min_freq|gpu.max_freq) printf 'GPU clock window the governor operates in. Only exposed by some kernels; when absent, the vendor driver fully manages clocks.' ;;
        zram.swappiness) printf 'zRAM-specific swap preference for the compressed RAM block device.' ;;
        sched.*) printf 'Scheduler tuning. CFS/WALT parameters are kernel-version-specific and vendor patches may ignore them - treat changes as experiments, verified with benchmarks.' ;;
        *) printf 'A kernel interface discovered on this device. See its detail line in the capability registry for device-specific information.' ;;
    esac
}

# ----------------------------------------------------------------------
# km_advise -> full JSON: facts, findings, suggestions
# ----------------------------------------------------------------------

km_advise() {
    _a_now=$(km_now_ms)
    _a_facts=""
    _a_findings=""
    _a_add_fact() {
        _a_facts="${_a_facts}{\"fact\":$(km_jesc "$1"),\"source\":$(km_jesc "$2")},"
    }
    _a_add_finding() {
        # id severity kind title explanation suggestions-json
        _a_findings="${_a_findings}{\"id\":\"$1\",\"severity\":\"$2\",\"kind\":\"$3\",\"title\":$(km_jesc "$4"),\"explanation\":$(km_jesc "$5"),\"suggestions\":[$6]},"
    }
    _a_sugg() {
        # op_id op_value reason risk -> validates before marking valid
        _as_v="0"
        _as_err=""
        if [ -n "$1" ]; then
            _as_err=$(km_ctl_validate "$1" "$2" 2>/dev/null)
            [ -z "$_as_err" ] && _as_v="1"
        fi
        printf '{"op":%s,"value":%s,"reason":%s,"risk":"%s","valid":%s}' \
            "$(km_jesc "$1")" \
            "$(km_jesc "$2")" \
            "$(km_jesc "$3")" "$4" "$_as_v"
    }

    # ---- gather facts
    _a_cpu=$(km_mon_cpu 2>/dev/null)
    _a_util=$(printf '%s' "$_a_cpu" | sed -n 's/.*"util_pct":\(-\?[0-9]*\).*/\1/p')
    _a_prof=$(current_profile 2>/dev/null)
    _a_mem=$(km_mon_mem 2>/dev/null)
    _a_mtot=$(printf '%s' "$_a_mem" | sed -n 's/.*"total_kb":\([0-9]*\).*/\1/p')
    _a_mavail=$(printf '%s' "$_a_mem" | sed -n 's/.*"available_kb":\([0-9]*\).*/\1/p')
    _a_zused=$(printf '%s' "$_a_mem" | sed -n 's/.*"zram_used_kb":\([0-9]*\).*/\1/p')
    _a_therm=$(km_mon_thermal 2>/dev/null)
    _a_thottest=$(printf '%s' "$_a_therm" | sed -n 's/.*"hottest":\"\([0-9]*\)C.*/\1/p')
    _a_batt=$(km_mon_batt 2>/dev/null)
    _a_bcap=$(printf '%s' "$_a_batt" | sed -n 's/.*"capacity_pct":\([0-9]*\).*/\1/p')
    _a_disk=$(km_mon_disk 2>/dev/null)
    _a_io=$(km_io_current 2>/dev/null)

    [ -n "$_a_util" ] && [ "$_a_util" != "-" ] && _a_add_fact "CPU utilization: ${_a_util}%" "/proc/stat delta"
    [ -n "$_a_prof" ] && _a_add_fact "active profile: $_a_prof" "HPC state"
    [ -n "$_a_mtot" ] && [ -n "$_a_mavail" ] && _a_add_fact "RAM: ${_a_mavail} kB available of ${_a_mtot} kB" "/proc/meminfo"
    [ -n "$_a_zused" ] && _a_add_fact "zRAM in use: ${_a_zused} kB" "/sys/block/zram*"
    [ -n "$_a_thottest" ] && _a_add_fact "hottest sensor: ${_a_thottest}C" "/sys/class/thermal"
    [ -n "$_a_bcap" ] && _a_add_fact "battery: ${_a_bcap}%" "power_supply"
    [ -n "$_a_io" ] && _a_add_fact "IO scheduler: $_a_io" "block queue"

    # events of the last 30 minutes
    _a_lim30=$(( _a_now - 1800000 ))
    _a_therm_ev=0
    if [ -f "$KM_EVENTS" ]; then
        _a_therm_ev=$(awk -F '\t' -v t="$_a_lim30" '$1>=t && $2=="thermal_high" {n++} END{print n+0}' "$KM_EVENTS" 2>/dev/null)
    fi
    [ -n "$_a_therm_ev" ] && [ "$_a_therm_ev" -gt 0 ] && _a_add_fact "thermal_high events (30m): $_a_therm_ev" "HPC event timeline"

    _a_kerr=0
    if dmesg >/dev/null 2>&1; then
        _a_kerr=$(dmesg 2>/dev/null | tail -n 400 | grep -icE 'error|fail|bug|panic|oops' 2>/dev/null)
    fi
    [ -n "$_a_kerr" ] && [ "$_a_kerr" -gt 0 ] && _a_add_fact "kernel error-pattern lines (klog tail): $_a_kerr" "dmesg"

    # ---- rules ------------------------------------------------------

    # R1: sustained load + thermal pressure
    if [ -n "$_a_util" ] && [ "$_a_util" -ge 70 ] 2>/dev/null && [ "${_a_therm_ev:-0}" -ge 1 ] 2>/dev/null; then
        _a_add_finding r1_thermal med inferred \
            "High CPU load is producing thermal pressure" \
            "Measured CPU utilization is ${_a_util}% and the event timeline shows ${_a_therm_ev} thermal warning(s) in the last 30 minutes. Sustained near-max load makes the kernel throttle; a profile with a lower floor trades some peak speed for smoother sustained performance." \
            "$(_a_sugg cpu1.governor schedutil 'use the scheduler-aware governor (validated against this kernel)' med),$(_a_sugg cpu1.min_freq '' 'lowering the CPU floor reduces heat (choose a concrete kHz below the hardware max)' med)"
    fi

    # R2: memory pressure
    if [ -n "$_a_mtot" ] && [ -n "$_a_mavail" ] && [ "$_a_mtot" -gt 0 ] 2>/dev/null; then
        _a_pctr=$(( _a_mavail * 100 / _a_mtot ))
        if [ "$_a_pctr" -le 8 ]; then
            _a_znote=""
            [ -n "$_a_zused" ] && [ "$_a_zused" -gt 102400 ] && _a_znote=" zRAM is already holding $((_a_zused / 1024)) MB of compressed swap."
            _a_add_finding r2_mem high observed \
                "Low available memory" \
                "Only ${_a_mavail} kB (${_a_pctr}%) of RAM is available. ${_a_znote} The system is relying on aggressive reclaim, which causes app reloads. This is usually solved by closing background apps rather than by kernel tuning." \
                ""
        fi
    fi

    # R3: kernel errors
    if [ -n "$_a_kerr" ] && [ "$_a_kerr" -ge 3 ]; then
        _a_add_finding r3_klog med observed \
            "Repeated kernel error patterns in the log" \
            "$_a_kerr line(s) matching error/fail/bug/panic patterns in the last 400 kernel log lines. Correlation with a specific setting is NOT proven; export the diagnostic report (it redacts identifiers) before sharing it." \
            ""
    fi

    # R4: IO scheduler note on UFS
    case "$_a_io" in
        cfq|deadline)
            _a_add_finding r4_io low inferred \
                "IO scheduler is a spinning-disk era choice" \
                "The active scheduler is '$_a_io'. On UFS the scheduler's effect is small compared to thermal state and available memory; if you suspect storage lag, run the IO A/B benchmark rather than guessing." \
                ""
            ;;
    esac

    # R5: idle device on performance profile
    if [ "$_a_prof" = "performance" ] && [ -n "$_a_util" ] && [ "$_a_util" -le 15 ] 2>/dev/null && [ -n "$_a_bcap" ] && [ "$_a_bcap" -lt 40 ] 2>/dev/null; then
        _a_add_finding r5_idle low inferred \
            "Performance profile while idle on low battery" \
            "The device is currently near-idle (CPU ${_a_util}%) with battery at ${_a_bcap}% while the performance profile is active. Switching back to balanced now would save power until you need speed." \
            "$(_a_sugg '' '' 'switch profile to balanced (done via the Profile section - profiles apply many settings, so this is a profile operation, not a single control)' low)"
    fi

    # R6: diagnostics limitation
    if ! dmesg >/dev/null 2>&1; then
        _a_add_finding r6_klog info observed \
            "Kernel log is restricted" \
            "dmesg is not readable from this context, so kernel-side diagnostics are limited. This is a kernel/SELinux policy, not an HPC fault." \
            ""
    fi

    # ---- remote AI backend (optional, off by default)
    _a_ai="off"
    if [ -n "${HPC_AI_ENDPOINT:-}" ] && command -v wget >/dev/null 2>&1; then
        _a_payload=$(printf '{"device":%s,"hpc_version":%s,"facts":[%s],"findings":[%s],"request":"analyze"}' \
            "$(km_jesc "$(getprop ro.product.device 2>/dev/null)")" \
            "$(km_jesc "${HPC_VERSION:-?}")" \
            "$(printf '%s' "$_a_facts" | sed 's/,$//')" \
            "$(printf '%s' "$_a_findings" | sed 's/,$//')")
        _a_resp=$(wget -qO- --timeout=5 --post-data="$_a_payload" --header='Content-Type: application/json' "${HPC_AI_ENDPOINT}" 2>/dev/null)
        [ -n "$_a_resp" ] && _a_ai="on"
    fi

    printf '{"ts":%s,"engine":"local-rules","ai_backend":%s,"facts":[%s],"findings":[%s],"note":"facts are measured values with their source; findings marked inferred are rules applied to facts, not measurements; suggestions marked valid=0 are not applicable on this device"}\n' \
        "$_a_now" "$(km_jesc "$_a_ai")" \
        "$(printf '%s' "$_a_facts" | sed 's/,$//')" \
        "$(printf '%s' "$_a_findings" | sed 's/,$//')"
    return 0
}

# km_advise_explain CONTROL_ID -> JSON {control, explanation_general, observed}
km_advise_explain() {
    _ae_id="$1"
    _ae_val=$(km_ctl_get "$_ae_id" 2>/dev/null)
    _ae_enum=$(km_ctl_enum "$_ae_id" 2>/dev/null)
    _ae_det=""
    [ -f "$KM_REG_TSV" ] && _ae_det=$(awk -F '\t' -v k="$_ae_id" '$1==k {print $10; exit}' "$KM_REG_TSV" 2>/dev/null)
    printf '{"ts":%s,"control":%s,"current":%s,"kernel_list":%s,"device_detail":%s,"explanation_general":%s,"note":"explanation_general is documentation, not a measurement of this device"}\n' \
        "$(km_now_ms)" "$(km_jesc "$_ae_id")" "$(km_jesc "${_ae_val:-absent}")" \
        "$(km_jesc "$_ae_enum")" "$(km_jesc "$_ae_det")" \
        "$(km_jesc "$(km_explain_text "$_ae_id")")"
    return 0
}
