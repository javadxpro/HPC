#!/system/bin/sh
# Hamedis Performance Core (HPC) - plugin loader
#
# Part of the Kernel Management Platform (v1.10).
#
# Deliberately simple extension mechanism matching the module's
# existing conventions: a plugin is a shell file in $HPC_MODDIR/plugins
# with a metadata header:
#
#   # HPC-PLUGIN: name=adapter_xiaomi_vayu version=1 min_core=1.10 perms=env,cpu
#
# Plugins may:
#   * call km_plugin_register ID NAME PATH RISK TYPE DETAIL to add
#     device-specific controls (validated at use time like everything
#     else - registration alone grants nothing)
#   * define hpc_tick_<name> - called once per service loop tick
#   * define km_mon_<name>_extra - extra monitor fields for the UI
#
# Safety:
#   * a plugin that fails to source is skipped and logged, never fatal
#   * plugins are disabled with PLUGIN_<name>=0 in config.conf
#   * plugin controls go through the SAME validation, protection and
#     change-log pipeline as core controls
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="${HPC_STATE:-$HPC_DATA/state}"
HPC_MODDIR="${HPC_MODDIR:-/data/adb/modules/hamedis_performance_core}"
KM_PLUGIN_DIR="$HPC_MODDIR/plugins"
KM_PLUGIN_CAPS="$HPC_STATE/plugin_caps.tsv"

# HPC core version this loader requires a plugin to accept (min_core)
KM_PLUGIN_MIN_CORE="${HPC_VERSION:-0}"

km_plugin_name_from_file() {
    printf '%s' "$1" | awk -F: '/^# HPC-PLUGIN:/ {
        for (i=2; i<=NF; i++) {
            split($i, kv, "=")
            if (kv[1]=="name") print kv[2]
        } exit }'
}

# km_plugin_register ID NAME PATH RISK TYPE DETAIL
km_plugin_register() {
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
    _pr_risk="${4:-low}"; _pr_type="${5:-str}"; _pr_det="${6:-plugin-provided}"
    case "$_pr_risk" in low|med|high|protected) ;; *) _pr_risk=low ;; esac
    [ -f "$KM_PLUGIN_CAPS" ] || : >"$KM_PLUGIN_CAPS" 2>/dev/null
    # replace-or-append
    _tmp="$KM_PLUGIN_CAPS.tmp"
    awk -F '\t' -v k="$1" '$1!=k' "$KM_PLUGIN_CAPS" 2>/dev/null >"$_tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$_pr_risk" "$_pr_type" "$_pr_det" >>"$_tmp"
    mv -f "$_tmp" "$KM_PLUGIN_CAPS" 2>/dev/null
    log_debug "plugin control registered: $1 -> $3"
    return 0
}

# resolve a plugin-registered control id to its path
km_plugin_path() {
    [ -f "$KM_PLUGIN_CAPS" ] || return 1
    awk -F '\t' -v k="$1" '$1==k {print $3; exit}' "$KM_PLUGIN_CAPS" 2>/dev/null
    return 0
}

# active plugin names (for tick hooks + UI)
km_plugin_names() {
    [ -f "$HPC_STATE/plugins_active" ] && cat "$HPC_STATE/plugins_active" 2>/dev/null
    return 0
}

hpc_load_plugins() {
    [ -d "$KM_PLUGIN_DIR" ] || return 0
    : >"$HPC_STATE/plugins_active" 2>/dev/null
    for _pf in "$KM_PLUGIN_DIR"/*.sh; do
        [ -f "$_pf" ] || continue
        _pname=$(km_plugin_name_from_file "$_pf")
        [ -n "$_pname" ] || _pname="${_pf##*/}"; _pname="${_pname%.sh}"
        # explicit opt-out
        case "$_pname" in
            *[!a-z0-9_]*) log_warn "plugin skipped (bad name): $_pf"; continue ;;
        esac
        if [ "$(eval "printf '%s' \"\${PLUGIN_${_pname}:-1}\"" 2>/dev/null)" = "0" ]; then
            log_debug "plugin disabled by config: $_pname"
            continue
        fi
        _perr=$(sh -n "$_pf" 2>&1)
        if [ -n "$_perr" ]; then
            log_warn "plugin skipped (syntax error): $_pname - $_perr"
            continue
        fi
        if ! . "$_pf" 2>"$HPC_STATE/plugin_src_err"; then
            log_warn "plugin failed to load: $_pname ($(cat "$HPC_STATE/plugin_src_err" 2>/dev/null | head -n1))"
            rm -f "$HPC_STATE/plugin_src_err" 2>/dev/null
            continue
        fi
        rm -f "$HPC_STATE/plugin_src_err" 2>/dev/null
        printf '%s\n' "$_pname" >>"$HPC_STATE/plugins_active" 2>/dev/null
        log_info "plugin loaded: $_pname"
    done
    return 0
}

# service-loop hook: call each active plugin's tick function, if any
hpc_tick_plugins() {
    for _pt in $(km_plugin_names); do
        _ptfn="hpc_tick_${_pt}"
        if command -v "$_ptfn" >/dev/null 2>&1; then
            "$_ptfn" 2>/dev/null || log_warn "plugin tick failed: $_pt"
        fi
    done
    return 0
}
