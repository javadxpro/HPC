#!/system/bin/sh
# Hamedis Performance Core (HPC) - benchmarking & A/B comparison
#
# Part of the Kernel Management Platform (v1.10).
#
# Synthetic micro-benchmarks that run entirely in userspace with bounded
# time and scratch usage. They are clearly SYNTHETIC numbers - useful
# for comparing configuration A vs B on the SAME device under similar
# conditions, not for absolute performance claims.
#
# Workloads:
#   cpu  - single-core arithmetic loop for a fixed duration
#   cpux - N parallel loops (all online cores)
#   io   - write + read a scratch file on /data (size bounded)
#   mem  - kernel memcpy of /dev/zero (bounded)
#
# Every run records: configuration snapshot, temperature before/after,
# duration, result, errors. Results persist in state/bench/.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
KM_BENCH_DIR="$HPC_STATE/bench"
KM_BENCH_SCRATCH="/data/local/tmp/hpc_bench"
KM_BENCH_IO_MB=32
KM_BENCH_MEM_MB=128

km_bench_init() {
    [ -d "$KM_BENCH_DIR" ] || mkdir -p "$KM_BENCH_DIR" 2>/dev/null
    [ -d "$KM_BENCH_SCRATCH" ] || mkdir -p "$KM_BENCH_SCRATCH" 2>/dev/null
}

