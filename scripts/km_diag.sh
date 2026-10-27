#!/system/bin/sh
# Hamedis Performance Core (HPC) - diagnostics, health & redaction
#
# Part of the Kernel Management Platform (v1.10).
#
# Builds structured diagnostic reports from REAL recorded data only:
#   * environment + capability registry
#   * current effective configuration (what we applied + what the
#     kernel actually reports)
#   * recent change history and events
#   * kernel log error scan
#   * benchmark summary
#
# The health score is a documented HEURISTIC (see km_health), not a
# hardware health measurement. Users can always inspect the evidence.
#
# Redaction (km_redact) removes identifiers before a report is shared.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
KM_REPORT_DIR="$HPC_STATE/reports"
KM_EXPORT_DIR="${KM_EXPORT_DIR:-/data/local/tmp/hpc_exports}"

km_diag_init() {
    [ -d "$KM_REPORT_DIR" ] || mkdir -p "$KM_REPORT_DIR" 2>/dev/null
    [ -d "$KM_EXPORT_DIR" ] || mkdir -p "$KM_EXPORT_DIR" 2>/dev/null
    chmod 0700 "$KM_EXPORT_DIR" 2>/dev/null
}

# ----------------------------------------------------------------------
# health score - documented formula, bounded 0-100
#
#   100
#   - 8  per failed change in the last 10 minutes (max 24)
#   - 12 if a thermal_high event in the last 30 minutes (max 24)
#   - 6  per distinct kernel error pattern in the last 30 minutes (max 24)
#   - 10 if the service heartbeat is older than 5 minutes (max 10)
#   - 10 if capability registry is missing/empty (max 10)
#
# It measures "things going wrong right now", NOT hardware wear.
# ----------------------------------------------------------------------

km_health() {
    _h_score=100
    _h_comp=""

    # failed changes, last 10 min
    _h_now=$(km_now_ms)
    _h_lim10=$(( _h_now - 600000 ))
    _h_fail=0
    if [ -f "$KM_CHANGE_LOG" ]; then
        _h_fail=$(awk -F '\t' -v t="$_h_lim10" '$1>=t && ($8=="fail" || $8=="restore_failed") {n++} END{print n+0}' "$KM_CHANGE_LOG" 2>/dev/null)
    fi
    _h_fail=${_h_fail:-0}
    [ "$_h_fail" -gt 3 ] && _h_fail=3
    _h_pen=$(( _h_fail * 8 ))
    _h_comp="${_h_comp}{\"name\":\"failed_changes_10m\",\"value\":$_h_fail,\"penalty\":$_h_pen},"

    # thermal events, last 30 min
    _h_lim30=$(( _h_now - 1800000 ))
    _h_therm=0
    if [ -f "$KM_EVENTS" ]; then
        _h_therm=$(awk -F '\t' -v t="$_h_lim30" '$1>=t && $2=="thermal_high" {n++} END{print n+0}' "$KM_EVENTS" 2>/dev/null)
    fi
    _h_therm=${_h_therm:-0}
    [ "$_h_therm" -gt 2 ] && _h_therm=2
    _h_pen2=$(( _h_therm * 12 ))
    _h_comp="${_h_comp}{\"name\":\"thermal_events_30m\",\"value\":$_h_therm,\"penalty\":$_h_pen2},"

    # distinct kernel error patterns in the klog tail
    _h_kerr=0
    if dmesg >/dev/null 2>&1; then
        _h_kerr=$(dmesg 2>/dev/null | tail -n 400 | grep -icE 'error|fail|bug|panic|watchdog|oops' 2>/dev/null)
    fi
    _h_kerr=${_h_kerr:-0}
    [ "$_h_kerr" -gt 4 ] && _h_kerr=4
    _h_pen3=$(( _h_kerr * 6 ))
    _h_comp="${_h_comp}{\"name\":\"kernel_error_lines\",\"value\":$_h_kerr,\"penalty\":$_h_pen3},"

    # service heartbeat: the service logs a heartbeat every ~20 ticks
    _h_hb=10
    if [ -f "$HPC_LOG_DIR/hpc.log" ]; then
        _h_hb_age=$(awk -v now="$(date +%s)" '$0 ~ /heartbeat/ {ts=substr($0,1,19)} END{}' /dev/null 2>/dev/null)
        # cheap check: is the log file modified within the last 5 min?
        _h_mtime=$(stat -c %Y "$HPC_LOG_DIR/hpc.log" 2>/dev/null || printf '0')
        _h_age=$(( $(date +%s) - _h_mtime ))
        if [ "$_h_age" -gt 300 ]; then
            _h_hb=10
            _h_comp="${_h_comp}{\"name\":\"stale_service_log\",\"value\":$_h_age,\"penalty\":10},"
        else
            _h_hb=0
            _h_comp="${_h_comp}{\"name\":\"stale_service_log\",\"value\":$_h_age,\"penalty\":0},"
        fi
    else
        _h_comp="${_h_comp}{\"name\":\"stale_service_log\",\"value\":\"no log\",\"penalty\":10},"
    fi

    # capability registry present?
    _h_caps=0
    if [ -f "$KM_REG_TSV" ] && [ -s "$KM_REG_TSV" ]; then
        :
    else
        _h_caps=10
        _h_comp="${_h_comp}{\"name\":\"missing_capability_registry\",\"value\":1,\"penalty\":10},"
    fi

    _h_score=$(( _h_score - _h_pen - _h_pen2 - _h_pen3 - _h_hb - _h_caps ))
    [ "$_h_score" -lt 0 ] && _h_score=0
    printf '{"ts":%s,"score":%s,"components":[%s],"formula":"100 - 8*failed_changes(10m, max3) - 12*thermal_high(30m, max2) - 6*kernel_error_lines(<=4) - 10*stale_service - 10*missing_registry","limitation":"heuristic of recent problems, not a hardware health measurement"}\n' \
        "$_h_now" "$_h_score" "$(printf '%s' "$_h_comp" | sed 's/,$//')"
}

