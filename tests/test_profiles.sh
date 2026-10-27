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
# a stale copy the USER modified must be kept - the name is
# deliberately NOT one of the retired v1.11 built-ins (those are
# stashed instead; see the migration test at the end of this file)
printf 'PROFILE_NAME="MINE"\n' >"$HPC_DATA/profiles/legacytest.conf"
printf '000000000000000000000000000000000000dead\tlegacytest\n' >>"$HPC_STATE/profiles_seed.txt"
hpc_init_config
check "stale seeded copy removed" "$([ ! -f "$HPC_DATA/profiles/cool.conf" ] && echo 0 || echo 1)"
check "user-modified stale copy kept" "$([ -f "$HPC_DATA/profiles/legacytest.conf" ] && echo 0 || echo 1)"
# the delete test below expects no seeded builtin copies in the user
# dir - remove the ones this section created (keep user semantics clean)
rm -f "$HPC_DATA/profiles/legacytest.conf"
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


echo "== v1.11 -> v1.12 migration (pre-manifest seeded copies) =="
# Simulate a v1.11.x install state: seeded copies of profiles that no
# longer ship, and NO seed manifest (it is a v1.12+ concept). After
# hpc_init_config the listed set must be exactly the 7 curated ones.
rm -f "$HPC_DATA/profiles/"*.conf
rm -rf "$HPC_STATE/retired_profiles_v11"
rm -f "$HPC_STATE/profiles_seed.txt"
# pristine seeded copy of the v1.11 builtin 'cool' (exact old content)
cat >"$HPC_DATA/profiles/cool.conf" <<'HPCOLD'
# Hamedis Performance Core - COOL profile
# Priority: temperature and battery life over peak throughput.
#
# All values are HINTS. Anything unsupported by this kernel is skipped
# and logged; nothing here is mandatory.

PROFILE_NAME="COOL"
PROFILE_DESC="Lowest temperature and best battery life"

# --- CPU -------------------------------------------------------------
# Governor preference list, best match wins.
CPU_GOVERNOR_PREF="conservative powersave schedutil ondemand"

# Cap max frequency as a PERCENTAGE of the hardware maximum.
# Never a hardcoded kHz value: that would be device-specific and unsafe.
CPU_MAX_PERCENT=70
# Minimum frequency percentage. Keep low so the CPU can idle deeply.
CPU_MIN_PERCENT=0

# schedutil tunables (only applied if the governor exposes them)
CPU_UP_RATE_LIMIT_US=20000
CPU_DOWN_RATE_LIMIT_US=20000
CPU_HISPEED_LOAD=95

# --- GPU -------------------------------------------------------------
GPU_GOVERNOR_PREF="powersave simple_ondemand msm-adreno-tz"
GPU_MAX_PERCENT=70
GPU_MIN_PERCENT=0
# Aggressive idle timeout: power the GPU down quickly (milliseconds).
GPU_IDLE_TIMER=58
# Leave kernel GPU throttling ON.
GPU_THROTTLING=1
# force_clk_on = 0 lets the GPU clock gate normally.
GPU_FORCE_CLK=0

# --- Scheduler -------------------------------------------------------
SCHED_MIN_GRANULARITY_NS=2250000
SCHED_WAKEUP_GRANULARITY_NS=3000000
SCHED_MIGRATION_COST_NS=500000
SCHED_LATENCY_NS=18000000
SCHED_CHILD_RUNS_FIRST=0
SCHED_AUTOGROUP=1

# --- VM / memory -----------------------------------------------------
# Higher swappiness: prefer compressed zRAM over dropping page cache.
VM_SWAPPINESS=120
VM_VFS_CACHE_PRESSURE=100
VM_DIRTY_RATIO=20
VM_DIRTY_BACKGROUND_RATIO=10
VM_DIRTY_EXPIRE_CENTISECS=3000
VM_DIRTY_WRITEBACK_CENTISECS=1500
VM_PAGE_CLUSTER=0
VM_STAT_INTERVAL=10

# --- Graphics ---------------------------------------------------------
# auto = use Vulkan when a driver exists (lower CPU driver overhead).
# On COOL we still prefer Vulkan: it costs less CPU for the same frame.
GFX_RENDERER=auto

