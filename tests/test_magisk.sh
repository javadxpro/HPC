#!/bin/sh
# Magisk system integration tests: fake magisk CLI (v31-style), version
# parsing, denylist validation + round-trip, module inventory, self-update
# guards, discovery registration, doctor, and the mgsk API endpoint.
. "$(dirname "$0")/lib.sh"

source_hpc
fake_tree
point_at_fake

# ---------------------------------------------------------------- fake magisk
MAGISK_DATABIN="$T/data/adb/magisk"
MODULES_DIR="$T/data/adb/modules"
export MAGISK_DATABIN MODULES_DIR
HPC_UPDATE_TMPDIR="$T/data/local/tmp"
export HPC_UPDATE_TMPDIR
unset ZYGISK_ENABLED

mkdir -p "$MAGISK_DATABIN" "$MODULES_DIR"
# fake busybox (executable; emulates only what HPC calls: unzip -p)
cat >"$MAGISK_DATABIN/busybox" <<'FAKEBB'
#!/bin/sh
# fake busybox for HPC tests
case "$1" in
    unzip)
        # unzip -p <zip> <inner>
        [ "$2" = "-p" ] || exit 1
        zip="$3"; inner="$4"
        case "$inner" in
            module.prop)
                if [ -f "$zip" ]; then
                    printf 'id=%s\nversion=%s\n' \
                        "$(sed -n 's/^id=//p' "$zip" 2>/dev/null | head -n1)" \
                        "$(sed -n 's/^version=//p' "$zip" 2>/dev/null | head -n1)"
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 0 ;;
esac
FAKEBB
chmod 0755 "$MAGISK_DATABIN/busybox"

# fake magisk CLI, stateful denylist in $T
cat >"$MAGISK_DATABIN/magisk" <<'FAKEMG'
#!/bin/sh
# fake magisk v31-style CLI
STATE="${FAKE_MG_STATE:?}"
case "$1" in
    --version)      printf '31.1:MAGISK:R\n' ;;
    --version-code) printf '31100\n' ;;
    --path)         printf '/sbin\n' ;;
    --sqlite)
        case "$2" in
            *zygisk*)    printf '1\n' ;;
            *denylist*)  printf '1\n' ;;
            *) printf '' ;;
        esac
        ;;
    --denylist)
        cmd="$2"
        case "$cmd" in
            status) printf 'Denylist is enforced\n' 1>&2 ;;
            ls)
                [ -f "$STATE" ] && cat "$STATE"
                ;;
            add)
                pkg="$3"
                if [ -f "$STATE" ] && grep -q "^$pkg|" "$STATE"; then
                    printf 'Target already exists in denylist\n' 1>&2
                else
                    printf '%s|\n' "$pkg" >>"$STATE"
                    printf 'Denylist is enforced\n' 1>&2
                fi
                ;;
            rm)
                pkg="$3"
                if [ -f "$STATE" ] && grep -q "^$pkg|" "$STATE"; then
                    { grep -v "^$pkg|" "$STATE" || true; } >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
                    printf 'Denylist is enforced\n' 1>&2
                else
                    printf 'Target does not exist in denylist\n' 1>&2
                fi
                ;;
            *) printf 'deny: bad command\n' 1>&2; exit 1 ;;
        esac
        ;;
    --install-module)
        [ -f "$2" ] || { printf 'install: no such file\n' 1>&2; exit 1; }
        printf 'Installing module: %s\n' "$2"
        printf 'Installation successful.\n'
        ;;
    *) printf 'magisk: unknown arg %s\n' "$1" 1>&2; exit 1 ;;
esac
exit 0
FAKEMG
chmod 0755 "$MAGISK_DATABIN/magisk"
export FAKE_MG_STATE="$T/denylist.state"
: >"$FAKE_MG_STATE"

# fake module dirs
mkdir -p "$MODULES_DIR/hamedis_performance_core" "$MODULES_DIR/othermod"
printf 'id=hamedis_performance_core\nname=HPC\nversion=v1.11.0\nversionCode=11100\n' \
    >"$MODULES_DIR/hamedis_performance_core/module.prop"
printf 'id=othermod\nname=Other\nversion=1.0\nversionCode=1\n' \
    >"$MODULES_DIR/othermod/module.prop"

echo "== magisk detection =="
check "magisk present" "$(magisk_present && echo 0 || echo 1)"
check_eq "version parsed" "31.1" "$(magisk_version)"
check_eq "version code" "31100" "$(magisk_version_code)"
check_eq "tmp path" "/sbin" "$(magisk_tmp_path)"
check_eq "zygisk from db" "1" "$(magisk_zygisk)"
check_eq "zygisk env override" "0" "$(ZYGISK_ENABLED=0 magisk_zygisk)"
check_eq "denylist enforced" "1" "$(magisk_denylist_enforced)"

echo "== package validation =="
check "pkg ok accepted" "$(_hpc_pkg_ok com.example.app && echo 0 || echo 1)"
check "pkg UPPER rejected" "$(_hpc_pkg_ok COM.EXAMPLE && echo 1 || echo 0)"
check "pkg single-segment rejected" "$(_hpc_pkg_ok example && echo 1 || echo 0)"
check "pkg semicolon rejected" "$(_hpc_pkg_ok 'com.x;rm' && echo 1 || echo 0)"
check "pkg slash rejected" "$(_hpc_pkg_ok 'com/x' && echo 1 || echo 0)"
check "pkg dots rejected" "$(_hpc_pkg_ok 'com..x' && echo 1 || echo 0)"
check "pkg traversal rejected" "$(_hpc_pkg_ok '../etc/passwd' && echo 1 || echo 0)"