# config snapshot for attribution
_km_bench_cfg() {
    _bc_gov=""
    for _bc_p in $(detect_policies 2>/dev/null); do
        _bc_g="read_node "  # placeholder
        _bc_g=$(read_node "$_bc_p/scaling_governor" 2>/dev/null)
        [ -n "$_bc_g" ] && _bc_gov="$_bc_gov $_bc_g"
        break
    done
    printf 'profile=%s|governor=%s|io=%s' \
        "$(current_profile 2>/dev/null)" \
        "$(printf '%s' "${_bc_gov# }" | tr ' ' ',')" \
        "$(km_io_current 2>/dev/null)"
}

# single-core arithmetic loop for DUR_MS milliseconds; prints iterations
_km_bench_cpu_loop() {
    _bl_dur="$1"
    _bl_end=$(( $(km_now_ms) + _bl_dur ))
    _bl_c=0
    _bl_s=7
    while :; do
        _bl_c=$((_bl_c + 1))
        _bl_s=$((_bl_s + _bl_c))
        _bl_s=$((_bl_s ^ _bl_c))
        [ "$(km_now_ms)" -ge "$_bl_end" ] && break
    done
    printf '%s' "$_bl_c"
}

# km_bench_run NAME [DUR_MS] -> prints JSON result (and stores it)
km_bench_run() {
    _bn_name="$1"
    _bn_dur="${2:-3000}"
    km_bench_init
    case "$_bn_name" in
        cpu|cpux|io|mem) ;;
        *) printf '{"ok":0,"error":"unknown benchmark"}\n'; return 1 ;;
    esac

    _bn_ts=$(km_now_ms)
    _bn_temp_before=$(read_temp_c "$(detect_cpu_thermal_zone 2>/dev/null)" 2>/dev/null)
    _bn_result=""
    _bn_unit=""
    _bn_err=""

    case "$_bn_name" in
        cpu)
            _bn_it=$(_km_bench_cpu_loop "$_bn_dur")
            _bn_elapsed=$(( $(km_now_ms) - _bn_ts ))
            [ "$_bn_elapsed" -gt 0 ] && _bn_result=$(( _bn_it * 1000 / _bn_elapsed ))
            _bn_unit="iters/s"
            ;;
        cpux)
            _bn_cores=$(cpu_online_state 2>/dev/null | awk -F/ '{print $1}')
            _bn_cores=${_bn_cores:-1}
            [ "$_bn_cores" -gt 8 ] && _bn_cores=8
            [ "$_bn_cores" -lt 1 ] && _bn_cores=1
            _bn_out="$KM_BENCH_DIR/cpux_out"
            : >"$_bn_out" 2>/dev/null
            _i=0
            while [ "$_i" -lt "$_bn_cores" ]; do
                _km_bench_cpu_loop "$_bn_dur" >>"$_bn_out" 2>/dev/null &
                _i=$((_i + 1))
            done
            wait 2>/dev/null
            _bn_it=$(awk '{s+=$1} END{print s+0}' "$_bn_out" 2>/dev/null)
            rm -f "$_bn_out" 2>/dev/null
            _bn_elapsed=$(( $(km_now_ms) - _bn_ts ))
            [ "$_bn_elapsed" -gt 0 ] && _bn_result=$(( _bn_it * 1000 / _bn_elapsed ))
            _bn_unit="iters/s (all cores)"
            ;;
        io)
            _bn_f="$KM_BENCH_SCRATCH/io_$$_tmp.bin"
            _bn_free=$(df -k "$KM_BENCH_SCRATCH" 2>/dev/null | awk 'NR==2 {print $4}')
            if [ -n "$_bn_free" ] && [ "$_bn_free" -lt $(( KM_BENCH_IO_MB * 1024 + 10240 )) ] 2>/dev/null; then
                _bn_err="not enough scratch space"
            else
                _bn_t0=$(km_now_ms)
                if dd if=/dev/zero of="$_bn_f" bs=1M count="$KM_BENCH_IO_MB" 2>/dev/null; then
                    _bn_tw=$(( $(km_now_ms) - _bn_t0 ))
                    [ "$_bn_tw" -gt 0 ] && _bn_io_w=$(( KM_BENCH_IO_MB * 1000 / _bn_tw ))
                else
                    _bn_err="write failed"
                fi
                _bn_t1=$(km_now_ms)
                if dd if="$_bn_f" of=/dev/null bs=1M 2>/dev/null; then
                    _bn_tr=$(( $(km_now_ms) - _bn_t1 ))
                    [ "$_bn_tr" -gt 0 ] && _bn_io_r=$(( KM_BENCH_IO_MB * 1000 / _bn_tr ))
                fi
                rm -f "$_bn_f" 2>/dev/null
                [ -n "$_bn_io_w" ] && [ -n "$_bn_io_r" ] && _bn_result="${_bn_io_w}/${_bn_io_r}"
                _bn_unit="MB/s (write/read, ${KM_BENCH_IO_MB}MB)"
            fi
            ;;
        mem)
            _bn_t0=$(km_now_ms)
            if dd if=/dev/zero of=/dev/null bs=1M count="$KM_BENCH_MEM_MB" 2>/dev/null; then
                _bn_tm=$(( $(km_now_ms) - _bn_t0 ))
                [ "$_bn_tm" -gt 0 ] && _bn_result=$(( KM_BENCH_MEM_MB * 1000 / _bn_tm ))
            else
                _bn_err="mem copy failed"
            fi
            _bn_unit="MB/s (kernel memcpy, ${KM_BENCH_MEM_MB}MB)"
            ;;
    esac

    _bn_temp_after=$(read_temp_c "$(detect_cpu_thermal_zone 2>/dev/null)" 2>/dev/null)
    _bn_cfg=$(_km_bench_cfg)
    _bn_elapsed=$(( $(km_now_ms) - _bn_ts ))
    [ "$_bn_elapsed" -le 0 ] && _bn_elapsed=1
    # result: plain number if integer, quoted string if composite (e.g. write/read)
    _bn_rj=$(case "${_bn_result:-}" in
        '') printf 'null' ;;
        *[!0-9]*) printf '%s' "$(km_jesc "$_bn_result")" ;;
        *) printf '%s' "$_bn_result" ;;
    esac)

    _bn_ok=1
    [ -n "$_bn_err" ] && _bn_ok=0
    _bn_json=$(printf '{"id":"%s_%s","ts":%s,"name":"%s","duration_ms":%s,"result":%s,"unit":%s,"cfg":%s,"temp_before_c":%s,"temp_after_c":%s,"error":%s,"ok":%s}' \
        "$_bn_name" "$_bn_ts" "$_bn_ts" "$_bn_name" "$_bn_elapsed" \
        "$_bn_rj" \
        "$(km_jesc "$_bn_unit")" "$(km_jesc "$_bn_cfg")" \
        "$([ -n "$_bn_temp_before" ] && printf '%s' "$_bn_temp_before" || printf 'null')" \
        "$([ -n "$_bn_temp_after" ] && printf '%s' "$_bn_temp_after" || printf 'null')" \
        "$(km_jesc "$_bn_err")" "$_bn_ok")

    printf '%s\n' "$_bn_json" >"$KM_BENCH_DIR/bench_${_bn_name}_${_bn_ts}.json" 2>/dev/null
    km_event bench "$_bn_name: $_bn_result $_bn_unit ${_bn_err:+(error)}"
    printf '%s\n' "$_bn_json"
    return 0
}

