#!/bin/sh
# Assistant + event timeline tests
. "$(dirname "$0")/lib.sh"

source_hpc
fake_tree
point_at_fake
km_caps_scan

echo "== events: append + filter =="
rm -f "$KM_EVENTS"
km_event boot "test boot"
km_event thermal_high "CPU at 50C"
km_event profile_change "balanced -> performance"
e=$(km_events 10)
check_json "events json" "$e"
check "events newest first" "$(printf '%s' "$e" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ts=[x["ts"] for x in d["events"]]
print(0 if ts == sorted(ts, reverse=True) else 1)')"
check "events count" "$(printf '%s' "$e" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(0 if len(d["events"])==3 else 1)')"
e2=$(km_events 10 thermal_high)
check "events filter by type" "$(printf '%s' "$e2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ev=d["events"]
print(0 if len(ev)==1 and ev[0]["type"]=="thermal_high" else 1)')"

echo "== events: ring trim =="
rm -f "$KM_EVENTS"
KM_EVENTS_MAX=10
export KM_EVENTS_MAX
i=0
while [ $i -lt 15 ]; do km_event fill "item $i"; i=$((i+1)); done
n=$(wc -l <"$KM_EVENTS" | tr -d ' ')
check "ring trimmed to max" "$([ "$n" -le 10 ] && echo 0 || echo 1)"
check "ring keeps newest" "$(grep -q 'item 14' "$KM_EVENTS" && echo 0 || echo 1)"
check "ring drops oldest" "$(! grep -q 'item 0' "$KM_EVENTS" && echo 0 || echo 1)"
KM_EVENTS_MAX=500

echo "== advise: honest output =="
a=$(km_advise)
check_json "advise json" "$a"
check "advise states engine" "$(printf '%s' "$a" | grep -q '"engine":"local-rules"' && echo 0 || echo 1)"
check "advise ai backend off" "$(printf '%s' "$a" | grep -q '"ai_backend":"off"' && echo 0 || echo 1)"
# every suggestion must carry a valid flag - no implicit promises
check "all suggestions flagged valid" "$(printf '%s' "$a" | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=0
for f in d["findings"]:
    for sg in f.get("suggestions",[]):
        if "valid" not in sg:
            bad=1
print(bad)')"
# facts must cite their source
check "all facts have sources" "$(printf '%s' "$a" | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=0
for f in d["facts"]:
    if not f.get("source"):
        bad=1
print(bad)')"
# the klog error rule must fire (fake dmesg has error-pattern lines)
check "klog error rule fired" "$(printf '%s' "$a" | grep -q '"id":"r3_klog"' && echo 0 || echo 1)"
# the klog restriction rule must NOT fire (dmesg readable in fake)
check "klog restriction rule absent" "$(! printf '%s' "$a" | grep -q '"id":"r6_klog"' && echo 0 || echo 1)"

echo "== advise: explain =="
x=$(km_advise_explain cpu1.governor)
check_json "explain json" "$x"
check "explain carries current value" "$(printf '%s' "$x" | grep -q '"current":"schedutil"' && echo 0 || echo 1)"
check "explain lists kernel governors" "$(printf '%s' "$x" | grep -q 'schedutil' && echo 0 || echo 1)"

echo "== advise: validation is device-driven =="
r=$(km_ctl_validate cpu1.governor interactive)
check "interactive rejected on fake kernel" "$([ -n "$r" ] && echo 0 || echo 1)"
check "rejection reason is the kernel list" "$(printf '%s' "$r" | grep -q 'not in kernel list' && echo 0 || echo 1)"

test_result "test_advise_events"
