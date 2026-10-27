#!/bin/sh
# Profile management tests: strict import validation, CRUD, compare
. "$(dirname "$0")/lib.sh"

source_hpc
fake_tree
point_at_fake
# seed builtin profiles for this test
cp "$MOD"/config/profiles/*.conf "$T/mod/config/profiles/" 2>/dev/null

echo "== list =="
l=$(km_prof_list)
check_json "list json" "$l"
check "list contains balanced" "$(printf '%s' "$l" | grep -q '"name":"balanced"' && echo 0 || echo 1)"
check "list marks current" "$(printf '%s' "$l" | grep -q '"current":"balanced"' && echo 0 || echo 1)"
check "new profiles present" "$(printf '%s' "$l" | grep -q '"name":"battery_saver"' && echo 0 || echo 1)"

echo "== curated profile set (v1.12.0) =="
# exactly the 7 shipped profiles - no more, no less
for _cp in overclock gaming120 gaming90 performance balanced battery_saver longevity; do
    check "shipped: $_cp" "$(printf '%s' "$l" | grep -q "\"name\":\"$_cp\"" && echo 0 || echo 1)"
done
for _cp in cool silent multitasking standby; do
    check "removed: $_cp" "$(printf '%s' "$l" | grep -q "\"name\":\"$_cp\"" && echo 1 || echo 0)"
done
# the new overclock profile pins CPU floor to the hardware max
oc=$(km_prof_show overclock)
check "overclock shows" "$(printf '%s' "$oc" | grep -q 'CPU_MIN_PERCENT' && echo 0 || echo 1)"
check "overclock floor=100" "$(printf '%s' "$oc" | grep -q '"CPU_MIN_PERCENT":"100"' && echo 0 || echo 1)"
check "overclock keeps GPU throttling on" "$(printf '%s' "$oc" | grep -q '"GPU_THROTTLING":"1"' && echo 0 || echo 1)"

echo "== seed cleanup (stale seeded profiles) =="
# NOTE: nested command substitutions inside double quotes use PLAIN
# double quotes - \" there would stay a literal backslash in dash.
# shellcheck source=/dev/null
. "$HPC_SCRIPTS/common.sh"
hpc_init_dirs
hpc_init_config
check "seeded: overclock in data dir" "$([ -f "$HPC_DATA/profiles/overclock.conf" ] && echo 0 || echo 1)"
check "seed manifest written" "$([ -s "$HPC_STATE/profiles_seed.txt" ] && echo 0 || echo 1)"
# a stale seeded copy (untouched) of a removed profile gets cleaned
cp "$MOD/config/profiles/balanced.conf" "$HPC_DATA/profiles/cool.conf"
printf '%s\tcool\n' "$(sha1sum "$HPC_DATA/profiles/cool.conf" | cut -d' ' -f1)" >>"$HPC_STATE/profiles_seed.txt"
# a stale copy the USER modified must be kept
printf 'PROFILE_NAME="MINE"\n' >"$HPC_DATA/profiles/standby.conf"
printf '000000000000000000000000000000000000dead\tstandby\n' >>"$HPC_STATE/profiles_seed.txt"
hpc_init_config
check "stale seeded copy removed" "$([ ! -f "$HPC_DATA/profiles/cool.conf" ] && echo 0 || echo 1)"
check "user-modified stale copy kept" "$([ -f "$HPC_DATA/profiles/standby.conf" ] && echo 0 || echo 1)"
# the delete test below expects no seeded builtin copies in the user
# dir - remove the ones this section created (keep user semantics clean)
rm -f "$HPC_DATA/profiles/standby.conf"
for _cp in overclock gaming120 gaming90 performance balanced battery_saver longevity; do
    rm -f "$HPC_DATA/profiles/$_cp.conf"
done
rm -f "$HPC_STATE/profiles_seed.txt"

echo "== show / compare =="
s=$(km_prof_show balanced)
check_json "show json" "$s"
check "show has keys" "$(printf '%s' "$s" | grep -q 'CPU_GOVERNOR_PREF' && echo 0 || echo 1)"
c=$(km_prof_compare balanced performance)
check_json "compare json" "$c"
check "compare found differences" "$(printf '%s' "$c" | grep -q '"key":"CPU_MIN_PERCENT"' && echo 0 || echo 1)"

echo "== import: valid =="
GOOD='PROFILE_NAME="TEST"
PROFILE_DESC="valid test profile"
CPU_GOVERNOR_PREF="schedutil powersave"
CPU_MAX_PERCENT=80
CPU_MIN_PERCENT=10
POLL_INTERVAL=45'
r=$(km_prof_import testprof "$GOOD")
check_json "import json" "$r"
check "valid import accepted" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "imported file exists" "$([ -f "$KM_PROF_USER/testprof.conf" ] && echo 0 || echo 1)"
check "import did not activate" "$([ "$(current_profile)" = "balanced" ] && echo 0 || echo 1)"

echo "== import: rejections =="
r=$(km_prof_import badname! 'CPU_MAX_PERCENT=50')
check "bad name rejected" "$(printf '%s' "$r" | grep -q 'invalid profile name' && echo 0 || echo 1)"
r=$(km_prof_import test2 'UNKNOWN_KEY=1')
check "unknown key rejected" "$(printf '%s' "$r" | grep -q 'unknown key' && echo 0 || echo 1)"
r=$(km_prof_import test3 'CPU_MAX_PERCENT=150')
check "out-of-range percent rejected" "$(printf '%s' "$r" | grep -q 'out of range' && echo 0 || echo 1)"
r=$(km_prof_import test4 'CPU_MAX_PERCENT=50
POLL_INTERVAL=999')
check "out-of-range poll rejected" "$(printf '%s' "$r" | grep -q 'out of range' && echo 0 || echo 1)"
r=$(km_prof_import test5 'CPU_GOVERNOR_PREF="schedutil;rm -rf /"')
check "metachar governor rejected" "$(printf '%s' "$r" | grep -qE 'prohibited characters|governor preference malformed' && echo 0 || echo 1)"
r=$(km_prof_import test6 'CPU_MAX_PERCENT=$(reboot)')
check "dollar-value rejected" "$(printf '%s' "$r" | grep -q 'prohibited characters' && echo 0 || echo 1)"
check "rejected import created no file" "$([ ! -f "$KM_PROF_USER/test6.conf" ] && echo 0 || echo 1)"

echo "== import: rejection JSON stays valid with special chars =="
r=$(km_prof_import test7 'BAD LINE "quoted" stuff')
check_json "import rejection json (quotes in line)" "$r"
check "special-char line rejected" "$(printf '%s' "$r" | grep -q 'not KEY=VALUE' && echo 0 || echo 1)"

echo "== duplicate / delete =="
r=$(km_prof_duplicate testprof copyprof)
check "duplicate ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "duplicate exists" "$([ -f "$KM_PROF_USER/copyprof.conf" ] && echo 0 || echo 1)"
r=$(km_prof_delete balanced)
check "builtin delete refused" "$(printf '%s' "$r" | grep -q 'only user profiles' && echo 0 || echo 1)"
_cur=$(_cur_prof 2>/dev/null; current_profile)
r=$(km_prof_delete copyprof)
check "user delete ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "user delete removed" "$([ ! -f "$KM_PROF_USER/copyprof.conf" ] && echo 0 || echo 1)"

echo "== export =="
e=$(km_prof_export testprof)
check_json "export json" "$e"
check "export has content" "$(printf '%s' "$e" | grep -q 'CPU_GOVERNOR_PREF' && echo 0 || echo 1)"

test_result "test_profiles"
