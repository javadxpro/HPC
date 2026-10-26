#!/bin/sh
# Discovery engine tests: full fake tree, missing interfaces, read-only
. "$(dirname "$0")/lib.sh"

source_hpc
fake_tree
point_at_fake

echo "== discovery: full tree =="
km_caps_scan
check "registry file created" $([ -s "$KM_REG_TSV" ] && echo 0 || echo 1)
check "summary json created" $([ -s "$KM_SUM_JSON" ] && echo 0 || echo 1)

check_eq "cpu governor discovered" "rw" \
    "$(awk -F '\t' '$1=="cpu1.governor" {print $5}' "$KM_REG_TSV")"
check "governor enum in detail" \
    "$(awk -F '\t' '$1=="cpu1.governor" {print (($10 ~ /schedutil/) ? 0 : 1); f=1} END{if(!f) print 1}' "$KM_REG_TSV")"
check_eq "governor current value" "schedutil" \
    "$(awk -F '\t' '$1=="cpu1.governor" {print $9}' "$KM_REG_TSV")"
check_eq "max freq hw max recorded" "2841600" \
    "$(awk -F '\t' '$1=="cpu2.max_freq" {print $9}' "$KM_REG_TSV")"
check_eq "io scheduler discovered" "rw" \
    "$(awk -F '\t' '$1=="io.mmcblk0.scheduler" {print $5}' "$KM_REG_TSV")"
check_eq "gpu path discovered" "r" \
    "$(awk -F '\t' '$1=="gpu.path" {print $5}' "$KM_REG_TSV")"
check "gpu governor enum from kernel" \
    "$(awk -F '\t' '$1=="gpu.governor" {print (($10 ~ /msm-adreno-tz/) ? 0 : 1); f=1} END{if(!f) print 1}' "$KM_REG_TSV")"
check_eq "zram discovered" "r" \
    "$(awk -F '\t' '$1=="zram.path" {print $5}' "$KM_REG_TSV")"
check_eq "battery discovered" "r" \
    "$(awk -F '\t' '$1=="battery.battery" {print $5}' "$KM_REG_TSV")"
check "thermal sensor with temp" \
    "$(awk -F '\t' '$1 ~ /^thermal\./ && $9 ~ /45/ {found=1} END{exit !found}' "$KM_REG_TSV" && echo 0 || echo 1)"

echo "== discovery: read-only / protected =="
# thermal zone mode is read-only -> capability recorded but never rw
check_eq "thermal mode not offered writable" "r" \
    "$(awk -F '\t' '$1 ~ /^thermal\./ {print $5; exit}' "$KM_REG_TSV")"

echo "== discovery: missing GPU =="
rm -rf "$T/sys/kgsl"
detect_gpu_path() { return 1; }
detect_gpu_vendor() { :; }
detect_gpu_caps() { :; }
km_caps_scan
check "gpu.path marked unavailable when no interface" \
    "$(awk -F '\t' '$1=="gpu.path" {print (($5=="-" && $9=="") ? 0 : 1); f=1} END{if(!f) print 1}' "$KM_REG_TSV")"
check "no gpu governor capability without interface" \
    "$(awk -F '\t' '$1=="gpu.governor" {found=1} END{exit found ? 1 : 0}' "$KM_REG_TSV" && echo 0 || echo 1)"

echo "== discovery: change detection (cap_lost) =="
# restore GPU, scan, then remove a block device and scan again
mkdir -p "$T/sys/kgsl/kgsl-3d0/devfreq"
detect_gpu_path() { printf '%s' "$T/sys/kgsl/kgsl-3d0"; }
detect_gpu_vendor() { printf 'adreno'; }
detect_gpu_caps() { printf ' governor busy_pct gpuclk'; }
km_caps_scan
km_block_devices() { :; }   # device disappeared
rm -f "$KM_EVENTS"
km_caps_scan
check "cap_lost event recorded for io device" \
    "$(grep -q 'cap_lost' "$KM_EVENTS" 2>/dev/null && echo 0 || echo 1)"

test_result "test_discover"
