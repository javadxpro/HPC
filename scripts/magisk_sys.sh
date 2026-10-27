# Hamedis Performance Core (HPC) - Magisk system integration
#
# Detects and reports the root environment (Magisk / KernelSU / APatch),
# and exposes a few safe, read-mostly Magisk features through HPC.
#
# Built against the Magisk v31.x source (topjohnwu/Magisk):
#   * /data/adb/magisk            (DATABIN) holds: magisk, magisk32,
#                                  magiskpolicy, busybox
#   * $MAGISKTMP (usually /sbin)/.magisk holds the tmpfs layout:
#                                  busybox/ (busybox + applet symlinks),
#                                  modules/, device/socket, config
#   * Module scripts are executed with `<busybox> sh` and
#     PATH=$PATH:$MAGISKTMP. NOTE (v31+): the busybox applet dir is no
#     longer added to PATH, so module scripts resolve utilities from the
#     system toybox, NOT busybox. HPC therefore never relies on applets
#     that toybox lacks (e.g. pkill does not exist on Android) and calls
#     busybox by explicit path when it needs a busybox applet (httpd).
#   * magisk.db (SQLite at /data/adb/magisk.db) tables:
#        settings(key TEXT, value INT)   keys: zygisk, denylist, bootloop,
#                                         multiuser_mode, mnt_ns
#        denylist(package_name TEXT, process TEXT)
#   * CLI (talks to the daemon over /data/adb/magisk/device/socket):
#        magisk --version        -> "31.1:MAGISK:R"  (release build)
#        magisk --version-code   -> "31100"
#        magisk --path           -> tmpfs path
#        magisk --sqlite "SQL"   -> one result line per row on stdout
#        magisk --denylist status|enable|disable|add PKG [PROC]|rm PKG [PROC]|ls
#                                   status/add/rm print on stderr, ls prints
#                                   "pkg|proc" lines on stdout
#        magisk --install-module ZIP
#
# SAFETY:
#   * Everything here is read-only EXCEPT denylist add/remove and module
#     self-update, and those two go through the official Magisk CLI, which
#     owns the database and the install procedure. HPC never touches
#     magisk.db, the daemon socket or Magisk files directly.
#   * Package names are validated against a strict Android package-name
#     regex before any add/remove.
#   * Self-update only accepts zips that live in /data/local/tmp and whose
#     embedded module.prop declares id=hamedis_performance_core.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"

# Magisk data dir (DATABIN in Magisk's consts). Overridable so the test
# harness can point it at a fake tree; on device it is always
# /data/adb/magisk (the environment never sets this variable).
MAGISK_DATABIN="${MAGISK_DATABIN:-/data/adb/magisk}"

# The only module zip HPC is allowed to install via magisk --install-module
HPC_SELF_ID="hamedis_performance_core"

# Where self-update zips must live (adb push location). Overridable for
# tests; on device it is always /data/local/tmp.
HPC_UPDATE_TMPDIR="${HPC_UPDATE_TMPDIR:-/data/local/tmp}"

# ----------------------------------------------------------------------
# binary / version discovery
# ----------------------------------------------------------------------

# magisk_bin -> prints path to the magisk binary, or nothing
magisk_bin() {
    for _mb in "$MAGISK_DATABIN/magisk" \
               "$(command -v magisk 2>/dev/null)" ; do
        [ -n "$_mb" ] && [ -x "$_mb" ] && { printf '%s' "$_mb"; return 0; }
    done
    return 1
}

# magisk_present -> 0 when a magisk binary is reachable
magisk_present() {
    [ -n "$(magisk_bin 2>/dev/null)" ]
}

# magisk_version -> "31.1" (from "31.1:MAGISK:R"), or "unknown"
magisk_version() {
    _mbv=$(magisk_bin 2>/dev/null) || { printf 'unknown'; return 0; }
    _mbv_out=$("$_mbv" --version 2>/dev/null | head -n 1)
    case "$_mbv_out" in
        *:*) printf '%s' "${_mbv_out%%:*}" ;;
        ''|unknown) printf 'unknown' ;;
        *) printf '%s' "$_mbv_out" ;;
    esac
}

# magisk_version_code -> "31100" or ""
magisk_version_code() {
    _mbc=$(magisk_bin 2>/dev/null) || return 0
    _mbc_out=$("$_mbc" --version-code 2>/dev/null | head -n 1 | tr -d '[:space:]')
    case "$_mbc_out" in
        ''|*[!0-9]*) return 0 ;;
        *) printf '%s' "$_mbc_out" ;;
    esac
}

