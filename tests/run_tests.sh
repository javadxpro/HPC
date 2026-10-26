#!/bin/sh
# HPC test runner - runs every test_*.sh with a fresh fake environment.
# Usage: sh tests/run_tests.sh [verbose]
MOD="$(cd "$(dirname "$0")/.." && pwd)"
[ "${1:-}" = "verbose" ] && export HPC_TEST_VERBOSE=1

total_fail=0
ran=0
for t in "$MOD"/tests/test_*.sh; do
    [ -f "$t" ] || continue
    ran=$((ran+1))
    name="${t##*/}"
    echo "──────────────────────────────────────────"
    echo "RUN  $name"
    ( . "$t" ) 2>&1
    rc=$?
    echo ""
    if [ $rc -ne 0 ]; then
        total_fail=$((total_fail+1))
        echo "RESULT: $name FAILED"
    else
        echo "RESULT: $name passed"
    fi
done

echo "══════════════════════════════════════════════"
if [ $total_fail -eq 0 ]; then
    echo "ALL $ran TEST FILES PASSED"
    exit 0
else
    echo "$total_fail of $ran test files FAILED"
    exit 1
fi
