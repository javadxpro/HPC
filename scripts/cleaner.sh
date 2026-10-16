#!/system/bin/sh
# Hamedis Performance Core (HPC) - cleaner
#
# Root-level cleanup of regenerable system junk ONLY.
#
# Hard rules:
#   * The target list is HARDCODED in this file. No path ever comes from
#     the user or the network, so the web API cannot be turned into an
#     rm -rf vector.
#   * Only directory CONTENTS are removed, never the directory itself
#     (several of them must exist for the system).
#   * User files (/sdcard pictures, videos, docs, app data) are never
#     touched. The only /sdcard targets are hidden .thumbnails caches,
#     which the media scanner rebuilds automatically.
#   * Every removal is logged with the size actually freed.
# shellcheck disable=SC3043

# Quick targets: "path|Persian label"
CLEANER_QUICK_TARGETS="
/data/local/tmp|فایل‌های موقت (tmp)
/data/anr|گزارش‌های گیرکردن (ANR)
/data/misc/anr|گزارش‌های ANR (2)
/data/tombstones|تومباستون‌ها (crash)
/data/crash_reports|گزارش‌های کرش
/data/log|لاگ‌های سیستم
/cache|پارتیشن کش
/sdcard/.thumbnails|کاشهٔ بندانگشتی‌ها
/sdcard/DCIM/.thumbnails|بندانگشتی‌های دوربین
/sdcard/Pictures/.thumbnails|بندانگشتی‌های عکس‌ها
/data/media/0/.thumbnails|بندانگشتی‌ها (مسیر جدید)
"

# Deep targets: same format. Only run after explicit confirmation in the UI.
CLEANER_DEEP_TARGETS="
/data/dalvik-cache|کاشهٔ اجرا برنامه‌ها (ART)
"

# du in KiB for a directory; prints 0 when absent or unreadable.
cleaner_dir_kb() {
    _cdk_d="$1"
    [ -d "$_cdk_d" ] || return 0
    _cdk_out=$(du -sk "$_cdk_d" 2>/dev/null | awk '{print $1; exit}')
    case "$_cdk_out" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$_cdk_out" ;;
    esac
}

# Number of top-level entries in a directory.
cleaner_dir_count() {
    _cdc_d="$1"
    [ -d "$_cdc_d" ] || return 0
    find "$_cdc_d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# Remove only the CONTENTS of a directory (including hidden entries),
# keeping the directory itself.
cleaner_dir_wipe() {
    _cdw_d="$1"
    [ -d "$_cdw_d" ] || return 1
    rm -rf "$_cdw_d"/* 2>/dev/null
    rm -rf "$_cdw_d"/.[!.]* 2>/dev/null
    rm -rf "$_cdw_d"/..?* 2>/dev/null
    return 0
}

# Drop HPC's own rotated logs (keep the live hpc.log).
cleaner_hpc_logs_wipe() {
    _clh_n=0
    for _clh_f in "$HPC_LOG_DIR"/hpc.log.[0-9]*; do
        [ -f "$_clh_f" ] || continue
        rm -f "$_clh_f" 2>/dev/null && _clh_n=$((_clh_n + 1))
    done
    printf '%s' "$_clh_n"
}

# Storage free space (KiB) for a mountpoint.
cleaner_storage_free_kb() {
    _csf_m="$1"
    [ -d "$_csf_m" ] || return 0
    df -k "$_csf_m" 2>/dev/null | awk 'NR==2 {print $4; exit}' | tr -d ' '
}

# Scan: print a JSON array of {path,label,kb,count} for the given mode.
# cleaner_scan_json quick|deep
cleaner_scan_json() {
    _csj_mode="${1:-quick}"
    printf '['
    _csj_first=1
    _csj_list="$CLEANER_QUICK_TARGETS"
    [ "$_csj_mode" = "deep" ] && _csj_list="$_csj_list
$CLEANER_DEEP_TARGETS"
    # shellcheck disable=SC2086
    for _csj_entry in $_csj_list; do
        case "$_csj_entry" in ''|\#*|*'|'*) ;; *) continue ;; esac
        _csj_p=${_csj_entry%%|*}
        _csj_l=${_csj_entry#*|}
        _csj_kb=$(cleaner_dir_kb "$_csj_p")
        _csj_n=$(cleaner_dir_count "$_csj_p")
        [ "$_csj_first" -eq 1 ] || printf ','
        _csj_first=0
        printf '{"path":%s,"label":%s,"kb":%s,"count":%s}' \
            "$(jstr "$_csj_p")" "$(jstr "$_csj_l")" \
            "$(jnum "$_csj_kb")" "$(jnum "$_csj_n")"
    done
    printf ']'
}

# Run cleanup. Prints the total freed size in KiB on stdout;
# details go to the log. cleaner_run quick|deep
cleaner_run() {
    _cr_mode="${1:-quick}"
    _cr_total=0
    _cr_targets="$CLEANER_QUICK_TARGETS"
    [ "$_cr_mode" = "deep" ] && _cr_targets="$_cr_targets
$CLEANER_DEEP_TARGETS"

    log_info "cleaner: run $_cr_mode"
    # shellcheck disable=SC2086
    for _cr_entry in $_cr_targets; do
        case "$_cr_entry" in ''|\#*|*'|'*) ;; *) continue ;; esac
        _cr_p=${_cr_entry%%|*}
        _cr_l=${_cr_entry#*|}
        _cr_kb=$(cleaner_dir_kb "$_cr_p")
        if [ -d "$_cr_p" ]; then
            cleaner_dir_wipe "$_cr_p"
            log_info "cleaner: wiped $_cr_p ($_cr_kb KiB)"
            _cr_total=$((_cr_total + _cr_kb))
        fi
    done

    _cr_n=$(cleaner_hpc_logs_wipe)
    [ "$_cr_n" -gt 0 ] && log_info "cleaner: dropped $_cr_n rotated logs"

    log_info "cleaner: total freed $_cr_total KiB ($_cr_mode)"
    printf '%s' "$_cr_total"
}

# RAM housekeeping: clear logcat buffers and drop clean page caches.
# Prints "ok" on success.
cleaner_ram() {
    # logcat -c clears the ring buffers (frees the RAM they hold).
    logcat -c 2>/dev/null
    # drop_caches is an ACTION node: it always reads back 0, so verify
    # would always "fail" - use --no-verify. The backup/restore of "0"
    # is harmless.
    safe_write /proc/sys/vm/drop_caches 3 --no-verify
    log_info "cleaner: ram housekeeping done"
    printf 'ok'
}