# --- Module behaviour ------------------------------------------------
# How often the service loop wakes up, in seconds. Longer = less overhead.
POLL_INTERVAL=60
# Thermal thresholds in degrees Celsius.
TEMP_WARM=42
TEMP_HOT=48
TEMP_CRITICAL=54
HPCOLD
# user-modified old 'standby' (v1.11 content + a user edit on the end)
cat >"$HPC_DATA/profiles/standby.conf" <<'HPCOLD'
# Hamedis Performance Core - STANDBY profile
# Priority: minimal drain when the phone is mostly unused (night,
# bag, desk). Lowest clocks, fastest GPU sleep, longest service poll.
# Games will still switch to GAME_PROFILE when detected.

PROFILE_NAME="STANDBY"
PROFILE_DESC="Minimal background drain - lowest clocks, deep sleep"
PROFILE_VERSION=1

# --- CPU -------------------------------------------------------------
CPU_GOVERNOR_PREF="powersave conservative schedutil ondemand"
CPU_MAX_PERCENT=50
CPU_MIN_PERCENT=0
CPU_UP_RATE_LIMIT_US=40000
CPU_DOWN_RATE_LIMIT_US=20000
CPU_HISPEED_LOAD=99

# --- GPU -------------------------------------------------------------
GPU_GOVERNOR_PREF="powersave simple_ondemand msm-adreno-tz"
GPU_MAX_PERCENT=55
GPU_MIN_PERCENT=0
GPU_IDLE_TIMER=40
GPU_THROTTLING=1
GPU_FORCE_CLK=0

# --- Scheduler -------------------------------------------------------
SCHED_MIN_GRANULARITY_NS=3000000
SCHED_WAKEUP_GRANULARITY_NS=5000000
SCHED_MIGRATION_COST_NS=1000000
SCHED_LATENCY_NS=30000000
SCHED_CHILD_RUNS_FIRST=0
SCHED_AUTOGROUP=1

# --- VM / memory -----------------------------------------------------
VM_SWAPPINESS=160
VM_VFS_CACHE_PRESSURE=100
VM_DIRTY_RATIO=15
VM_DIRTY_BACKGROUND_RATIO=8
VM_PAGE_CLUSTER=0
VM_STAT_INTERVAL=15

# --- Graphics ---------------------------------------------------------
GFX_RENDERER=auto

# --- Module behaviour ------------------------------------------------
POLL_INTERVAL=120
TEMP_WARM=40
TEMP_HOT=46
TEMP_CRITICAL=52
HPCOLD
printf 'SCHED_LATENCY_NS=12345\n' >>"$HPC_DATA/profiles/standby.conf"
hpc_init_config
check "migration: pristine old seeded copy removed" "$([ ! -f "$HPC_DATA/profiles/cool.conf" ] && echo 0 || echo 1)"
check "migration: modified old copy left the list" "$([ ! -f "$HPC_DATA/profiles/standby.conf" ] && echo 0 || echo 1)"
check "migration: modified old copy stashed (data kept)" "$([ -f "$HPC_STATE/retired_profiles_v11/standby.conf" ] && echo 0 || echo 1)"
check "migration: stash preserves the user edit" "$(grep -q 'SCHED_LATENCY_NS=12345' "$HPC_STATE/retired_profiles_v11/standby.conf" 2>/dev/null && echo 0 || echo 1)"
_ml=$(km_prof_list)
_ml_count=$(printf '%s' "$_ml" | grep -o '"name":"[a-z0-9_]*"' | sort -u | wc -l)
check "migration: listed set is exactly the 7" "$([ "$_ml_count" -eq 7 ] && echo 0 || echo 1)"
check "migration: no retired name listed" "$(printf '%s' "$_ml" | grep -q '"name":"cool"' && echo 1 || echo 0)"
# idempotent: a second boot is a no-op
hpc_init_config
check "migration: idempotent on re-run" "$([ ! -f "$HPC_DATA/profiles/cool.conf" ] && [ ! -f "$HPC_DATA/profiles/standby.conf" ] && echo 0 || echo 1)"

test_result "test_profiles"
