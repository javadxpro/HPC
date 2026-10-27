#!/system/bin/sh
# Hamedis Performance Core (HPC) - profile management operations
#
# Part of the Kernel Management Platform (v1.10).
#
# Extends the existing profile engine (profile_manager.sh) with the
# management operations the platform needs, WITHOUT changing how
# profiles are applied:
#
#   list / show / compare / duplicate / delete
#   export  - raw conf content (CGI wraps it for the WebUI)
#   import  - STRICT validation, never blindly applied
#
# Import rules (all enforced, all must pass):
#   * target name: [a-z0-9]+, max 24 chars
#   * content: KEY=VALUE lines and # comments only
#   * keys: a fixed whitelist of known profile keys
#   * values: no shell metacharacters, no $ / backticks / backslashes
#   * per-key ranges: percentages 0-100, temperatures 20-70 C,
#     POLL_INTERVAL 15-600, numeric keys non-negative
#   * written only to the user profile dir, atomically
#   * importing does NOT activate the profile
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
HPC_MODDIR="${HPC_MODDIR:-/data/adb/modules/hamedis_performance_core}"
KM_PROF_USER="$HPC_DATA/profiles"
KM_PROF_BUILTIN="$HPC_MODDIR/config/profiles"

# ----------------------------------------------------------------------
# name helpers
# ----------------------------------------------------------------------

km_prof_name_ok() {
    # lowercase, digits, underscore only - no dots or slashes possible
    case "$1" in
        ''|*[!a-z0-9_]*) return 1 ;;
    esac
    [ "${#1}" -le 24 ] || return 1
    return 0
}

# known profile keys (whitelist for import + parsing)
KM_PROF_KEYS="PROFILE_NAME PROFILE_DESC PROFILE_VERSION CPU_GOVERNOR_PREF CPU_MAX_PERCENT CPU_MIN_PERCENT CPU_UP_RATE_LIMIT_US CPU_DOWN_RATE_LIMIT_US CPU_HISPEED_LOAD GPU_PATH GPU_GOVERNOR_PREF GPU_MAX_PERCENT GPU_MIN_PERCENT GPU_IDLE_TIMER GPU_THROTTLING GPU_FORCE_CLK SCHED_MIN_GRANULARITY_NS SCHED_WAKEUP_GRANULARITY_NS SCHED_MIGRATION_COST_NS SCHED_LATENCY_NS SCHED_CHILD_RUNS_FIRST SCHED_AUTOGROUP VM_SWAPPINESS VM_VFS_CACHE_PRESSURE VM_DIRTY_RATIO VM_DIRTY_BACKGROUND_RATIO VM_DIRTY_EXPIRE_CENTISECS VM_DIRTY_WRITEBACK_CENTISECS VM_PAGE_CLUSTER VM_STAT_INTERVAL GFX_RENDERER POLL_INTERVAL TEMP_WARM TEMP_HOT TEMP_CRITICAL"

_km_prof_key_known() {
    for _k in $KM_PROF_KEYS; do
        [ "$1" = "$_k" ] && return 0
    done
    return 1
}

km_prof_file() {
    # user dir wins over builtins (shadowing)
    [ -f "$KM_PROF_USER/$1.conf" ] && { printf '%s' "$KM_PROF_USER/$1.conf"; return 0; }
    [ -f "$KM_PROF_BUILTIN/$1.conf" ] && { printf '%s' "$KM_PROF_BUILTIN/$1.conf"; return 0; }
    return 1
}

# ----------------------------------------------------------------------
# list
# ----------------------------------------------------------------------