# magisk_tmp_path -> "/sbin" style tmpfs path, or ""
magisk_tmp_path() {
    _mbt=$(magisk_bin 2>/dev/null) || return 0
    _mbt_out=$("$_mbt" --path 2>/dev/null | head -n 1 | tr -d '[:space:]')
    [ -n "$_mbt_out" ] && printf '%s' "$_mbt_out"
    return 0
}

# magisk_sqlite SQL -> daemon-mediated read of magisk.db (read-only use
# here). Prints result lines; returns 1 when the daemon is unreachable.
magisk_sqlite() {
    _mbs=$(magisk_bin 2>/dev/null) || return 1
    _mbs_out=$("$_mbs" --sqlite "$1" 2>/dev/null)
    case "$_mbs_out" in
        ''|error*|Error*|*Daemon*) return 1 ;;
        *) printf '%s\n' "$_mbs_out" ;;
    esac
}

# ----------------------------------------------------------------------
# zygisk / denylist state
# ----------------------------------------------------------------------

# magisk_zygisk -> "1" | "0" | "" (unknown)
# In module script environments Magisk exports ZYGISK_ENABLED=1 when on;
# otherwise ask the database (settings key 'zygisk').
magisk_zygisk() {
    if [ -n "${ZYGISK_ENABLED:-}" ]; then
        printf '%s' "$ZYGISK_ENABLED"
        return 0
    fi
    _mz=$(magisk_sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null | head -n 1 | tr -d '[:space:]')
    case "$_mz" in
        ''|*[!0-9]*) return 0 ;;
        *) printf '%s' "$_mz" ;;
    esac
}

# magisk_denylist_enforced -> "1" | "0" | "" (unknown)
magisk_denylist_enforced() {
    _mde=$(magisk_bin 2>/dev/null) && \
        _mde_out=$("$_mde" --denylist status 2>&1 | head -n 1)
    case "${_mde_out:-}" in
        *"not enforced"*) printf '0' ;;
        *enforced*)       printf '1' ;;
        *)
            # daemon unreachable or older CLI: fall back to the DB flag
            _mde_db=$(magisk_sqlite "SELECT value FROM settings WHERE key='denylist'" 2>/dev/null | head -n 1 | tr -d '[:space:]')
            case "$_mde_db" in
                ''|*[!0-9]*) return 0 ;;
                *) printf '%s' "$_mde_db" ;;
            esac
            ;;
    esac
}

# magisk_denylist_ls -> one "pkg|proc" line per entry (stdout)
magisk_denylist_ls() {
    _mdl=$(magisk_bin 2>/dev/null) || return 1
    "$_mdl" --denylist ls 2>/dev/null
    return 0
}

# strict Android package name: com.example.app (2+ segments)
_hpc_pkg_ok() {
    case "$1" in
        ''|*[!a-z0-9._]*) return 1 ;;
    esac
    [ "${#1}" -le 128 ] || return 1
    printf '%s' "$1" | grep -qE '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'
}

# magisk_denylist_add PKG -> JSON
magisk_denylist_add() {
    _mda="$1"
    _hpc_pkg_ok "$_mda" || { printf '{"ok":0,"error":"invalid package name"}\n'; return 1; }
    _mda_bin=$(magisk_bin 2>/dev/null) || { printf '{"ok":0,"error":"magisk CLI unavailable"}\n'; return 1; }
    _mda_out=$("$_mda_bin" --denylist add "$_mda" 2>&1)
    case "$_mda_out" in
        *"already exists"*)
            printf '{"ok":1,"note":"already in denylist"}\n' ;;
        *)
            case "$_mda_out" in
                *error*|*Error*|*Daemon*|*Invalid*)
                    printf '{"ok":0,"error":%s}\n' "$(_hpc_jesc "$_mda_out")" ;;
                *)
                    km_event denylist_add "denylist add: $_mda" 2>/dev/null
                    printf '{"ok":1,"pkg":%s}\n' "$(_hpc_jesc "$_mda")" ;;
            esac
            ;;
    esac
}

