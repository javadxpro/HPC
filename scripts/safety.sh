#!/system/bin/sh
# Hamedis Performance Core (HPC) - safety / state layer
#
# Core guarantees provided here:
#   1. Never write to a node that does not exist.
#   2. Never write without first saving the original value.
#   3. Verify the write landed; log and continue if it did not.
#   4. Never abort the caller on failure (no set -e semantics leak out).
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"
HPC_STATE="$HPC_DATA/state"
HPC_BACKUP="$HPC_STATE/original_values"     # key<TAB>value
HPC_APPLIED="$HPC_STATE/applied_values"     # key<TAB>value currently set by us

hpc_safety_init() {
    [ -d "$HPC_STATE" ] || mkdir -p "$HPC_STATE" 2>/dev/null
    [ -f "$HPC_BACKUP" ]  || : >"$HPC_BACKUP"  2>/dev/null
    [ -f "$HPC_APPLIED" ] || : >"$HPC_APPLIED" 2>/dev/null
    chmod 0600 "$HPC_BACKUP" "$HPC_APPLIED" 2>/dev/null
}

# --- existence / capability probes -------------------------------------

node_exists()   { [ -e "$1" ]; }
node_readable() { [ -r "$1" ]; }

# A node is writable if the file is writable OR we can make it so.
# Some sysfs nodes are 0444 but chmod-able as root.
# SELinux state helpers -------------------------------------------------
_selinux_enforcing() {
    [ -r /sys/fs/selinux/enforce ] || return 1
    [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ]
}

# Try to grant write access to a sysfs node that SELinux is blocking.
# Uses magiskpolicy live patching, which is the supported mechanism for
# Magisk modules. Narrow: only the node's own type is allowed, and only
# for the magisk domain.
_selinux_allow_node() {
    _sp="$1"
    command -v magiskpolicy >/dev/null 2>&1 || return 1
    _ctx=$(ls -Zd "$_sp" 2>/dev/null | awk '{print $1}')
    _type=$(printf '%s' "$_ctx" | awk -F: '{print $3}')
    [ -n "$_type" ] || return 1
    magiskpolicy --live "allow magisk $_type file { open read write getattr }" 2>/dev/null
    magiskpolicy --live "allow init $_type file { open read write getattr }" 2>/dev/null
    return 0
}

node_writable() {
    [ -e "$1" ] || return 1
    # DAC first.
    [ -w "$1" ] || chmod 0644 "$1" 2>/dev/null
    # -w only reflects DAC. SELinux denies at open(), so -w can lie.
    # The only reliable test is an actual open for write.
    ( : >>"$1" ) 2>/dev/null && return 0
    # Blocked. If SELinux is the reason, try to grant access once.
    if _selinux_enforcing; then
        _selinux_allow_node "$1" || return 1
        ( : >>"$1" ) 2>/dev/null && return 0
    fi
    return 1
}

# Read a node safely; prints nothing and returns 1 if unreadable.
read_node() {
    _p="$1"
    [ -e "$_p" ] || return 1
    [ -r "$_p" ] || return 1
    # head -n1 guards against multi-line nodes and huge files.
    head -n 1 "$_p" 2>/dev/null || return 1
}

# --- backup bookkeeping ------------------------------------------------

_kv_get() {
    # _kv_get FILE KEY
    [ -f "$1" ] || return 1
    # Exact match on first tab-separated field.
    awk -F '\t' -v k="$2" '$1==k {print $2; found=1; exit} END{exit !found}' "$1" 2>/dev/null
}

_kv_set() {
    # _kv_set FILE KEY VALUE  (replace or append, atomic-ish)
    _f="$1"; _k="$2"; _v="$3"
    [ -f "$_f" ] || : >"$_f" 2>/dev/null
    _tmp="$_f.tmp.$$"
    awk -F '\t' -v k="$_k" '$1!=k' "$_f" 2>/dev/null >"$_tmp"
    printf '%s\t%s\n' "$_k" "$_v" >>"$_tmp" 2>/dev/null
    mv -f "$_tmp" "$_f" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
}

_kv_del() {
    _f="$1"; _k="$2"
    [ -f "$_f" ] || return 0
    _tmp="$_f.tmp.$$"
    awk -F '\t' -v k="$_k" '$1!=k' "$_f" 2>/dev/null >"$_tmp"
    mv -f "$_tmp" "$_f" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
}

