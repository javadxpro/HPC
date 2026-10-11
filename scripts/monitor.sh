#!/system/bin/sh
# Hamedis Performance Core (HPC) - session monitor
#
# Records what actually happened during a gaming session so the tuning
# can be judged on data instead of feel.
#
# This is OPT-IN and TIME-LIMITED. It is never started by the service
# loop. Sampling costs a handful of small file reads every few seconds;
# the recorder stops itself after the requested duration so it can never
# be left running and quietly draining battery.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_LOG_DIR="$HPC_DATA/logs"
HPC_SESSION="$HPC_LOG_DIR/session.csv"
HPC_MON_PID="$HPC_STATE/monitor_pid"
HPC_SESSION_DIR="$HPC_LOG_DIR/sessions"

# Keep at most this many archived sessions so /data never fills up.
MON_KEEP_SESSIONS=6

# Archive the current session under a label so it survives the next run.
# Without this, starting a second recording silently destroys the first,
# which makes an A/B comparison impossible.
monitor_archive() {
    _ma_label="$1"
    [ -f "$HPC_SESSION" ] || return 1
    # Header-only file is not worth keeping.
    [ "$(grep -c ',' "$HPC_SESSION" 2>/dev/null)" -gt 1 ] || return 1

    [ -d "$HPC_SESSION_DIR" ] || mkdir -p "$HPC_SESSION_DIR" 2>/dev/null

    # Label defaults to the profile that was active during the run.
    if [ -z "$_ma_label" ]; then
        _ma_label=$(awk -F',' 'NR>1 && $11!="" {p=$11} END{print p}' \
                    "$HPC_SESSION" 2>/dev/null)
        [ -n "$_ma_label" ] || _ma_label="session"
    fi
    _ma_label=$(printf '%s' "$_ma_label" | tr -cd 'A-Za-z0-9_.-' | cut -c1-24)

    _ma_dest="$HPC_SESSION_DIR/${_ma_label}.csv"
    cp -f "$HPC_SESSION" "$_ma_dest" 2>/dev/null || return 1

    # Prune oldest beyond the cap.
    _ma_n=$(ls -1 "$HPC_SESSION_DIR"/*.csv 2>/dev/null | wc -l | tr -d ' ')
    if [ "${_ma_n:-0}" -gt "$MON_KEEP_SESSIONS" ]; then
        ls -1t "$HPC_SESSION_DIR"/*.csv 2>/dev/null | \
            tail -n +$(( MON_KEEP_SESSIONS + 1 )) | \
            while IFS= read -r _ma_old; do rm -f "$_ma_old" 2>/dev/null; done
    fi
    printf '%s' "$_ma_dest"
    return 0
}

monitor_list() {
    [ -d "$HPC_SESSION_DIR" ] || return 1
    _ml_any=0
    for _ml_f in "$HPC_SESSION_DIR"/*.csv; do
        [ -f "$_ml_f" ] || continue
        _ml_any=1
        _ml_n=$(( $(grep -c ',' "$_ml_f" 2>/dev/null) - 1 ))
        printf '  %-24s %s samples\n' "$(basename "$_ml_f" .csv)" "$_ml_n"
    done
    [ "$_ml_any" -eq 1 ] || return 1
    return 0
}

# Safety caps so a forgotten monitor cannot fill storage.
MON_MAX_SAMPLES=4000
MON_DEFAULT_INTERVAL=5
MON_DEFAULT_MINUTES=20

# ----------------------------------------------------------------------
# sampling
# ----------------------------------------------------------------------

# Current frequency of the first policy, in MHz.
_mon_cpu_cur_mhz() {
    for _mc in $(detect_policies); do
        _f=$(read_node "$_mc/scaling_cur_freq" 2>/dev/null)
        [ -n "$_f" ] || _f=$(read_node "$_mc/cpuinfo_cur_freq" 2>/dev/null)
        case "$_f" in
            ''|*[!0-9]*) continue ;;
        esac
        printf '%s' $(( _f / 1000 ))
        return 0
    done
    printf ''
}

# Ceiling of the first policy, in MHz.
_mon_cpu_max_mhz() {
    for _mm in $(detect_policies); do
        _f=$(read_node "$_mm/scaling_max_freq" 2>/dev/null)
        case "$_f" in
            ''|*[!0-9]*) continue ;;
        esac
        printf '%s' $(( _f / 1000 ))
        return 0
    done
    printf ''
}

monitor_sample() {
    _s_t=$(thermal_read 2>/dev/null)
    _s_state=$(thermal_get_state 2>/dev/null)
    _s_step=$(thermal_get_step 2>/dev/null)
    _s_cmax=$(_mon_cpu_max_mhz)
    _s_ccur=$(_mon_cpu_cur_mhz)
    _s_gb=$(gfx_gpu_busy 2>/dev/null)
    _s_gc=$(gfx_gpu_clock_mhz 2>/dev/null)
    _s_bat=$(battery_capacity 2>/dev/null)
    _s_bt=$(battery_temp_c 2>/dev/null)
    _s_prof=$(current_profile 2>/dev/null)
    _s_game=$(game_current_pkg 2>/dev/null)

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%H:%M:%S' 2>/dev/null)" \
        "${_s_t:-}" "${_s_state:-}" "${_s_step:-0}" \
        "${_s_cmax:-}" "${_s_ccur:-}" \
        "${_s_gb:-}" "${_s_gc:-}" \
        "${_s_bat:-}" "${_s_bt:-}" \
        "${_s_prof:-}" "${_s_game:-}"
}

# ----------------------------------------------------------------------
# recorder
# ----------------------------------------------------------------------

monitor_running() {
    [ -f "$HPC_MON_PID" ] || return 1
    _mp=$(read_node "$HPC_MON_PID" 2>/dev/null)
    case "$_mp" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_mp" ]
}

monitor_stop() {
    if [ -f "$HPC_MON_PID" ]; then
        _mp=$(read_node "$HPC_MON_PID" 2>/dev/null)
        case "$_mp" in
            ''|*[!0-9]*) ;;
            *) kill "$_mp" 2>/dev/null ;;
        esac
        rm -f "$HPC_MON_PID" 2>/dev/null
    fi
    return 0
}

# monitor_loop MINUTES INTERVAL  - runs in background
monitor_loop() {
    _ml_min="$1"
    _ml_int="$2"
    _ml_max=$(( _ml_min * 60 / _ml_int ))
    [ "$_ml_max" -gt "$MON_MAX_SAMPLES" ] && _ml_max="$MON_MAX_SAMPLES"

    _ml_n=0
    while [ "$_ml_n" -lt "$_ml_max" ]; do
        monitor_sample >>"$HPC_SESSION" 2>/dev/null
        _ml_n=$(( _ml_n + 1 ))
        sleep "$_ml_int"
    done

    rm -f "$HPC_MON_PID" 2>/dev/null
    log_info "monitor: session finished, $_ml_n samples"
    return 0
}

# ----------------------------------------------------------------------
# report
# ----------------------------------------------------------------------

monitor_report() {
    # Optional argument: report on an archived session instead of the
    # live one.
    if [ -n "$1" ]; then
        if [ -f "$HPC_SESSION_DIR/$1.csv" ]; then
            HPC_SESSION="$HPC_SESSION_DIR/$1.csv"
        elif [ -f "$1" ]; then
            HPC_SESSION="$1"
        else
            printf '  No session named "%s".\n' "$1"
            printf '  Available:\n'
            monitor_list || printf '    (none)\n'
            return 1
        fi
    fi

    if [ ! -f "$HPC_SESSION" ]; then
        printf '  No session recorded yet.\n'
        printf '  Start one with:  hpc.sh monitor 20\n'
        return 1
    fi

    _rows=$(grep -c ',' "$HPC_SESSION" 2>/dev/null)
    case "$_rows" in ''|*[!0-9]*) _rows=0 ;; esac
    if [ "$_rows" -lt 2 ]; then
        printf '  Session too short to summarise (%s samples).\n' "$_rows"
        return 1
    fi

    awk -F',' '
    BEGIN {
        tmin = 999; tmax = -999; tsum = 0; tn = 0
        fmin = 999999; fmax = 0; fsum = 0; fn = 0
        gmax = 0; gsum = 0; gn = 0
        cmin = 999999; cmax2 = 0
        b_first = ""; b_last = ""
        prev_state = ""; transitions = 0
        maxstep = 0
    }
    # Skip the header row and any malformed line. Without this the
    # literal header text is parsed as a sample, which drags every
    # minimum to 0 and makes the first battery reading a string.
    NR == 1 && $1 == "time" { next }
    $1 == "time" { next }

    {
        # temperature
        if ($2 ~ /^-?[0-9]+$/) {
            t = $2 + 0
            if (t < tmin) tmin = t
            if (t > tmax) tmax = t
            tsum += t; tn++
        }
        # thermal state occupancy
        if ($3 ~ /^[A-Z]+$/) {
            state[$3]++
            if (prev_state != "" && $3 != prev_state) transitions++
            prev_state = $3
        }
        # worst throttle step reached
        if ($4 ~ /^[0-9]+$/ && ($4 + 0) > maxstep) maxstep = $4 + 0
        # cpu ceiling
        if ($5 ~ /^[0-9]+$/) {
            f = $5 + 0
            if (f < fmin) fmin = f
            if (f > fmax) fmax = f
            fsum += f; fn++
            ceil[$5]++
        }
        # cpu current freq
        if ($6 ~ /^[0-9]+$/) {
            c = $6 + 0
            if (c < cmin) cmin = c
            if (c > cmax2) cmax2 = c
        }
        # gpu busy
        if ($7 ~ /^[0-9]+$/) {
            g = $7 + 0
            if (g > gmax) gmax = g
            gsum += g; gn++
        }
        # battery
        if ($9 ~ /^[0-9]+$/) {
            if (b_first == "") b_first = $9
            b_last = $9
        }
        if ($10 ~ /^-?[0-9]+$/) bt_last = $10
        if ($11 != "") prof = $11
        if ($12 != "") game = $12
        total++
    }
    END {
        printf "  Samples      : %d\n", total
        if (game != "") printf "  Game         : %s\n", game
        if (prof != "") printf "  Profile      : %s\n", toupper(prof)
        printf "\n"

        if (tn > 0) {
            printf "  SoC temp     : min %d°C   avg %d°C   max %d°C\n", tmin, tsum/tn, tmax
        } else {
            printf "  SoC temp     : not readable\n"
        }

        printf "  Thermal      : "
        n = 0
        for (s in state) {
            if (n++) printf ", "
            printf "%s %d%%", s, (state[s] * 100 / total)
        }
        printf "\n"
        printf "  Worst step   : %d/3", maxstep
        if (maxstep == 0) printf "   (HPC never throttled)"
        printf "\n"
        printf "  State changes: %d\n", transitions
        printf "\n"

        if (fn > 0 && fmin <= fmax) {
            printf "  CPU ceiling  : min %d MHz   avg %d MHz   max %d MHz\n", fmin, fsum/fn, fmax
            if (fmin == fmax)
                printf "                 held steady the whole session\n"
            else
                printf "                 varied by %d MHz\n", fmax - fmin
        }
        if (cmax2 > 0)
            printf "  CPU actual   : %d - %d MHz\n", cmin, cmax2

        if (gn > 0)
            printf "  GPU load     : avg %d%%   peak %d%%\n", gsum/gn, gmax
        printf "\n"

        if (b_first != "" && b_last != "") {
            drop = b_first - b_last
            printf "  Battery      : %s%% -> %s%%  (used %d%%)\n", b_first, b_last, drop
        }
        if (bt_last != "") printf "  Battery temp : %s°C\n", bt_last
        printf "\n"

        # --- interpretation -------------------------------------------
        printf "  VERDICT\n"
        printf "  -------\n"
        if (maxstep == 0) {
            printf "  HPC never reduced performance. Thermal headroom to spare.\n"
            if (tn > 0 && tmax < 60)
                printf "  Peak %d°C is low - you could raise CPU_MIN_PERCENT for\n  even steadier frame pacing.\n", tmax
        } else if (maxstep == 1) {
            printf "  Light throttling only (step 1). This is healthy behaviour.\n"
        } else if (maxstep >= 2) {
            printf "  Throttled to step %d. If the phone did NOT feel hot,\n", maxstep
            printf "  raise TEMP_WARM/TEMP_HOT in the active profile.\n"
        }
        if (transitions > 8)
            printf "  %d state changes - thresholds may be too close together.\n", transitions
        if (gn > 0 && gsum/gn < 40)
            printf "  GPU avg %d%% - you are CPU-bound, not GPU-bound.\n", gsum/gn
        if (gn > 0 && gsum/gn > 85)
            printf "  GPU avg %d%% - GPU-bound. Lower in-game resolution\n  before touching CPU settings.\n", gsum/gn
    }' "$HPC_SESSION"

    printf '\n  Raw data: %s\n' "$HPC_SESSION"
    return 0
}

# ----------------------------------------------------------------------
# Side-by-side comparison of two recorded sessions.
#
# The point of this is to answer one question honestly: did the change
# actually help, or did it just feel different? Peak frequency is not the
# metric that matters - STABILITY is. A session that holds a slightly
# lower clock without throttling will feel smoother than one that spikes
# high and then collapses.
# ----------------------------------------------------------------------
monitor_compare() {
    _mc_a="$1"
    _mc_b="$2"

    _mc_fa="$HPC_SESSION_DIR/$_mc_a.csv"
    _mc_fb="$HPC_SESSION_DIR/$_mc_b.csv"
    [ -f "$_mc_fa" ] || { printf '  No session "%s"\n' "$_mc_a"; return 1; }
    [ -f "$_mc_fb" ] || { printf '  No session "%s"\n' "$_mc_b"; return 1; }

    printf '\n  Session comparison\n'
    printf '  ─────────────────────────────────────────\n\n'

    awk -F',' -v NA="$_mc_a" -v NB="$_mc_b" '
    function reset() {
        tmin=999; tmax=-999; tsum=0; tn=0
        fsum=0; fn=0; fmin=999999; fmax=0
        gsum=0; gn=0; gmax=0
        maxstep=0; trans=0; prev=""
        bfirst=""; blast=""
        n=0
    }
    function absorb(   t,f,g) {
        if ($2 ~ /^-?[0-9]+$/) { t=$2+0
            if(t<tmin)tmin=t; if(t>tmax)tmax=t; tsum+=t; tn++ }
        if ($3 ~ /^[A-Z]+$/) {
            if(prev!="" && $3!=prev) trans++
            prev=$3 }
        if ($4 ~ /^[0-9]+$/ && $4+0>maxstep) maxstep=$4+0
        if ($5 ~ /^[0-9]+$/) { f=$5+0
            if(f<fmin)fmin=f; if(f>fmax)fmax=f; fsum+=f; fn++ }
        if ($7 ~ /^[0-9]+$/) { g=$7+0
            if(g>gmax)gmax=g; gsum+=g; gn++ }
        if ($9 ~ /^[0-9]+$/) { if(bfirst=="")bfirst=$9; blast=$9 }
        n++
    }
    function store(i) {
        S[i,"n"]=n
        S[i,"tmin"]=(tn?tmin:0); S[i,"tmax"]=(tn?tmax:0)
        S[i,"tavg"]=(tn?tsum/tn:0)
        S[i,"fmin"]=(fn?fmin:0); S[i,"fmax"]=(fn?fmax:0)
        S[i,"favg"]=(fn?fsum/fn:0)
        # Stability: how much the ceiling moved as a share of its peak.
        S[i,"fspread"]=(fn && fmax>0 ? (fmax-fmin)*100/fmax : 0)
        S[i,"gavg"]=(gn?gsum/gn:0); S[i,"gmax"]=(gn?gmax:0)
        S[i,"step"]=maxstep; S[i,"trans"]=trans
        S[i,"batt"]=((bfirst!=""&&blast!="")?bfirst-blast:0)
    }
    BEGIN { reset() }
    FNR==1 { if(FILENAME==ARGV[2] && NR>1){ store(1); reset() } next }
    $1=="time" { next }
    { absorb() }
    END {
        store(2)
        printf "  %-16s %14s %14s\n", "", substr(NA,1,14), substr(NB,1,14)
        printf "  %-16s %14s %14s\n", "────────────────", "──────────────", "──────────────"
        printf "  %-16s %14d %14d\n", "samples", S[1,"n"], S[2,"n"]
        printf "  %-16s %11.0f °C %11.0f °C\n", "temp avg", S[1,"tavg"], S[2,"tavg"]
        printf "  %-16s %11d °C %11d °C\n", "temp peak", S[1,"tmax"], S[2,"tmax"]
        printf "  %-16s %10.0f MHz %10.0f MHz\n", "ceiling avg", S[1,"favg"], S[2,"favg"]
        printf "  %-16s %13.0f%% %13.0f%%\n", "ceiling spread", S[1,"fspread"], S[2,"fspread"]
        printf "  %-16s %12d/3 %12d/3\n", "worst throttle", S[1,"step"], S[2,"step"]
        printf "  %-16s %14d %14d\n", "state changes", S[1,"trans"], S[2,"trans"]
        printf "  %-16s %13.0f%% %13.0f%%\n", "gpu avg", S[1,"gavg"], S[2,"gavg"]
        printf "  %-16s %13d%% %13d%%\n", "battery used", S[1,"batt"], S[2,"batt"]
        printf "\n  VERDICT\n  -------\n"

        # Stability is the headline number, not peak clock.
        if (S[1,"fspread"] < S[2,"fspread"] - 3)
            printf "  %s held a steadier clock (%.0f%% vs %.0f%% spread).\n", NA, S[1,"fspread"], S[2,"fspread"]
        else if (S[2,"fspread"] < S[1,"fspread"] - 3)
            printf "  %s held a steadier clock (%.0f%% vs %.0f%% spread).\n", NB, S[2,"fspread"], S[1,"fspread"]
        else
            printf "  Both held a similarly steady clock.\n"

        if (S[1,"step"] != S[2,"step"]) {
            if (S[1,"step"] < S[2,"step"])
                printf "  %s throttled less (step %d vs %d).\n", NA, S[1,"step"], S[2,"step"]
            else
                printf "  %s throttled less (step %d vs %d).\n", NB, S[2,"step"], S[1,"step"]
        }

        d = S[1,"tmax"] - S[2,"tmax"]
        if (d >= 4)      printf "  %s ran %d°C cooler at peak.\n", NB, d
        else if (d <= -4) printf "  %s ran %d°C cooler at peak.\n", NA, -d

        if (S[1,"gavg"] > 85 || S[2,"gavg"] > 85)
            printf "  GPU is the bottleneck (avg >85%%). Lower in-game\n  resolution before changing CPU settings.\n"
        else if (S[1,"gavg"] > 0 && S[1,"gavg"] < 55 && S[2,"gavg"] < 55)
            printf "  GPU has headroom (<55%%). A higher frame target may\n  be sustainable.\n"

        if (S[1,"batt"] > 0 && S[2,"batt"] > 0) {
            bd = S[1,"batt"] - S[2,"batt"]
            if (bd >= 3)       printf "  %s used %d%% less battery.\n", NB, bd
            else if (bd <= -3) printf "  %s used %d%% less battery.\n", NA, -bd
        }
        printf "\n  Note: steadier beats faster. An even 90 fps feels\n  smoother than an erratic 110 with frame drops.\n\n"
    }' "$_mc_fa" "$_mc_fb"
    return 0
}