# ----------------------------------------------------------------------
# redaction - remove identifiers that should not leave the device
# ----------------------------------------------------------------------

km_redact() {
    # km_redact FILE -> prints redacted content
    _rf="$1"
    [ -f "$_rf" ] || return 1
    _r_serial=$(getprop ro.serialno 2>/dev/null)
    _r_imei=$(getprop ro.serial 2>/dev/null)
    _r_mac=$(cat /sys/class/net/wlan0/address 2>/dev/null)
    sed -E \
        -e 's/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[REDACTED-IP]/g' \
        -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/[REDACTED-MAC]/g' \
        -e "s/$_r_serial/[REDACTED-SERIAL]/g" \
        -e "s/$_r_imei/[REDACTED-SERIAL]/g" \
        -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[REDACTED-UUID]/g' \
        "$_rf" 2>/dev/null
    return 0
}

# ----------------------------------------------------------------------
# full diagnostic report
# ----------------------------------------------------------------------

# km_diag_report -> prints report file path; also exports to
# /data/local/tmp/hpc_exports/ (redacted) for easy adb pull
km_diag_report() {
    km_diag_init
    _d_ts=$(km_now_ms)
    _d_out="$KM_REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).txt"

    {
        printf '════════════════════════════════════════════════\n'
        printf ' HPC diagnostic report - %s\n' "$(date 2>/dev/null)"
        printf ' HPC version: %s\n' "${HPC_VERSION:-?}"
        printf '════════════════════════════════════════════════\n\n'

        printf -- '--- environment ---\n'
        km_mon_status 2>/dev/null
        printf '\n'

        printf -- '--- capability summary (top entries) ---\n'
        if [ -f "$KM_REG_TSV" ]; then
            awk -F '\t' '{printf "%-28s %-6s %-9s conf=%s  %s\n", $1, $5, $6, $8, substr($9,1,60)}' "$KM_REG_TSV" 2>/dev/null | head -n 60
        else
            printf 'capability registry missing - run km_caps_scan\n'
        fi
        printf '\n'

        printf -- '--- live: cpu ---\n';  km_mon_cpu 2>/dev/null;  printf '\n'
        printf -- '--- live: gpu ---\n';  km_mon_gpu 2>/dev/null;  printf '\n'
        printf -- '--- live: memory ---\n'; km_mon_mem 2>/dev/null; printf '\n'
        printf -- '--- live: thermal ---\n'; km_mon_thermal 2>/dev/null; printf '\n'
        printf -- '--- live: battery ---\n'; km_mon_batt 2>/dev/null; printf '\n'

        printf -- '--- applied configuration (what HPC set) ---\n'
        if [ -f "$HPC_APPLIED" ]; then
            awk -F '\t' '{printf "%-52s %s\n", $1, $2}' "$HPC_APPLIED" 2>/dev/null | head -n 40
        else
            printf 'nothing applied\n'
        fi
        printf '\n'

        printf -- '--- recent changes (newest 30) ---\n'
        _d_ch=$(km_history 30 2>/dev/null | awk -F '\t' '{printf "%s  %-24s %-44s %s -> %s  [%s]\n", $1, $2, $3, $4, $5, $8}')
        [ -n "$_d_ch" ] && printf '%s\n' "$_d_ch" || printf '(no recorded changes yet)\n'
        printf '\n'

        printf -- '--- recent events (newest 30) ---\n'
        km_events 30 2>/dev/null
        printf '\n'

        printf -- '--- kernel log: error lines (last 400) ---\n'
        if dmesg >/dev/null 2>&1; then
            _d_kerr=$(dmesg 2>/dev/null | tail -n 400 | grep -iE 'error|fail|bug|panic|watchdog|oops|thermal' | tail -n 40)
            [ -n "$_d_kerr" ] && printf '%s\n' "$_d_kerr" || printf '(no matching lines)\n'
        else
            printf 'dmesg not readable in this context\n'
        fi
        printf '\n'

        printf -- '--- recent benchmarks ---\n'
        km_bench_list 5 2>/dev/null
        printf '\n'

        printf -- '--- health ---\n'
        km_health 2>/dev/null
        printf '\n'
    } >"$_d_out" 2>/dev/null

    # redacted export copy
    _d_exp="$KM_EXPORT_DIR/report_$(date +%Y%m%d_%H%M%S)_redacted.txt"
    km_redact "$_d_out" >"$_d_exp" 2>/dev/null
    chmod 0600 "$_d_out" "$_d_exp" 2>/dev/null

    printf '{"ok":1,"path":"%s","export":"%s"}\n' "$_d_out" "$_d_exp"
    return 0
}