# km_prof_list -> JSON array
km_prof_list() {
    _pl_json=""
    _pl_first=1
    _pl_cur=$(current_profile 2>/dev/null)
    _pl_avail_govs=$(detect_governors 2>/dev/null)
    for _pl_d in "$KM_PROF_USER" "$KM_PROF_BUILTIN"; do
        [ -d "$_pl_d" ] || continue
        for _pl_f in "$_pl_d"/*.conf; do
            [ -f "$_pl_f" ] || continue
            _pl_name="${_pl_f##*/}"; _pl_name="${_pl_name%.conf}"
            km_prof_name_ok "$_pl_name" || continue
            # skip duplicates (user shadowing builtin)
            [ "$_pl_d" = "$KM_PROF_BUILTIN" ] && [ -f "$KM_PROF_USER/$_pl_name.conf" ] && continue

            _pl_desc=$(grep '^PROFILE_DESC=' "$_pl_f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
            _pl_ver=$(grep '^PROFILE_VERSION=' "$_pl_f" 2>/dev/null | head -n1 | cut -d= -f2)
            _pl_mtime=$(stat -c %Y "$_pl_f" 2>/dev/null || printf '0')
            _pl_active="0"
            [ "$_pl_name" = "$_pl_cur" ] && _pl_active="1"
            _pl_user="0"
            [ "$_pl_d" = "$KM_PROF_USER" ] && _pl_user="1"

            # compatibility: can the governor preference be resolved here?
            _pl_gpref=$(grep '^CPU_GOVERNOR_PREF=' "$_pl_f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
            _pl_compat="1"; _pl_cnote=""
            if [ -n "$_pl_gpref" ] && [ -n "$_pl_avail_govs" ]; then
                _pl_match=""
                for _pl_g in $_pl_gpref; do
                    for _pl_a in $_pl_avail_govs; do
                        [ "$_pl_g" = "$_pl_a" ] && _pl_match="$_pl_g"
                    done
                done
                if [ -z "$_pl_match" ]; then
                    _pl_compat="0"
                    _pl_cnote="no preferred governor available on this kernel"
                fi
            fi

            [ "$_pl_first" = "1" ] || _pl_json="$_pl_json,"
            _pl_first=0
            _pl_json="$_pl_json{\"name\":$(km_jesc "$_pl_name"),\"desc\":$(km_jesc "$_pl_desc"),\"version\":$(km_jnum "$_pl_ver"),\"mtime\":$(km_jnum "$_pl_mtime"),\"active\":$_pl_active,\"user\":$_pl_user,\"compatible\":$_pl_compat,\"compat_note\":$(km_jesc "$_pl_cnote")}"
        done
    done
    printf '{"ts":%s,"current":%s,"profiles":[%s]}\n' "$(km_now_ms)" "$(km_jesc "$_pl_cur")" "$_pl_json"
    return 0
}

# ----------------------------------------------------------------------
# show / compare
# ----------------------------------------------------------------------

# km_prof_show NAME -> JSON of all parsed key=value pairs
km_prof_show() {
    _ps_f=$(km_prof_file "$1") || { printf '{"ok":0,"error":"profile not found"}\n'; return 1; }
    _ps_json=""
    _ps_first=1
    while IFS= read -r _ps_l; do
        case "$_ps_l" in
            ''|\#*) continue ;;
        esac
        case "$_ps_l" in
            *=*) ;;
            *) continue ;;
        esac
        _ps_k="${_ps_l%%=*}"
        _ps_v="${_ps_l#*=}"
        [ "$_ps_first" = "1" ] || _ps_json="$_ps_json,"
        _ps_first=0
        _ps_vq="$_ps_v"
        case "$_ps_vq" in \"*\") _ps_vq="${_ps_vq#\"}"; _ps_vq="${_ps_vq%\"}" ;; esac
        _ps_json=$_ps_json$(km_jesc "$_ps_k"):$(km_jesc "$_ps_vq")
    done <"$_ps_f"
    printf '{"ok":1,"name":%s,"path":%s,"values":{%s}}\n' \
        "$(km_jesc "$1")" "$(km_jesc "$_ps_f")" "$_ps_json"
    return 0
}

