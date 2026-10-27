#!/bin/sh
# Registry / transaction engine tests
. "$(dirname "$0")/lib.sh"

source_hpc
fake_tree
point_at_fake
km_caps_scan

echo "== validation =="
km_ctl_validate cpu1.governor performance; check "valid governor accepted" "$([ $? -eq 0 ] && echo 0 || echo 1)"
r=$(km_ctl_validate cpu1.governor bogusgov); check "unknown governor rejected" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "rejection mentions kernel list" "$([ "$r" = "value not in kernel list (schedutil|performance|powersave|ondemand)" ] && echo 0 || echo 1)"
km_ctl_validate cpu1.max_freq 99999999 >/dev/null; check "freq above hw max rejected" "$([ $? -ne 0 ] && echo 0 || echo 1)"
km_ctl_validate cpu1.max_freq 100000 >/dev/null; check "freq below hw min rejected" "$([ $? -ne 0 ] && echo 0 || echo 1)"
km_ctl_validate cpu1.max_freq 1500000 >/dev/null; check "freq within range accepted" "$([ $? -eq 0 ] && echo 0 || echo 1)"
km_ctl_validate vm.swappiness 500 >/dev/null; check "swappiness out of range rejected" "$([ $? -ne 0 ] && echo 0 || echo 1)"
km_ctl_validate vm.swappiness 60 >/dev/null; check "swappiness in range accepted" "$([ $? -eq 0 ] && echo 0 || echo 1)"
km_ctl_validate net.tcp_cc bbr >/dev/null 2>&1
# bbr is not in the available list -> must be rejected
check "tcp cc rejected when not in list" "$([ $? -ne 0 ] && echo 0 || echo 1)"
km_ctl_validate cpu1.governor 'a;rm -rf /' >/dev/null; check "shell metachars rejected" "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo "== writes =="
r=$(km_ctl_set cpu1.governor performance cli)
check_json "set result json" "$r"
check "set ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "cpu1 wrote first policy only" "$(grep -q '^performance$' "$T/sys/cpu/cpufreq/pol0/scaling_governor" && echo 0 || echo 1)"
check "second policy untouched" "$(grep -q '^schedutil$' "$T/sys/cpu/cpufreq/pol1/scaling_governor" && echo 0 || echo 1)"
r=$(km_ctl_set cpu2.governor performance cli)
check "cpu2 wrote second policy" "$(grep -q '^performance$' "$T/sys/cpu/cpufreq/pol1/scaling_governor" && echo 0 || echo 1)"
check "change log recorded" "$(grep -q 'cpu1.governor' "$KM_CHANGE_LOG" && echo 0 || echo 1)"
check "log entry status ok" "$(awk -F '\t' '$2=="cpu1.governor" && $8=="ok" {f=1} END{exit !f}' "$KM_CHANGE_LOG" && echo 0 || echo 1)"
# redundant write is a no-op
r=$(km_ctl_set cpu1.governor performance cli)
check "redundant write skipped" "$(printf '%s' "$r" | grep -q '"skipped":1' && echo 0 || echo 1)"

echo "== unsupported control =="
r=$(km_ctl_set cpu9.governor performance cli)
check "missing interface -> not supported" "$(printf '%s' "$r" | grep -q 'not supported' && echo 0 || echo 1)"
check "unsupported recorded in log" "$(awk -F '\t' '$8=="unsupported" {f=1} END{exit !f}' "$KM_CHANGE_LOG" && echo 0 || echo 1)"

echo "== protected path (plugin control on thermal zone mode) =="
km_plugin_register plugin.test_thermal "test thermal" "$T/sys/thermal/thermal_zone0/mode" "med" "flag" "test"
km_caps_scan   # merge the new plugin control into the registry
r=$(km_ctl_set plugin.test_thermal 0 test)
check "protected path refused" "$(printf '%s' "$r" | grep -q '"protected":1' && echo 0 || echo 1)"
check_eq "thermal mode still enabled" "enabled" "$(read_node "$T/sys/thermal/thermal_zone0/mode")"
check "protected attempt logged" "$(awk -F '\t' '$8=="protected" {f=1} END{exit !f}' "$KM_CHANGE_LOG" && echo 0 || echo 1)"

echo "== history =="
h=$(km_history 10)
check "history non-empty" "$([ -n "$h" ] && echo 0 || echo 1)"
check "history has new value" "$(printf '%s' "$h" | grep -q performance && echo 0 || echo 1)"