# km_bench_list [N] -> JSON array of stored results, newest first
km_bench_list() {
    _bl_n="${1:-20}"
    case "$_bl_n" in ''|*[!0-9]*) _bl_n=20 ;; esac
    km_bench_init
    _bj=""
    _bfirst=1
    _bcnt=0
    for _bf in $(ls -t "$KM_BENCH_DIR"/bench_*.json 2>/dev/null | head -n "$_bl_n"); do
        [ -f "$_bf" ] || continue
        [ "$_bfirst" = "1" ] || _bj="$_bj,"
        _bfirst=0
        _bj="$_bj$(cat "$_bf" 2>/dev/null)"
        _bcnt=$((_bcnt + 1))
    done
    printf '{"ts":%s,"runs":[%s]}\n' "$(km_now_ms)" "$_bj"
}

# km_bench_compare ID_A ID_B -> percent difference of the numeric result
km_bench_compare() {
    _bca="$KM_BENCH_DIR/bench_$1.json"
    _bcb="$KM_BENCH_DIR/bench_$2.json"
    [ -f "$_bca" ] && [ -f "$_bcb" ] || {
        printf '{"ok":0,"error":"one or both runs not found"}\n'
        return 1
    }
    _v_a=$(sed -n 's/.*"result":\([0-9.\/]*\).*/\1/p' "$_bca" 2>/dev/null | head -n1)
    _v_b=$(sed -n 's/.*"result":\([0-9.\/]*\).*/\1/p' "$_bcb" 2>/dev/null | head -n1)
    case "$_v_a$_v_b" in
        ''|*[!0-9.\/]*) printf '{"ok":0,"error":"results not numeric"}\n'; return 1 ;;
    esac
    # take the first component (e.g. write speed) for io runs
    _v_a=${_v_a%%/*}; _v_b=${_v_b%%/*}
    _diff=$(( ( _v_b - _v_a ) * 100 / _v_a ))
    printf '{"ok":1,"a":%s,"b":%s,"delta_pct":%s,"note":"synthetic; compare only same workload on same device"}\n' \
        "$_v_a" "$_v_b" "$_diff"
    return 0
}

# ----------------------------------------------------------------------
# A/B experiment: run the same benchmark under two profiles, restore
# the original profile afterwards. Uses the profile engine (safe_write
# layer) for all changes.
# ----------------------------------------------------------------------

# km_bench_ab NAME PROFILE_A PROFILE_B [DUR_MS]
km_bench_ab() {
    _bna="$1"; _bpa="$2"; _bpb="$3"; _bdur="${4:-3000}"
    case "$_bna" in cpu|cpux|io|mem) ;;
        *) printf '{"ok":0,"error":"unknown benchmark"}\n'; return 1 ;;
    esac
    if ! km_prof_name_ok "$_bpa" 2>/dev/null || [ -z "$(km_prof_file "$_bpa" 2>/dev/null)" ]; then
        printf '{"ok":0,"error":"profile A invalid"}\n'; return 1
    fi
    if ! km_prof_name_ok "$_bpb" 2>/dev/null || [ -z "$(km_prof_file "$_bpb" 2>/dev/null)" ]; then
        printf '{"ok":0,"error":"profile B invalid"}\n'; return 1
    fi

    _borig=$(current_profile 2>/dev/null)

    km_event bench "A/B start: $_bna under $_bpa vs $_bpb"
    apply_profile "$_bpa" quiet 2>/dev/null
    _ba=$(km_bench_run "$_bna" "$_bdur")
    apply_profile "$_bpb" quiet 2>/dev/null
    _bb=$(km_bench_run "$_bna" "$_bdur")
    # restore what the user had
    if [ -n "$_borig" ] && [ "$_borig" != "unknown" ]; then
        apply_profile "$_borig" quiet 2>/dev/null
    fi

    _id_a=$(printf '%s' "$_ba" | sed -n 's/.*"id":\"\([0-9_a-z]*\)\".*/\1/p')
    _id_b=$(printf '%s' "$_bb" | sed -n 's/.*"id":\"\([0-9_a-z]*\)\".*/\1/p')
    _cmp=$(km_bench_compare "$_id_a" "$_id_b" 2>/dev/null)

    printf '{"ok":1,"benchmark":"%s","profile_a":"%s","profile_b":"%s","run_a":%s,"run_b":%s,"compare":%s,"restored_profile":"%s","note":"synthetic measurement - sustained real-world performance may differ; temperatures and background load affect results"}\n' \
        "$_bna" "$_bpa" "$_bpb" "$_ba" "$_bb" "${_cmp:-null}" "$_borig"
    return 0
}
