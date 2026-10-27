#!/bin/sh
# API endpoint tests: source api.sh inside the harness with a faked
# QUERY_STRING and validate the JSON responses.
. "$(dirname "$0")/lib.sh"

source_hpc
fake_tree
point_at_fake
km_caps_scan

# api.sh defines its own MODDIR logic; point it at the real module dir
# so it can find the scripts, but HPC_DATA etc. stay fake.
export HPC_WEB_MODDIR="$MOD"

# source api.sh inside a subshell that still has our stub functions
call_api2() {
    QUERY_STRING="$1"
    out=$( { . "$MOD/webroot/cgi-bin/api.sh"; } 2>/dev/null )
    # strip the HTTP header lines
    printf '%s\n' "$out" | sed -n '/^\r\?$/,$p' | tail -n +2
}

echo "== routing: invalid action rejected =="
r=$(call_api2 "action=bogus")
check "invalid action rejected" "$(printf '%s' "$r" | grep -q 'invalid action' && echo 0 || echo 1)"

echo "== km: status =="
r=$(call_api2 "action=km&value=status")
check_json "km status json" "$r"
check "km status has kernel" "$(printf '%s' "$r" | grep -q '"kernel"' && echo 0 || echo 1)"
check "km status root env" "$(printf '%s' "$r" | grep -q '"root_env":"none"' && echo 0 || echo 1)"

echo "== km: cpu =="
r=$(call_api2 "action=km&value=cpu")
check_json "km cpu json" "$r"
check "km cpu has policies" "$(printf '%s' "$r" | grep -q '"policies":\[' && echo 0 || echo 1)"

echo "== km: caps =="
r=$(call_api2 "action=km&value=caps")
check_json "km caps json" "$r"
check "km caps has controls" "$(printf '%s' "$r" | grep -q '"controls":\[' && echo 0 || echo 1)"

echo "== kmctl: write through the engine =="
r=$(call_api2 "action=kmctl&id=cpu1.governor&value=powersave&src=test")
check_json "kmctl json" "$r"
check "kmctl applied" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "kmctl wrote node" "$(grep -q '^powersave$' "$T/sys/cpu/cpufreq/pol0/scaling_governor" && echo 0 || echo 1)"

echo "== kmctl: injection attempt rejected =="
r=$(call_api2 "action=kmctl&id=cpu1.governor&value=%3Brm%20-rf%20/%26%26whoami")
check "metachar value rejected" "$(printf '%s' "$r" | grep -q 'invalid value' && echo 0 || echo 1)"
check "node unchanged after injection" "$(grep -q '^powersave$' "$T/sys/cpu/cpufreq/pol0/scaling_governor" && echo 0 || echo 1)"

echo "== kmprof: list via api =="
r=$(call_api2 "action=kmprof&value=list")
check_json "kmprof list json" "$r"
check "kmprof list has profiles" "$(printf '%s' "$r" | grep -q '"profiles":\[' && echo 0 || echo 1)"

echo "== kmprof: import via base64 =="
B64=$(printf 'PROFILE_NAME="API"\nCPU_MAX_PERCENT=75\nCPU_MIN_PERCENT=5' | base64 | tr -d '\n')
r=$(call_api2 "action=kmprof&value=import&name=apip&b64=$B64")
check_json "kmprof import json" "$r"
check "kmprof import ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
# base64 with junk rejected
r=$(call_api2 "action=kmprof&value=import&name=apix&b64=!!!notbase64!!!")
check "bad base64 rejected" "$(printf '%s' "$r" | grep -q 'bad base64' && echo 0 || echo 1)"
# path traversal in name rejected
r=$(call_api2 "action=kmprof&value=show:../../etc/passwd")
check "traversal name rejected" "$(printf '%s' "$r" | grep -q 'bad profile name' && echo 0 || echo 1)"

echo "== kmrollback via api =="
r=$(call_api2 "action=kmrollback&value=1")
check_json "kmrollback json" "$r"

echo "== kmreport: bad export name rejected =="
r=$(call_api2 "action=kmreport&value=file:../../etc/passwd")
check "export traversal rejected" "$(printf '%s' "$r" | grep -q 'bad export name' && echo 0 || echo 1)"

echo "== kmreport doctor =="
r=$(call_api2 "action=kmreport&value=doctor")
check_json "kmreport doctor json" "$r"
check "doctor via api has report" "$(printf '%s' "$r" | grep -q 'DOCTOR RESULT:' && echo 0 || echo 1)"

echo "== config guard (a broken config cannot kill the API) =="
# shellcheck source=/dev/null
. "$HPC_SCRIPTS/common.sh"
# 1) valid config passes
printf 'MODE=cool\nPOLL_INTERVAL=45\n' >"$HPC_CONFIG"
check "valid config ok" "$( [ "$(hpc_config_check)" = "ok" ] && echo 0 || echo 1 )"
# 2) syntax error is caught with a line number
printf '# header\nMODE=cool\nbroken ( line\nPOLL_INTERVAL=45\n' >"$HPC_CONFIG"
chk=$(hpc_config_check)
check "syntax error flagged" "$([ "$chk" != "ok" ] && echo 0 || echo 1)"
check "syntax error has line number" "$(printf '%s' "$chk" | grep -qE '[0-9]+:' && echo 0 || echo 1)"
# 3) stray word (valid syntax, executed at source time) is caught
printf 'MODE=cool\ncool\n' >"$HPC_CONFIG"
chk=$(hpc_config_check)
check "stray word flagged" "$([ "$chk" != "ok" ] && echo 0 || echo 1)"
check "stray word says not found" "$(printf '%s' "$chk" | grep -q 'not found' && echo 0 || echo 1)"
# 4) hpc_load_config degrades to defaults instead of dying
hpc_load_config
check "load survives broken config" "$( [ "$POLL_INTERVAL" = "45" ] && echo 0 || echo 1 )"
check "load fell back to default MODE" "$( [ "$MODE" = "balanced" ] && echo 0 || echo 1 )"
# 5) a repaired/clean config passes again
printf 'MODE=cool\nPOLL_INTERVAL=45\n' >"$HPC_CONFIG"
check "clean config ok again" "$( [ "$(hpc_config_check)" = "ok" ] && echo 0 || echo 1 )"
# 6) with a broken config the API still answers (degraded defaults)
printf 'MODE=cool\ncool\n' >"$HPC_CONFIG"
r=$(call_api2 "action=ping")
check_json "api json despite broken config" "$r"
check "api answers despite broken config" "$(printf '%s' "$r" | grep -q '"ok":true' && echo 0 || echo 1)"
printf 'MODE=cool\nPOLL_INTERVAL=45\n' >"$HPC_CONFIG"

echo "== backward compat: old endpoints still work =="
r=$(call_api2 "action=ping")
check "ping works" "$(printf '%s' "$r" | grep -q 'ok' && echo 0 || echo 1)"
r=$(call_api2 "action=boost")
check_json "boost json" "$r"

test_result "test_api"