# magisk_denylist_rm PKG -> JSON
magisk_denylist_rm() {
    _mdr="$1"
    _hpc_pkg_ok "$_mdr" || { printf '{"ok":0,"error":"invalid package name"}\n'; return 1; }
    _mdr_bin=$(magisk_bin 2>/dev/null) || { printf '{"ok":0,"error":"magisk CLI unavailable"}\n'; return 1; }
    _mdr_out=$("$_mdr_bin" --denylist rm "$_mdr" 2>&1)
    case "$_mdr_out" in
        *"does not exist"*)
            printf '{"ok":1,"note":"was not in denylist"}\n' ;;
        *)
            case "$_mdr_out" in
                *error*|*Error*|*Daemon*|*Invalid*)
                    printf '{"ok":0,"error":%s}\n' "$(_hpc_jesc "$_mdr_out")" ;;
                *)
                    km_event denylist_rm "denylist rm: $_mdr" 2>/dev/null
                    printf '{"ok":1,"pkg":%s}\n' "$(_hpc_jesc "$_mdr")" ;;
            esac
            ;;
    esac
}

# ----------------------------------------------------------------------
# module inventory (read-only)
# ----------------------------------------------------------------------

# _hpc_jesc: JSON string escape (same invariants as km_jesc; kept local so
# this file stays sourceable before km_discover.sh is loaded)
_hpc_jesc() {
    _hj=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\t' ' ' | tr -d '\000-\037\177' | tr -d '\r')
    printf '"%s"' "$_hj"
}