echo "== rollback =="
km_ctl_set cpu1.max_freq 1500000 cli >/dev/null
r=$(km_rollback 1)
check_json "rollback json" "$r"
check "rollback restored max_freq" "$(grep -q '^1804800$' "$T/sys/cpu/cpufreq/pol0/scaling_max_freq" && echo 0 || echo 1)"
check "rollback logged as restored" "$(awk -F '\t' '$8=="restored" {f=1} END{exit !f}' "$KM_CHANGE_LOG" && echo 0 || echo 1)"

echo "== transactions =="
# valid transaction
r=$( { km_txn_begin test; km_txn_apply "cpu1.governor=powersave|vm.swappiness=70" test; } 2>&1 )
check "txn commit reported" "$(printf '%s' "$r" | grep -q '"committed":1' && echo 0 || echo 1)"
check "txn applied governor" "$(grep -q '^powersave$' "$T/sys/cpu/cpufreq/pol0/scaling_governor" && echo 0 || echo 1)"

# invalid transaction: nothing applied
km_ctl_set cpu1.governor schedutil test >/dev/null
r=$( { km_txn_begin test; km_txn_apply "cpu1.governor=performance|cpu1.max_freq=99999999" test; } 2>&1 )
check "invalid txn rejected" "$(printf '%s' "$r" | grep -q 'validation failed' && echo 0 || echo 1)"
check "invalid txn applied nothing" "$(grep -q '^schedutil$' "$T/sys/cpu/cpufreq/pol0/scaling_governor" && echo 0 || echo 1)"

# partial failure -> automatic rollback (the one policy in scope is
# made read-only so the write fails and the group must roll back)
chmod 0444 "$T/sys/cpu/cpufreq/pol0/scaling_governor"
km_ctl_set cpu1.governor schedutil test >/dev/null
r=$( { km_txn_begin test; km_txn_apply "cpu1.governor=powersave" test; } 2>&1 )
check "partial failure detected" "$(printf '%s' "$r" | grep -q '"rolled_back":1' && echo 0 || echo 1)"
check "rolled back applied part" "$(grep -q '^schedutil$' "$T/sys/cpu/cpufreq/pol0/scaling_governor" && echo 0 || echo 1)"
check "restore outcome reported" "$(printf '%s' "$r" | grep -qE '"restore_failed":[0-9]' && echo 0 || echo 1)"
chmod 0644 "$T/sys/cpu/cpufreq/pol0/scaling_governor"

echo "== lock =="
mkdir "$KM_LOCK_DIR" 2>/dev/null
r=$(km_ctl_set cpu1.governor performance cli)
check "locked -> busy" "$(printf '%s' "$r" | grep -q busy && echo 0 || echo 1)"
rmdir "$KM_LOCK_DIR" 2>/dev/null

echo "== registry freshness window (HPC_REG_TTL) =="
# The WebUI CGI must NOT re-scan a registry younger than HPC_REG_TTL
# (a full scan on every 3s poll is what made the UI feel slow), and
# must re-scan one older than it. (hpc_bootstrap lives in common.sh,
# which this suite does not otherwise load.)
# shellcheck source=/dev/null
. "$HPC_SCRIPTS/common.sh"
export HPC_REG_TTL=300
_KT_REG="$HPC_STATE/caps2/registry.tsv"
touch -d "@$(( $(date +%s) - 290 ))" "$_KT_REG"
_kt_m0=$(stat -c %Y "$_KT_REG" 2>/dev/null)
hpc_bootstrap >/dev/null 2>&1
_kt_m1=$(stat -c %Y "$_KT_REG" 2>/dev/null)
check "fresh registry not rescanned" "$([ "$_kt_m0" = "$_kt_m1" ] && echo 0 || echo 1)"
touch -d "@$(( $(date +%s) - 310 ))" "$_KT_REG"
hpc_bootstrap >/dev/null 2>&1
_kt_now=$(date +%s)
_kt_m2=$(stat -c %Y "$_KT_REG" 2>/dev/null)
check "stale registry rescanned" "$([ $(( _kt_now - _kt_m2 )) -lt 30 ] && echo 0 || echo 1)"
# km_caps_json must be fork-free per row: validate output + shape
r=$(km_caps_json)
check_json "caps json valid" "$r"
check "caps json has id/name/path keys" "$(printf '%s' "$r" | grep -q '"id":"env.kernel"' && echo 0 || echo 1)"
check "caps json empty conf -> null" "$(printf '%s' "$r" | grep -q '"conf":null\|"conf":[0-9]' && echo 0 || echo 1)"

test_result "test_registry"