# Save original value exactly once. Subsequent calls are no-ops so that
# profile switching never overwrites the true pre-module value.
backup_original() {
    _path="$1"
    _kv_get "$HPC_BACKUP" "$_path" >/dev/null 2>&1 && return 0
    _cur=$(read_node "$_path") || return 1
    _kv_set "$HPC_BACKUP" "$_path" "$_cur"
    log_debug "backup $_path = $_cur"
    return 0
}

# --- the single write primitive ----------------------------------------
#
# safe_write PATH VALUE [--verify|--no-verify]
#
# Returns 0 on success, 1 if skipped/failed. NEVER returns nonzero in a
# way that can kill a caller running under `set -e` — callers use `|| true`
# patterns, and we always end with an explicit return.
safe_write() {
    _path="$1"
    _val="$2"
    _mode="${3:---verify}"

    if [ ! -e "$_path" ]; then
        log_unsupported "$_path" "node missing"
        return 1
    fi

    if ! node_writable "$_path"; then
        log_unsupported "$_path" "not writable"
        return 1
    fi

    _cur=$(read_node "$_path")
    # Skip redundant writes: saves CPU and avoids kernel churn.
    if [ "$_cur" = "$_val" ]; then
        _kv_set "$HPC_APPLIED" "$_path" "$_val"
        return 0
    fi

    backup_original "$_path"

    # The actual write.
    # NOTE: the SHELL reports redirection failures ("can't create ...")
    # itself, before the command ever runs, so `printf ... >"$p" 2>/dev/null`
    # does NOT suppress them. The redirection must happen inside a subshell
    # whose stderr is discarded.
    if ! ( printf '%s' "$_val" >"$_path" ) 2>/dev/null; then
        if _selinux_enforcing; then
            log_unsupported "$_path" "write blocked (SELinux enforcing)"
        else
            log_unsupported "$_path" "write rejected (value=$_val)"
        fi
        return 1
    fi

    if [ "$_mode" = "--verify" ]; then
        _new=$(read_node "$_path")
        # Kernel may normalise (e.g. "1" -> "1", "0x1" -> "1"), so accept
        # either exact match or numeric equality.
        if [ "$_new" != "$_val" ]; then
            if ! _num_eq "$_new" "$_val"; then
                log_warn "verify mismatch $_path: wanted=$_val got=$_new"
                _kv_set "$HPC_APPLIED" "$_path" "$_new"
                return 1
            fi
        fi
    fi

    _kv_set "$HPC_APPLIED" "$_path" "$_val"
    log_debug "write $_path = $_val"
    return 0
}

_num_eq() {
    case "$1" in ''|*[!0-9-]*) return 1 ;; esac
    case "$2" in ''|*[!0-9-]*) return 1 ;; esac
    [ "$1" -eq "$2" ] 2>/dev/null
}

# Restore one node to its pre-module value.
restore_node() {
    _path="$1"
    _orig=$(_kv_get "$HPC_BACKUP" "$_path") || return 1
    [ -e "$_path" ] || return 1
    node_writable "$_path" || return 1
    ( printf '%s' "$_orig" >"$_path" ) 2>/dev/null || {
        log_warn "restore failed: $_path"
        return 1
    }
    _kv_del "$HPC_APPLIED" "$_path"
    log_debug "restore $_path = $_orig"
    return 0
}

# Restore everything we ever touched. Used by uninstall and `reset`.
restore_all() {
    [ -f "$HPC_BACKUP" ] || return 0
    _n=0
    _fail=0
    while IFS="$(printf '\t')" read -r _p _v; do
        [ -n "$_p" ] || continue
        if [ -e "$_p" ] && node_writable "$_p"; then
            if ( printf '%s' "$_v" >"$_p" ) 2>/dev/null; then
                _n=$((_n + 1))
            else
                _fail=$((_fail + 1))
            fi
        fi
    done <"$HPC_BACKUP"
    : >"$HPC_APPLIED" 2>/dev/null
    log_info "restore_all: restored=$_n failed=$_fail"
    return 0
}

# Write a whole list of "path value" pairs from stdin, tolerating failures.
# Usage:  printf '%s\n' "/sys/x 1" "/sys/y 2" | apply_pairs
apply_pairs() {
    _ok=0; _skip=0
    while read -r _p _v; do
        [ -n "$_p" ] || continue
        case "$_p" in \#*) continue ;; esac
        if safe_write "$_p" "$_v"; then
            _ok=$((_ok + 1))
        else
            _skip=$((_skip + 1))
        fi
    done
    log_debug "apply_pairs ok=$_ok skipped=$_skip"
    return 0
}
