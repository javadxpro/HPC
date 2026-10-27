#!/system/bin/sh
# Hamedis Performance Core (HPC) - common bootstrap
# Sourced by every entry point. Loads libraries, config and capabilities
# in the correct order, exactly once.
# shellcheck disable=SC3043

HPC_ID="hamedis_performance_core"
HPC_NAME="Hamedis Performance Core"
HPC_SHORT="HPC"
HPC_VERSION="1.10.0"

HPC_MODDIR="${HPC_MODDIR:-/data/adb/modules/$HPC_ID}"
HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_LOG_DIR="$HPC_DATA/logs"
HPC_CONFIG="$HPC_DATA/config.conf"
# Freshness window (seconds) for the capability registry, shared by the
# service loop (which refreshes at TTL-60) and the WebUI CGI (which
# falls back to a full scan only past TTL). Must stay in sync - see
# hpc_bootstrap() and service.sh.
HPC_REG_TTL="${HPC_REG_TTL:-300}"
HPC_SCRIPTS="$HPC_MODDIR/scripts"

# Create the persistent data tree. Everything HPC writes lives here,
# NOT inside the module directory, so it survives module updates.
hpc_init_dirs() {
    for _d in "$HPC_DATA" "$HPC_STATE" "$HPC_LOG_DIR" "$HPC_DATA/profiles"; do
        [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
    done
    chmod 0700 "$HPC_DATA" 2>/dev/null
}

# Install the default config on first run, and seed user-editable copies
# of the profiles so the user can tune them without touching the module.
hpc_init_config() {
    if [ ! -f "$HPC_CONFIG" ]; then
        if [ -f "$HPC_MODDIR/config/config.conf" ]; then
            cp -f "$HPC_MODDIR/config/config.conf" "$HPC_CONFIG" 2>/dev/null
        fi
        chmod 0600 "$HPC_CONFIG" 2>/dev/null
    fi

    for _p in cool balanced performance gaming90 gaming120 longevity \
              battery_saver silent multitasking standby; do
        if [ ! -f "$HPC_DATA/profiles/$_p.conf" ] && \
           [ -f "$HPC_MODDIR/config/profiles/$_p.conf" ]; then
            cp -f "$HPC_MODDIR/config/profiles/$_p.conf" \
                  "$HPC_DATA/profiles/$_p.conf" 2>/dev/null
        fi
    done
}

# Add keys introduced by newer versions to an existing config, without
# touching anything the user has already customised.
#
# The installer deliberately preserves config.conf across updates so your
# game list and tuning survive. The side effect was that NEW settings
# never arrived - a user upgrading from 1.4 still had GAME_PROFILE
# pointing at a profile that predated gaming90.
hpc_migrate_config() {
    [ -f "$HPC_CONFIG" ] || return 0
    _mig=0

    # key|default|comment
    for _entry in \
        "WEBUI_PORT|1111|Port for the web management interface (loopback only)" \
        "WEBUI_AUTOSTART|1|1 = start the WebUI automatically at boot" \
        "BATT_LOW|20|Below this %, PERFORMANCE downgrades to BALANCED" \
        "BATT_CRITICAL|10|Below this %, COOL is forced" \
        "IO_SCHEDULER||Leave empty to keep the kernel default" \
        "THERMAL_HYST|4|Degrees below a threshold before de-escalating" \
        ; do
        _k=${_entry%%|*}
        _rest=${_entry#*|}
        _def=${_rest%%|*}
        _cmt=${_rest#*|}
        if ! grep -q "^[[:space:]]*$_k=" "$HPC_CONFIG" 2>/dev/null; then
            {
                printf '\n# %s\n' "$_cmt"
                printf '%s=%s\n' "$_k" "$_def"
            } >>"$HPC_CONFIG" 2>/dev/null
            _mig=$((_mig + 1))
        fi
    done

    # GAME_PROFILE pointing at a profile that no longer exists, or at an
    # older default, is silently corrected once.
    _gp=$(grep '^[[:space:]]*GAME_PROFILE=' "$HPC_CONFIG" 2>/dev/null | cut -d= -f2 | tr -d ' ')
    if [ -n "$_gp" ] && [ ! -f "$HPC_DATA/profiles/$_gp.conf" ] && \
       [ ! -f "$HPC_MODDIR/config/profiles/$_gp.conf" ]; then
        sed -i "s/^[[:space:]]*GAME_PROFILE=.*/GAME_PROFILE=balanced/" "$HPC_CONFIG" 2>/dev/null
        _mig=$((_mig + 1))
    fi

    # Same guard for MODE (e.g. longevity, which no longer ships with the
    # module): a missing profile file would otherwise make every service
    # tick log an error and leave the device on the previous profile.
    _md=$(grep '^[[:space:]]*MODE=' "$HPC_CONFIG" 2>/dev/null | cut -d= -f2 | tr -d ' ')
    if [ -n "$_md" ] && [ ! -f "$HPC_DATA/profiles/$_md.conf" ] && \
       [ ! -f "$HPC_MODDIR/config/profiles/$_md.conf" ]; then
        sed -i "s/^[[:space:]]*MODE=.*/MODE=balanced/" "$HPC_CONFIG" 2>/dev/null
        _mig=$((_mig + 1))
    fi

    [ "$_mig" -gt 0 ] && log_info "config migrated: $_mig key(s) added"
    return 0
}

# hpc_config_check -> "ok" when the config is sourceable, otherwise the
# shell's error line (ash includes the line number, e.g.
# "sh: 104: syntax error: ..." or "sh: 104: cool: not found").
# Two passes:
#   1. sh -n  : catches syntax errors (unbalanced quotes, ...)
#   2. source in a throwaway subshell: catches a stray word with no '='
#      (e.g. a leftover "cool" on the last line), which is syntactically
#      valid but gets EXECUTED when the config is sourced - the classic
#      "line 104: not found" that kills the WebUI.
hpc_config_check() {
    [ -f "$HPC_CONFIG" ] || { printf 'missing'; return 0; }
    _hcc_out=$(sh -n "$HPC_CONFIG" 2>&1)
    if [ -n "$_hcc_out" ]; then
        printf '%s\n' "$_hcc_out" | head -n 1
        return 1
    fi
    _hcc_run=$(sh -c ". \"$HPC_CONFIG\"" 2>&1)
    if [ -n "$_hcc_run" ]; then
        printf '%s\n' "$_hcc_run" | head -n 1
        return 1
    fi
    printf 'ok'
    return 0
}

hpc_load_config() {
    # Syntax-check BEFORE sourcing: a broken config.conf must not be able
    # to take the WebUI/API/service down. A corrupted line (CRLF from an
    # editor, a half-removed key, ...) used to kill the shell that sourced
    # it; now it degrades to the built-in defaults and is logged with the
    # offending line number. `hpc.sh config` shows details,
    # `hpc.sh config-fix` reseeds the file.
    if [ -f "$HPC_CONFIG" ]; then
        _hpc_cfg_err=$(hpc_config_check)
        if [ "$_hpc_cfg_err" = "ok" ]; then
            . "$HPC_CONFIG"
        else
            log_error "config.conf rejected, using built-in defaults: $_hpc_cfg_err"
        fi
    fi
    # Defaults for anything the user deleted from the file.
    MODE="${MODE:-balanced}"
    AUTO_GAME_MODE="${AUTO_GAME_MODE:-1}"
    GAME_PROFILE="${GAME_PROFILE:-performance}"
    THERMAL_PROTECTION="${THERMAL_PROTECTION:-1}"
    BATTERY_AWARE="${BATTERY_AWARE:-1}"
    LOGGING="${LOGGING:-1}"
    POLL_INTERVAL="${POLL_INTERVAL:-45}"
    SERVICE_ENABLED="${SERVICE_ENABLED:-1}"
    # Clamp poll interval to something sane.
    case "$POLL_INTERVAL" in
        ''|*[!0-9]*) POLL_INTERVAL=45 ;;
    esac
    [ "$POLL_INTERVAL" -lt 15 ] && POLL_INTERVAL=15
    [ "$POLL_INTERVAL" -gt 600 ] && POLL_INTERVAL=600
}

hpc_load_libs() {
    # Order matters: the km_* (kernel management platform) layers sit on
    # top of detector/safety/kernel_manager and must load after them.
    for _lib in logger safety detector profile_manager thermal_manager \
                ram_manager battery_manager graphics_manager kernel_manager webui game_detector monitor \
                cleaner booster \
                km_discover km_registry km_events km_monitor km_bench \
                km_diag km_advise km_profiles magisk_sys plugin_loader; do
        # shellcheck source=/dev/null
        [ -f "$HPC_SCRIPTS/$_lib.sh" ] && . "$HPC_SCRIPTS/$_lib.sh"
    done
}

# Full bootstrap used by service.sh and action.sh.
hpc_bootstrap() {
    hpc_init_dirs
    hpc_init_config
    hpc_load_libs
    hpc_migrate_config
    hpc_load_config
    hpc_log_init
    hpc_safety_init
    load_capabilities
    # Kernel Management Platform: load plugins, then build the
    # capability registry (discovery + change detection).
    # The registry is STRUCTURAL data (which sysfs paths exist, rw
    # permission, risk) - it only changes on reboot, kernel-module
    # load or ROM updates, so a few minutes of age is harmless.
    # The CGI only scans when the registry is older than HPC_REG_TTL;
    # the service (POLL_INTERVAL cadence) refreshes it at TTL-60, so a
    # live WebUI poll essentially never pays the scan cost. (Before
    # this was aligned, the service scanned every 10 ticks (~7 min)
    # while the CGI went stale after 60 s - so for ~6 min out of every
    # 7, every 3 s WebUI poll ran a full capability scan and the UI
    # felt slow.)
    if [ "${HPC_KM_SCAN_FORCE:-0}" = "1" ]; then
        km_caps_scan
    else
        _hb_reg="$HPC_STATE/caps2/registry.tsv"
        _hb_fresh=0
        if [ -f "$_hb_reg" ]; then
            _hb_age=$(( $(date +%s) - $(stat -c %Y "$_hb_reg" 2>/dev/null || printf '0') ))
            [ "$_hb_age" -ge 0 ] && [ "$_hb_age" -lt "${HPC_REG_TTL:-300}" ] && _hb_fresh=1
        fi
        [ "$_hb_fresh" = "1" ] || km_caps_scan
    fi
}
