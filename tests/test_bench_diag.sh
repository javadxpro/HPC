#!/bin/sh
# Benchmark + diagnostics + health + redaction tests
. "$(dirname "$0")/lib.sh"

source_hpc
fake_tree
point_at_fake
km_caps_scan
export KM_BENCH_SCRATCH="$T/scratch"
mkdir -p "$T/scratch"

echo "== bench: cpu (short) =="
r=$(km_bench_run cpu 600)
check_json "cpu bench json" "$r"
check "cpu bench ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "cpu bench has numeric result" "$(printf '%s' "$r" | grep -qE '"result":[0-9]+' && echo 0 || echo 1)"
check "cpu bench recorded temp" "$(printf '%s' "$r" | grep -q '"temp_before_c":45' && echo 0 || echo 1)"
check "bench event emitted" "$(grep -q 'bench' "$KM_EVENTS" && echo 0 || echo 1)"

echo "== bench: io =="
r=$(km_bench_run io)
check_json "io bench json" "$r"
check "io bench ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"
check "io bench write/read pair" "$(printf '%s' "$r" | grep -qE '"result":"[0-9]+/[0-9]+"' && echo 0 || echo 1)"
check_eq "io scratch cleaned count" "0" "$(ls "$T/scratch" | wc -l | tr -d ' ')"

echo "== bench: mem =="
r=$(km_bench_run mem)
check "mem bench ok" "$(printf '%s' "$r" | grep -q '"ok":1' && echo 0 || echo 1)"

echo "== bench: list / unknown =="
l=$(km_bench_list 5)
check_json "bench list json" "$l"
check "bench list non-empty" "$(printf '%s' "$l" | grep -q '"name":"cpu"' && echo 0 || echo 1)"
r=$(km_bench_run bogus)
check "unknown bench rejected" "$(printf '%s' "$r" | grep -q 'unknown benchmark' && echo 0 || echo 1)"

echo "== health =="
h=$(km_health)
check_json "health json" "$h"
check "health score bounded" "$(printf '%s' "$h" | grep -qE '"score":(0|[1-9][0-9]?|100)' && echo 0 || echo 1)"
check "health components present" "$(printf '%s' "$h" | grep -q 'failed_changes_10m' && echo 0 || echo 1)"
check "health documents formula" "$(printf '%s' "$h" | grep -q 'formula' && echo 0 || echo 1)"

echo "== redaction =="
cat >"$T/secret_report.txt" <<EOF
boot id: 12345678-abcd-1234-abcd-123456789abc
ip 192.168.1.50 connected
serial FAKESERIAL123 detected
mac 00:11:22:33:44:55 seen
EOF
red=$(km_redact "$T/secret_report.txt")
check "redact: ip removed" "$(! printf '%s' "$red" | grep -q '192.168.1.50' && echo 0 || echo 1)"
check "redact: ip placeholder" "$(printf '%s' "$red" | grep -q 'REDACTED-IP' && echo 0 || echo 1)"
check "redact: serial removed" "$(! printf '%s' "$red" | grep -q 'FAKESERIAL123' && echo 0 || echo 1)"
check "redact: mac removed" "$(! printf '%s' "$red" | grep -q '00:11:22' && echo 0 || echo 1)"
check "redact: boot_id removed" "$(! printf '%s' "$red" | grep -q '12345678-abcd' && echo 0 || echo 1)"

echo "== report =="
r=$(km_diag_report)
check_json "report json" "$r"
check "report file created" "$([ -f "$(printf '%s' "$r" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')" ] && echo 0 || echo 1)"
check "redacted export created" "$([ -f "$(printf '%s' "$r" | sed -n 's/.*"export":"\([^"]*\)".*/\1/p')" ] && echo 0 || echo 1)"
check "report has capability section" "$(grep -q 'capability summary' "$(printf '%s' "$r" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')" && echo 0 || echo 1)"

test_result "test_bench_diag"