echo "== denylist add / rm =="
r=$(magisk_denylist_add com.example.bank)
check_json "denyadd json" "$r"
check "denyadd ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "denyadd recorded" "$(grep -q '^com.example.bank|' "$FAKE_MG_STATE" && echo 0 || echo 1)"
r=$(magisk_denylist_add com.example.bank)
check "denyadd duplicate noted" "$(printf '%s' "$r" | grep -q 'already in denylist' && echo 0 || echo 1)"
r=$(magisk_denylist_add 'bad..pkg')
check "denyadd invalid rejected" "$(printf '%s' "$r" | grep -q 'invalid package name' && echo 0 || echo 1)"
r=$(magisk_denylist_rm com.example.bank)
check_json "denyrmm json" "$r"
check "denyrmm ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "denyrmm removed" "$(! grep -q '^com.example.bank|' "$FAKE_MG_STATE" && echo 0 || echo 1)"
r=$(magisk_denylist_rm com.example.bank)
check "denyrmm missing noted" "$(printf '%s' "$r" | grep -q 'was not in denylist' && echo 0 || echo 1)"

echo "== module inventory =="
ml=$(magisk_modules_list)
check "modules count 2" "$([ "$(printf '%s\n' "$ml" | wc -l | tr -d ' ')" = "2" ] && echo 0 || echo 1)"
_tab=$(printf '\t')
check "modules includes hpc" "$(printf '%s\n' "$ml" | grep -q "^hamedis_performance_core${_tab}" && echo 0 || echo 1)"
check "modules version parsed" "$(printf '%s\n' "$ml" | grep 'hamedis_performance_core' | grep -q 'v1.11.0' && echo 0 || echo 1)"

echo "== self-update guards =="
r=$(hpc_self_update /data/data/evil/app.zip)
check "update outside tmp rejected" "$(printf '%s' "$r" | grep -q 'must be under' && echo 0 || echo 1)"
r=$(hpc_self_update "$HPC_UPDATE_TMPDIR/nope.zip")
check "update missing zip rejected" "$(printf '%s' "$r" | grep -q 'zip not found' && echo 0 || echo 1)"
mkdir -p "$T/data/local/tmp"
printf 'id=evil_module\nversion=v1\n' >"$T/data/local/tmp/evil.zip"
r=$(hpc_self_update "$T/data/local/tmp/evil.zip")
check "update wrong id rejected" "$(printf '%s' "$r" | grep -q 'not an HPC module zip' && echo 0 || echo 1)"
printf 'id=hamedis_performance_core\nversion=v9.9.9\n' >"$T/data/local/tmp/hpc_new.zip"
r=$(hpc_self_update "$T/data/local/tmp/hpc_new.zip")
check_json "update json" "$r"
check "update ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "update reboot note" "$(printf '%s' "$r" | grep -q 'reboot' && echo 0 || echo 1)"

echo "== discovery registration =="
km_caps_scan
check "registry has magisk version" "$(grep -q "env.magisk_ver${_tab}" "$KM_REG_TSV" && echo 0 || echo 1)"
check "registry has httpd backend" "$(grep -q "env.httpd${_tab}" "$KM_REG_TSV" && echo 0 || echo 1)"
check "registry magisk version value" "$(awk -F'\t' '$1=="env.magisk_ver"{print $9}' "$KM_REG_TSV" | grep -q '31.1' && echo 0 || echo 1)"

echo "== doctor =="
r=$(km_doctor 2>/dev/null)
check "doctor magisk line" "$(printf '%s\n' "$r" | grep -q 'PASS  magisk  version 31.1' && echo 0 || echo 1)"
check "doctor httpd line" "$(printf '%s\n' "$r" | grep -q 'PASS  httpd  backend available' && echo 0 || echo 1)"

echo "== mgsk api =="
# api.sh needs the fake env; source it in a subshell like test_api.sh.
# HPC_WEB_MODDIR lets api.sh find the module tree in the sandbox.
export HPC_WEB_MODDIR="$MOD"
call_api_mg() {
    QUERY_STRING="$1"
    out=$( { . "$MOD/webroot/cgi-bin/api.sh"; } 2>/dev/null )
    printf '%s\n' "$out" | sed -n '/^\r\?$/,$p' | tail -n +2
}
r=$(call_api_mg "action=mgsk&value=info")
check_json "mgsk info json" "$r"
check "mgsk info version" "$(printf '%s' "$r" | grep -q '"version":"31.1"' && echo 0 || echo 1)"
check "mgsk info zygisk" "$(printf '%s' "$r" | grep -q '"zygisk":1' && echo 0 || echo 1)"
r=$(call_api_mg "action=mgsk&value=modules")
check_json "mgsk modules json" "$r"
check "mgsk modules has hpc" "$(printf '%s' "$r" | grep -q 'hamedis_performance_core' && echo 0 || echo 1)"
r=$(call_api_mg "action=mgsk&value=denylist")
check_json "mgsk denylist json" "$r"
check "mgsk denylist enforced" "$(printf '%s' "$r" | grep -q '"enforced":true' && echo 0 || echo 1)"
r=$(call_api_mg "action=mgsk&value=denyadd&pkg=com.example.web")
check_json "mgsk denyadd json" "$r"
check "mgsk denyadd ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
r=$(call_api_mg "action=mgsk&value=denyadd&pkg=../etc")
check "mgsk denyadd traversal rejected" "$(printf '%s' "$r" | grep -q 'invalid package name' && echo 0 || echo 1)"
r=$(call_api_mg "action=mgsk&value=bogus")
check "mgsk unknown sub rejected" "$(printf '%s' "$r" | grep -q 'unknown mgsk sub' && echo 0 || echo 1)"

test_result "test_magisk"