# km_prof_compare A B -> JSON list of differing keys
km_prof_compare() {
    _pc_a=$(km_prof_file "$1") || { printf '{"ok":0,"error":"profile A not found"}\n'; return 1; }
    _pc_b=$(km_prof_file "$2") || { printf '{"ok":0,"error":"profile B not found"}\n'; return 1; }
    _pc_json=""
    _pc_first=1
    # union of keys, via awk on both files
    _pc_keys=$(awk -F= '/^[A-Z_]+=/ {print $1}' "$_pc_a" "$_pc_b" 2>/dev/null | sort -u)
    for _pc_k in $_pc_keys; do
        _pc_va=$(awk -F= -v k="$_pc_k" '$1==k {print $2; exit}' "$_pc_a" 2>/dev/null)
        _pc_vb=$(awk -F= -v k="$_pc_k" '$1==k {print $2; exit}' "$_pc_b" 2>/dev/null)
        case "$_pc_va" in \"*\") _pc_va="${_pc_va#\"}"; _pc_va="${_pc_va%\"}" ;; esac
        case "$_pc_vb" in \"*\") _pc_vb="${_pc_vb#\"}"; _pc_vb="${_pc_vb%\"}" ;; esac
        if [ "$_pc_va" != "$_pc_vb" ]; then
            [ "$_pc_first" = "1" ] || _pc_json="$_pc_json,"
            _pc_first=0
            _pc_json="$_pc_json{\"key\":$(km_jesc "$_pc_k"),\"a\":$(km_jesc "$_pc_va"),\"b\":$(km_jesc "$_pc_vb")}"
        fi
    done
    printf '{"ok":1,"a":%s,"b":%s,"differences":[%s]}\n' \
        "$(km_jesc "$1")" "$(km_jesc "$2")" "$_pc_json"
    return 0
}

# ----------------------------------------------------------------------
# export / import
# ----------------------------------------------------------------------

km_prof_export() {
    _pe_f=$(km_prof_file "$1") || { printf '{"ok":0,"error":"profile not found"}\n'; return 1; }
    printf '{"ok":1,"name":%s,"content":%s}\n' "$(km_jesc "$1")" "$(km_jesc "$(cat "$_pe_f" 2>/dev/null)")"
    return 0
}

# validate one line: prints error or nothing
_km_prof_line_check() {
    _lc_l="$1"
    case "$_lc_l" in
        ''|\#*) return 0 ;;
    esac
    case "$_lc_l" in
        *=*) ;;
        *) printf 'line is not KEY=VALUE: %.40s' "$_lc_l"; return 1 ;;
    esac
    _lc_k="${_lc_l%%=*}"
    _lc_v="${_lc_l#*=}"
    _km_prof_key_known "$_lc_k" || { printf 'unknown key: %s' "$_lc_k"; return 1; }
    # value safety: printable, no metachars
    case "$_lc_v" in
        *[\;\&\|\$\`\(\)\<\>\n]*) printf 'value contains prohibited characters: %s' "$_lc_k"; return 1 ;;
    esac
    case "$_lc_v" in *\\*) printf 'value contains backslash: %s' "$_lc_k"; return 1 ;; esac
    # type/range checks
    case "$_lc_k" in
        PROFILE_NAME|PROFILE_DESC|CPU_GOVERNOR_PREF|GPU_GOVERNOR_PREF|GFX_RENDERER)
            : ;;  # strings / preference lists
        PROFILE_VERSION|POLL_INTERVAL|TEMP_WARM|TEMP_HOT|TEMP_CRITICAL|CPU_MAX_PERCENT|CPU_MIN_PERCENT|GPU_MAX_PERCENT|GPU_MIN_PERCENT|CPU_HISPEED_LOAD|GPU_THROTTLING|GPU_FORCE_CLK|SCHED_CHILD_RUNS_FIRST|SCHED_AUTOGROUP|VM_SWAPPINESS|VM_VFS_CACHE_PRESSURE|VM_DIRTY_RATIO|VM_DIRTY_BACKGROUND_RATIO|VM_DIRTY_EXPIRE_CENTISECS|VM_DIRTY_WRITEBACK_CENTISECS|VM_PAGE_CLUSTER|VM_STAT_INTERVAL|CPU_UP_RATE_LIMIT_US|CPU_DOWN_RATE_LIMIT_US|SCHED_MIN_GRANULARITY_NS|SCHED_WAKEUP_GRANULARITY_NS|SCHED_MIGRATION_COST_NS|SCHED_LATENCY_NS|GPU_IDLE_TIMER|GPU_PATH)
            case "$_lc_k" in
                GPU_PATH) : ;;  # path-ish string, checked separately below
                *)
                    case "$_lc_v" in
                        ''|*[!0-9]*) printf 'value must be numeric: %s=%s' "$_lc_k" "$_lc_v"; return 1 ;;
                    esac
                    ;;
            esac
            case "$_lc_k" in
                CPU_MAX_PERCENT|CPU_MIN_PERCENT|GPU_MAX_PERCENT|GPU_MIN_PERCENT|CPU_HISPEED_LOAD)
                    [ "$_lc_v" -ge 0 ] && [ "$_lc_v" -le 100 ] || { printf 'out of range (0-100): %s=%s' "$_lc_k" "$_lc_v"; return 1; }
                    ;;
                TEMP_WARM|TEMP_HOT|TEMP_CRITICAL)
                    [ "$_lc_v" -ge 20 ] && [ "$_lc_v" -le 70 ] || { printf 'out of range (20-70): %s=%s' "$_lc_k" "$_lc_v"; return 1; }
                    ;;
                POLL_INTERVAL)
                    [ "$_lc_v" -ge 15 ] && [ "$_lc_v" -le 600 ] || { printf 'out of range (15-600): %s=%s' "$_lc_k" "$_lc_v"; return 1; }
                    ;;
                VM_SWAPPINESS)
                    [ "$_lc_v" -ge 0 ] && [ "$_lc_v" -le 200 ] || { printf 'out of range (0-200): %s=%s' "$_lc_k" "$_lc_v"; return 1; }
                    ;;
                VM_VFS_CACHE_PRESSURE)
                    [ "$_lc_v" -ge 0 ] && [ "$_lc_v" -le 1000 ] || { printf 'out of range (0-1000): %s=%s' "$_lc_k" "$_lc_v"; return 1; }
                    ;;
            esac
            ;;
    esac
    return 0
}

# km_prof_import NAME CONTENT -> JSON
km_prof_import() {
    _pi_name="$1"; _pi_content="$2"
    km_prof_name_ok "$_pi_name" || { printf '{"ok":0,"error":"invalid profile name ([a-z0-9]+, max 24)"}\n'; return 1; }
    [ -n "$_pi_content" ] || { printf '{"ok":0,"error":"empty content"}\n'; return 1; }

    # validate every line; errors collected via a temp file because the
    # read loop runs in a pipeline subshell
    _pi_tmpf="$HPC_STATE/import_check.tmp"
    _pi_cr=$(printf '\r')
    : >"$_pi_tmpf" 2>/dev/null
    printf '%s\n' "$_pi_content" | while IFS= read -r _pi_l; do
        _pi_l="${_pi_l%"$_pi_cr"}"
        _pi_e=$(_km_prof_line_check "$_pi_l")
        if [ -n "$_pi_e" ]; then
            printf '%s\n' "$_pi_e" >>"$_pi_tmpf"
        fi
    done
    _pi_err=$(head -n 1 "$_pi_tmpf" 2>/dev/null)
    rm -f "$_pi_tmpf" 2>/dev/null
    [ -n "$_pi_err" ] && { printf '{"ok":0,"error":%s}\n' "$(km_jesc "import rejected: $_pi_err")"; return 1; }

    # governor preference sanity: at least one recognizable governor word
    _pi_gpref=$(printf '%s\n' "$_pi_content" | awk -F= '/^CPU_GOVERNOR_PREF=/ {print $2; exit}' 2>/dev/null)
    if [ -n "$_pi_gpref" ] && printf '%s' "$_pi_gpref" | grep -q '[;&|$`<>()\\]'; then
        printf '{"ok":0,"error":"import rejected: governor preference malformed"}\n'
        return 1
    fi

    [ -d "$KM_PROF_USER" ] || mkdir -p "$KM_PROF_USER" 2>/dev/null
    _pi_out="$KM_PROF_USER/$_pi_name.conf"
    _pi_tmp="$_pi_out.tmp"
    {
        printf '# Hamedis Performance Core - USER profile (imported %s)\n' "$(date 2>/dev/null)"
        printf '%s\n' "$_pi_content"
    } >"$_pi_tmp" 2>/dev/null && mv -f "$_pi_tmp" "$_pi_out" 2>/dev/null
    chmod 0600 "$_pi_out" 2>/dev/null
    km_event profile_import "imported profile '$_pi_name' (not activated)"
    printf '{"ok":1,"name":%s,"path":%s,"note":"imported but NOT activated - activate from the Profile section"}\n' \
        "$(km_jesc "$_pi_name")" "$(km_jesc "$_pi_out")"
    return 0
}