# magisk_modules_list -> one "id<TAB>name<TAB>version<TAB>versionCode" line
# per module directory (HPC included). Read-only.
magisk_modules_list() {
    _mml_d="${MODULES_DIR:-/data/adb/modules}"
    [ -d "$_mml_d" ] || return 0
    for _mml_p in "$_mml_d"/*/module.prop; do
        [ -f "$_mml_p" ] || continue
        _mml_id=$(_mml_getprop "$_mml_p" id)
        [ -n "$_mml_id" ] || continue
        _mml_name=$(_mml_getprop "$_mml_p" name)
        [ -n "$_mml_name" ] || _mml_name="$_mml_id"
        _mml_ver=$(_mml_getprop "$_mml_p" version)
        [ -n "$_mml_ver" ] || _mml_ver="?"
        _mml_code=$(_mml_getprop "$_mml_p" versionCode)
        [ -n "$_mml_code" ] || _mml_code=""
        printf '%s\t%s\t%s\t%s\n' "$_mml_id" "$_mml_name" "$_mml_ver" "$_mml_code"
    done
    return 0
}

_mml_getprop() {
    # _mml_getprop FILE KEY -> value (first matching line, stripped)
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# magisk_modules_count -> number of module dirs with a module.prop
magisk_modules_count() {
    magisk_modules_list | wc -l | tr -d ' '
}

# ----------------------------------------------------------------------
# web server backend
# ----------------------------------------------------------------------

# hpc_web_httpd -> prints the httpd backend id that HPC can use:
#   "busybox:<path>"  when a usable busybox binary exists
#   "none"            otherwise
# toybox httpd is deliberately NOT a fallback: the Android toybox httpd is
# an inetd-only static file server without CGI or a listener (verified in
# the toybox source), so it cannot serve the HPC WebUI.
hpc_web_httpd() {
    if command -v web_busybox >/dev/null 2>&1; then
        _hwh=$(web_busybox 2>/dev/null) && { printf 'busybox:%s' "$_hwh"; return 0; }
    fi
    for _hwh in "$MAGISK_DATABIN/busybox" /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        [ -x "$_hwh" ] && { printf 'busybox:%s' "$_hwh"; return 0; }
    done
    printf 'none'
}

# ----------------------------------------------------------------------
# module self-update (through the official Magisk CLI)
# ----------------------------------------------------------------------

# hpc_zip_module_id ZIP -> prints the id= line of the zip's module.prop
# (module.prop must be at the zip root, the Magisk layout). Empty on error.
hpc_zip_module_id() {
    _hmz="$1"
    _hmz_bb=$(magisk_bin 2>/dev/null)
    [ -n "$_hmz_bb" ] || [ -x "$MAGISK_DATABIN/busybox" ] && _hmz_bb="$MAGISK_DATABIN/busybox"
    [ -n "$_hmz_bb" ] || return 1
    _hmz_out=$("$_hmz_bb" unzip -p "$_hmz" module.prop 2>/dev/null) || return 1
    printf '%s\n' "$_hmz_out" | sed -n 's/^id=//p' | head -n 1
}

# hpc_self_update ZIP -> JSON
# Strict rules:
#   * ZIP must be an absolute path under /data/local/tmp/ (the adb push
#     location) and end in .zip
#   * the zip must exist and be readable
#   * the zip's module.prop must declare id=hamedis_performance_core
# Then the official `magisk --install-module ZIP` is used; Magisk does the
# actual install and the user reboots.
hpc_self_update() {
    _hsu="$1"
    case "$_hsu" in
        "$HPC_UPDATE_TMPDIR"/*.zip) ;;
        *) printf '{"ok":0,"error":"zip must be under %s and end in .zip"}\n' "$HPC_UPDATE_TMPDIR"; return 1 ;;
    esac
    [ -f "$_hsu" ] || { printf '{"ok":0,"error":"zip not found"}\n'; return 1; }
    [ -r "$_hsu" ] || { printf '{"ok":0,"error":"zip not readable"}\n'; return 1; }

    _hsu_id=$(hpc_zip_module_id "$_hsu") || { printf '{"ok":0,"error":"could not read module.prop from zip"}\n'; return 1; }
    if [ "$_hsu_id" != "$HPC_SELF_ID" ]; then
        printf '{"ok":0,"error":"not an HPC module zip (expected id %s, found %s)"}\n' \
            "$HPC_SELF_ID" "$(_hpc_jesc "$_hsu_id")"
        return 1
    fi

    _hsu_bin=$(magisk_bin 2>/dev/null) || { printf '{"ok":0,"error":"magisk CLI unavailable"}\n'; return 1; }
    _hsu_out=$("$_hsu_bin" --install-module "$_hsu" 2>&1)
    case "$_hsu_out" in
        *error*|*Error*|*fail*|*Fail*)
            printf '{"ok":0,"error":"%s"}\n' "$(_hpc_jesc "$_hsu_out")" ;;
        *)
            km_event self_update "module update installed: $_hsu (reboot required)" 2>/dev/null
            printf '{"ok":1,"note":"module update installed - reboot to apply"}\n' ;;
    esac
}

# ----------------------------------------------------------------------
# capability discovery registration
# ----------------------------------------------------------------------

# km_magisk_scan -> register read-only magisk environment capabilities
# (skips silently when the km_reg helper is not available, e.g. in unit
# tests that source this file alone). env.root is registered by
# km_discover.sh, not here, to keep IDs unique.
km_magisk_scan() {
    command -v km_reg >/dev/null 2>&1 || return 0

    _kms_root="none"
    [ -d "$MAGISK_DATABIN" ] && _kms_root="magisk"
    [ -d /data/adb/ksu ] && _kms_root="kernelsu"
    [ -f /data/adb/ap ] && _kms_root="apatch"

    [ "$_kms_root" = "magisk" ] || return 0

    _kms_ver=$(magisk_version)
    _kms_code=$(magisk_version_code)
    _kms_tmp=$(magisk_tmp_path)
    _kms_z=$(magisk_zygisk)
    _kms_d=$(magisk_denylist_enforced)
    _kms_n=$(magisk_modules_count)
    _kms_h=$(hpc_web_httpd)

    km_reg env.magisk_ver "Magisk version" "magisk --version" "root" "r" info str 90 "$_kms_ver" "CLI via daemon (31.x returns e.g. 31.1:MAGISK:R)"
    km_reg env.magisk_code "Magisk version code" "magisk --version-code" "root" "r" info str 90 "${_kms_code:-?}" "numeric build code"
    km_reg env.magisk_tmp "Magisk tmpfs path" "magisk --path" "root" "r" info str 80 "${_kms_tmp:-?}" "tmpfs mount (usually /sbin)"
    case "$_kms_z" in
        '') km_reg env.zygisk "Zygisk" "magisk.db" "root" "r" info str 80 "unknown" "state unknown (daemon unreachable?)" ;;
        1)  km_reg env.zygisk "Zygisk" "magisk.db" "root" "r" info str 90 "on" "module environment / settings db" ;;
        *)  km_reg env.zygisk "Zygisk" "magisk.db" "root" "r" info str 90 "off" "module environment / settings db" ;;
    esac
    case "$_kms_d" in
        '') km_reg env.denylist "DenyList enforcement" "magisk --denylist status" "root" "r" info str 80 "unknown" "state unknown" ;;
        1)  km_reg env.denylist "DenyList enforcement" "magisk --denylist status" "root" "r" info str 90 "enforced" "hide root from selected apps" ;;
        *)  km_reg env.denylist "DenyList enforcement" "magisk --denylist status" "root" "r" info str 90 "off" "not enforcing" ;;
    esac
    km_reg env.modules "Installed modules" "/data/adb/modules" "fs" "r" info str 85 "$_kms_n" "count of module dirs with module.prop"
    km_reg env.httpd "WebUI httpd backend" "filesystem" "root" "r" info str 85 "${_kms_h:-none}" "toybox httpd is not usable (no CGI/listener); busybox required"
    return 0
}