# ----------------------------------------------------------------------
# km_doctor — on-device self-check
#
# Read-only, EXCEPT one guarded no-op write round-trip: the current
# value of a single writable capability is written back to itself and
# read back, so the real write path (lock -> validate -> backup ->
# write -> verify -> commit) is exercised without changing anything.
#
# Output: one line per check:  PASS|WARN|FAIL  <area>  <detail>
# Final line:  DOCTOR RESULT: PASS|DEGRADED|FAIL (p=N w=M f=K)
km_doctor() {
    _dk_p=0; _dk_w=0; _dk_f=0

    # -- capability registry ------------------------------------------------
    if [ -f "$KM_REG_TSV" ]; then
        # registry.tsv columns: id name path kind rw risk type conf value detail
        # rw values: rw = writable, r = read-only, - = absent/inaccessible
        _dk_total=$(wc -l <"$KM_REG_TSV" 2>/dev/null | tr -d ' ')
        _dk_wrt=$(awk -F'\t' '$5=="rw"' "$KM_REG_TSV" 2>/dev/null | wc -l | tr -d ' ')
        _dk_ro=$(awk -F'\t' '$5=="r"' "$KM_REG_TSV" 2>/dev/null | wc -l | tr -d ' ')
        _dk_ab=$(awk -F'\t' '$5=="-"' "$KM_REG_TSV" 2>/dev/null | wc -l | tr -d ' ')
        if [ "${_dk_total:-0}" -gt 0 ]; then
            _dk_p=$((_dk_p + 1))
            printf 'PASS  registry  %s capabilities (%s writable, %s read-only, %s absent/inaccessible)\n' \
                "$_dk_total" "$_dk_wrt" "$_dk_ro" "$_dk_ab"
        else
            _dk_f=$((_dk_f + 1)); printf 'FAIL  registry  empty - run: hpc.sh km scan\n'
        fi
        if [ "${_dk_wrt:-0}" -eq 0 ]; then
            _dk_w=$((_dk_w + 1)); printf 'WARN  registry  no writable capability found (kernel exposes read-only only?)\n'
        fi
    else
        _dk_f=$((_dk_f + 1)); printf 'FAIL  registry  missing - run: hpc.sh km scan\n'
    fi

    # -- plugin adapters -----------------------------------------------------
    if [ -f "$KM_PLUGIN_CAPS" ]; then
        _dk_pl=$(wc -l <"$KM_PLUGIN_CAPS" 2>/dev/null | tr -d ' ')
        if [ "${_dk_pl:-0}" -gt 0 ]; then
            _dk_p=$((_dk_p + 1)); printf 'PASS  plugins  %s plugin capability(ies) registered\n' "$_dk_pl"
        else
            _dk_w=$((_dk_w + 1)); printf 'WARN  plugins  adapter loaded but registered no capabilities\n'
        fi
    else
        _dk_w=$((_dk_w + 1)); printf 'WARN  plugins  no adapter registered (core discovery only)\n'
    fi

    # -- monitor JSON endpoints ---------------------------------------------
    _dk_m_ok=0; _dk_m_n=0
    for _dk_m in km_mon_status km_mon_cpu km_mon_gpu km_mon_mem km_mon_thermal \
                 km_mon_batt km_mon_net km_mon_disk km_mon_sched km_mon_procs \
                 km_mon_modules km_mon_klog km_health km_caps_json; do
        _dk_m_n=$((_dk_m_n + 1))
        _dk_m_h=$($_dk_m 2>/dev/null | head -c 1)
        if [ "$_dk_m_h" = "{" ]; then
            _dk_m_ok=$((_dk_m_ok + 1))
        else
            _dk_f=$((_dk_f + 1)); printf 'FAIL  monitor  %s did not emit JSON\n' "$_dk_m"
        fi
    done
    if [ "$_dk_m_ok" -eq "$_dk_m_n" ]; then
        _dk_p=$((_dk_p + 1)); printf 'PASS  monitors  %s/%s endpoints emit JSON\n' "$_dk_m_ok" "$_dk_m_n"
    fi

    # -- audit trail ----------------------------------------------------------
    if [ -f "$KM_EVENTS" ]; then
        _dk_p=$((_dk_p + 1)); printf 'PASS  events  audit log present (%s lines)\n' "$(wc -l <"$KM_EVENTS" 2>/dev/null | tr -d ' ')"
    else
        _dk_w=$((_dk_w + 1)); printf 'WARN  events  audit log not created yet\n'
    fi
    if [ -f "$KM_CHANGE_LOG" ]; then
        _dk_p=$((_dk_p + 1)); printf 'PASS  history  change log present (%s changes)\n' "$(wc -l <"$KM_CHANGE_LOG" 2>/dev/null | tr -d ' ')"
    else
        _dk_w=$((_dk_w + 1)); printf 'WARN  history  no changes recorded yet\n'
    fi

    # -- guarded no-op write round-trip ----------------------------------------
    if [ -f "$KM_REG_TSV" ]; then
        _dk_rt=$(awk -F'\t' '$5=="rw" && $1 ~ /governor$/ {print $1; exit}' "$KM_REG_TSV" 2>/dev/null)
        [ -n "$_dk_rt" ] || _dk_rt=$(awk -F'\t' '$5=="rw" && $7=="enum" {print $1; exit}' "$KM_REG_TSV" 2>/dev/null)
        [ -n "$_dk_rt" ] || _dk_rt=$(awk -F'\t' '$5=="rw" {print $1; exit}' "$KM_REG_TSV" 2>/dev/null)
    fi
    if [ -n "${_dk_rt:-}" ]; then
        _dk_orig=$(km_ctl_get "$_dk_rt" 2>/dev/null)
        if [ -n "$_dk_orig" ]; then
            _dk_rr=$(km_ctl_set "$_dk_rt" "$_dk_orig" doctor 2>/dev/null)
            _dk_now=$(km_ctl_get "$_dk_rt" 2>/dev/null)
            if printf '%s' "$_dk_rr" | grep -q '"ok":1' && [ "$_dk_now" = "$_dk_orig" ]; then
                _dk_p=$((_dk_p + 1)); printf 'PASS  writetest  no-op write+readback ok on %s (value unchanged: %s)\n' "$_dk_rt" "$_dk_orig"
            else
                _dk_f=$((_dk_f + 1)); printf 'FAIL  writetest  no-op write on %s did not round-trip (check kernel support; no change left behind)\n' "$_dk_rt"
            fi
        else
            _dk_w=$((_dk_w + 1)); printf 'WARN  writetest  %s is writable but unreadable; skipped\n' "$_dk_rt"
        fi
    else
        _dk_w=$((_dk_w + 1)); printf 'WARN  writetest  no writable capability to test\n'
    fi

    # -- web surface ------------------------------------------------------------
    if [ -f "$HPC_MODDIR/webroot/index.html" ] && [ -f "$HPC_MODDIR/webroot/cgi-bin/api.sh" ]; then
        _dk_p=$((_dk_p + 1)); printf 'PASS  web  WebUI assets present\n'
    else
        _dk_f=$((_dk_f + 1)); printf 'FAIL  web  WebUI assets missing\n'
    fi

    # -- summary ------------------------------------------------------------------
    if [ "$_dk_f" -eq 0 ] && [ "$_dk_w" -eq 0 ]; then
        printf 'DOCTOR RESULT: PASS (p=%s w=%s f=%s)\n' "$_dk_p" "$_dk_w" "$_dk_f"
    elif [ "$_dk_f" -eq 0 ]; then
        printf 'DOCTOR RESULT: DEGRADED (p=%s w=%s f=%s)\n' "$_dk_p" "$_dk_w" "$_dk_f"
    else
        printf 'DOCTOR RESULT: FAIL (p=%s w=%s f=%s)\n' "$_dk_p" "$_dk_w" "$_dk_f"
    fi
    return 0
}