# ----------------------------------------------------------------------
# duplicate / delete (user profiles only for delete)
# ----------------------------------------------------------------------

km_prof_duplicate() {
    _pd_src="$1"; _pd_dst="$2"
    km_prof_name_ok "$_pd_dst" || { printf '{"ok":0,"error":"invalid destination name"}\n'; return 1; }
    _pd_f=$(km_prof_file "$_pd_src") || { printf '{"ok":0,"error":"source profile not found"}\n'; return 1; }
    [ -d "$KM_PROF_USER" ] || mkdir -p "$KM_PROF_USER" 2>/dev/null
    _pd_out="$KM_PROF_USER/$_pd_dst.conf"
    cp -f "$_pd_f" "$_pd_out" 2>/dev/null || { printf '{"ok":0,"error":"copy failed"}\n'; return 1; }
    chmod 0600 "$_pd_out" 2>/dev/null
    km_event profile_duplicate "duplicated $_pd_src -> $_pd_dst"
    printf '{"ok":1,"from":%s,"to":%s}\n' "$(km_jesc "$_pd_src")" "$(km_jesc "$_pd_dst")"
    return 0
}

km_prof_delete() {
    _pk_name="$1"
    km_prof_name_ok "$_pk_name" || { printf '{"ok":0,"error":"invalid profile name"}\n'; return 1; }
    _pk_f="$KM_PROF_USER/$_pk_name.conf"
    [ -f "$_pk_f" ] || { printf '{"ok":0,"error":"only user profiles can be deleted (built-ins live in the module)"}\n'; return 1; }
    _pk_cur=$(current_profile 2>/dev/null)
    [ "$_pk_name" = "$_pk_cur" ] && { printf '{"ok":0,"error":"cannot delete the active profile - switch first"}\n'; return 1; }
    rm -f "$_pk_f" 2>/dev/null
    km_event profile_delete "deleted user profile '$_pk_name'"
    printf '{"ok":1,"name":%s}\n' "$(km_jesc "$_pk_name")"
    return 0
}
