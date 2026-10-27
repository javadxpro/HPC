#!/system/bin/sh
# Hamedis Performance Core - WebUI server control
#
# Serves the management interface on 127.0.0.1:1111 using busybox httpd.
#
# SECURITY: bound to 127.0.0.1 only. The interface can change CPU limits
# and charging behaviour, so it must not be reachable from the network.
# Anyone on the same Wi-Fi would otherwise be able to control the phone.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_WEB_PID="$HPC_STATE/webui_pid"
HPC_WEB_PORT="${WEBUI_PORT:-1111}"

web_root() {
    printf '%s' "${HPC_MODDIR:-/data/adb/modules/hamedis_performance_core}/webroot"
}

web_busybox() {
    for _b in /data/adb/magisk/busybox \
              /data/adb/ksu/bin/busybox \
              /data/adb/ap/bin/busybox \
              "$(command -v busybox 2>/dev/null)" ; do
        [ -n "$_b" ] && [ -x "$_b" ] && { printf '%s' "$_b"; return 0; }
    done
    return 1
}

web_running() {
    [ -f "$HPC_WEB_PID" ] || return 1
    _wp=$(cat "$HPC_WEB_PID" 2>/dev/null)
    case "$_wp" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_wp" ]
}

# Kill any process whose /proc cmdline mentions the given pattern.
# Portable: Android's toybox has no pkill applet, and since Magisk v31+
# the busybox applet dir is no longer on the module script PATH.
web_kill_cmdline() {
    _wkc_pat="$1"
    for _wkc_d in /proc/[0-9]*; do
        _wkc_pid="${_wkc_d#/proc/}"
        [ "$_wkc_pid" = "$$" ] && continue
        # 2>/dev/null must precede the input redirect: dash applies
        # redirects left-to-right, so a process that dies between the
        # glob and the read would otherwise leak a "can't open
        # /proc/N/cmdline" message onto the Action-button log.
        _wkc_cl=$(tr '\0' ' ' 2>/dev/null <"$_wkc_d/cmdline") || continue
        case "$_wkc_cl" in
            *httpd*$_wkc_pat*)
                [ "$_wkc_pid" = "$$" ] && continue
                kill "$_wkc_pid" 2>/dev/null
                ;;
        esac
    done
    return 0
}

web_start() {
    web_kill_cmdline "127.0.0.1:$HPC_WEB_PORT"
    sleep 1

    _bb=$(web_busybox) || {
        log_error "webui: busybox not found"
        return 1
    }
    _root=$(web_root)
    [ -d "$_root" ] || { log_error "webui: webroot missing"; return 1; }

    # CGI needs to know where the module lives.
    HPC_WEB_MODDIR="${HPC_MODDIR:-/data/adb/modules/hamedis_performance_core}"
    export HPC_WEB_MODDIR

    # Self-heal: busybox httpd returns an empty body (no error) when a
    # CGI script is not executable, which is very hard to diagnose.
    for _cgi in "$_root"/cgi-bin/*.sh; do
        [ -f "$_cgi" ] && chmod 0755 "$_cgi" 2>/dev/null
    done

    # -c supplies the MIME map. Without it busybox serves
    # .webmanifest with no Content-Type and Chrome refuses to treat the
    # app as installable, with no visible error.
    _conf="$_root/httpd.conf"
    if [ -f "$_conf" ]; then
        "$_bb" httpd -f -p "127.0.0.1:$HPC_WEB_PORT" -h "$_root" -c "$_conf" \
            >/dev/null 2>&1 &
    else
        log_warn "webui: httpd.conf missing, PWA install will not work"
        "$_bb" httpd -f -p "127.0.0.1:$HPC_WEB_PORT" -h "$_root" \
            >/dev/null 2>&1 &
    fi
    _pid=$!
    printf '%s' "$_pid" >"$HPC_WEB_PID" 2>/dev/null

    # Give it a moment, then confirm it actually bound.
    sleep 1
    if [ -d "/proc/$_pid" ]; then
        log_info "webui: listening on 127.0.0.1:$HPC_WEB_PORT"
        return 0
    fi
    rm -f "$HPC_WEB_PID" 2>/dev/null
    log_error "webui: failed to start"
    return 1
}

web_stop() {
    if [ -f "$HPC_WEB_PID" ]; then
        _wp=$(cat "$HPC_WEB_PID" 2>/dev/null)
        case "$_wp" in
            ''|*[!0-9]*) ;;
            *) kill "$_wp" 2>/dev/null ;;
        esac
        rm -f "$HPC_WEB_PID" 2>/dev/null
    fi
    # Belt and braces: kill any stray httpd on our port.
    web_kill_cmdline "127.0.0.1:$HPC_WEB_PORT"
    log_info "webui: stopped"
    return 0
}

web_open() {
    _url="http://localhost:$HPC_WEB_PORT/"
    # Try the standard Android intent first; fall back to termux.
    am start -a android.intent.action.VIEW -d "$_url" \
        >/dev/null 2>&1 && return 0
    command -v termux-open-url >/dev/null 2>&1 && \
        termux-open-url "$_url" >/dev/null 2>&1 && return 0
    return 1
}
