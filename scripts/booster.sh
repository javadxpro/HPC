#!/system/bin/sh
# Hamedis Performance Core (HPC) - speed booster
#
# Combines the profile engine with booster-only extras that the profile
# system does not manage:
#   * I/O scheduler (UFS: "none" is the right call)
#   * VM speed values (swappiness / vfs_cache_pressure)
#   * Android animation scales (settings, global)
#   * MIUI "memory extension" (virtual RAM on the UFS - a real slowdown)
#
# Design rules:
#   * The CPU governor belongs to the profile engine (the service
#     re-applies it on every profile switch), so the booster never writes
#     governors directly. "Speed mode" = apply the performance profile
#     + the extras. "Speed off" = restore extras + re-apply MODE.
#   * Every sysfs/proc write goes through safe_write (backup + verify),
#     so uninstall.sh's restore_all covers them automatically.
#   * `settings` changes are NOT file nodes; their originals are saved in
#     $HPC_STATE/booster_settings and restored by uninstall.sh /
#     booster_restore_settings.
#   * Thermal protection is never touched.
# shellcheck disable=SC3043

BOOSTER_STATE="$HPC_STATE/booster_active"
BOOSTER_SETTINGS_BAK="$HPC_STATE/booster_settings"

# --- settings helpers ---------------------------------------------------

_bs_get() {  # _bs_get TABLE NAME  -> value, or the literal string null
    settings get "$1" "$2" 2>/dev/null
}

_bs_save_orig() {  # _bs_save_orig TABLE NAME  (first time only)
    _bso_t="$1"; _bso_n="$2"
    [ -f "$BOOSTER_SETTINGS_BAK" ] || : >"$BOOSTER_SETTINGS_BAK" 2>/dev/null
    _bso_line=$(awk -F '\t' -v t="$_bso_t" -v n="$_bso_n" \
        '$1==t && $2==n {print; exit}' "$BOOSTER_SETTINGS_BAK" 2>/dev/null)
    [ -n "$_bso_line" ] && return 0
    _bso_v=$(_bs_get "$_bso_t" "$_bso_n")
    [ -n "$_bso_v" ] || _bso_v="__null__"
    printf '%s\t%s\t%s\n' "$_bso_t" "$_bso_n" "$_bso_v" >>"$BOOSTER_SETTINGS_BAK" 2>/dev/null
}

_bs_put() {  # _bs_put TABLE NAME VALUE
    _bs_save_orig "$1" "$2"
    settings put "$1" "$2" "$3" 2>/dev/null
}

booster_restore_settings() {
    [ -f "$BOOSTER_SETTINGS_BAK" ] || return 0
    _brs_n=0
    while IFS="$(printf '\t')" read -r _brs_t _brs_nam _brs_v; do
        [ -n "$_brs_t" ] || continue
        if [ "$_brs_v" = "__null__" ]; then
            settings delete "$_brs_t" "$_brs_nam" 2>/dev/null
        else
            settings put "$_brs_t" "$_brs_nam" "$_brs_v" 2>/dev/null
        fi
        _brs_n=$((_brs_n + 1))
    done <"$BOOSTER_SETTINGS_BAK" 2>/dev/null
    log_info "booster: restored $_brs_n setting(s)"
}

# --- animations ----------------------------------------------------------

BOOSTER_ANIM_KEYS="window_animation_scale transition_animation_scale animator_duration_scale"

booster_anim_off() {
    _ba_ok=0
    for _ba_k in $BOOSTER_ANIM_KEYS; do
        _bs_put global "$_ba_k" 0.0 && _ba_ok=1
    done
    [ "$_ba_ok" -eq 1 ]
}

booster_anim_on() {
    _bo_ok=0
    for _bo_k in $BOOSTER_ANIM_KEYS; do
        # Restore the PRE-BOOSTER original when we have one; 1.0 is the
        # stock value on a clean system.
        _bo_v=$(awk -F '\t' -v n="$_bo_k" \
            '$1=="global" && $2==n {print $3; exit}' "$BOOSTER_SETTINGS_BAK" 2>/dev/null)
        case "$_bo_v" in
            ''|__null__|*[!0-9.]) _bo_v=1.0 ;;
        esac
        _bs_put global "$_bo_k" "$_bo_v" && _bo_ok=1
    done
    [ "$_bo_ok" -eq 1 ]
}

booster_anim_value() {
    _bs_get global window_animation_scale
}

# --- VM speed values ------------------------------------------------------

booster_vm_on() {
    # Lower swappiness: keep hot pages in RAM. 50 cache pressure: drop
    # inode/dentry caches sooner than the stock 100 - on a phone the
    # inode cache is mostly useless weight.
    safe_write /proc/sys/vm/swappiness 1 &&
    safe_write /proc/sys/vm/vfs_cache_pressure 50
}

booster_vm_off() {
    restore_node /proc/sys/vm/swappiness
    restore_node /proc/sys/vm/vfs_cache_pressure
}

# --- MIUI memory extension (virtual RAM) ----------------------------------
# Probed, not assumed: the key differs between MIUI versions.

BOOSTER_MEMEXT_KEYS="miui_virtual_ram_enable virtual_ram_enable miui_virtual_ram miframework_virtual_ram"

# Find the first existing key; prints "table|key" or nothing.
booster_memext_find() {
    for _bmf_k in $BOOSTER_MEMEXT_KEYS; do
        for _bmf_t in global secure; do
            _bmf_v=$(_bs_get "$_bmf_t" "$_bmf_k")
            [ -n "$_bmf_v" ] && [ "$_bmf_v" != "null" ] && {
                printf '%s|%s' "$_bmf_t" "$_bmf_k"
                return 0
            }
        done
    done
    return 1
}

booster_memext_off() {
    _bmo_f=$(booster_memext_find) || return 1
    _bs_put "${_bmo_f%%|*}" "${_bmo_f#*|}" 0
}

booster_memext_on() {
    _bmo_f=$(booster_memext_find) || return 1
    _bs_put "${_bmo_f%%|*}" "${_bmo_f#*|}" 1
}

booster_memext_state() {
    _bms_f=$(booster_memext_find) || { printf 'unknown'; return 0; }
    _bms_v=$(_bs_get "${_bms_f%%|*}" "${_bms_f#*|}")
    case "$_bms_v" in
        0) printf 'off' ;;
        1) printf 'on' ;;
        *) printf 'unknown' ;;
    esac
}

# --- modes ----------------------------------------------------------------

booster_speed_on() {
    [ -f "$BOOSTER_STATE" ] && return 0

    # 1) The profile engine takes the governor / ceilings / floors.
    #    Battery policy may downgrade (same rule the UI profile switch uses).
    apply_profile "$(battery_adjust_profile performance)" quiet >/dev/null 2>&1

    # 2) I/O: UFS wants no software scheduler.
    km_set_io "none walt mq-deadline" >/dev/null 2>&1

    # 3) VM speed values (after the profile, so they win).
    booster_vm_on

    # 4) Animations off.
    booster_anim_off

    # 5) Virtual RAM off (best effort).
    booster_memext_off || true

    printf '1\n' >"$BOOSTER_STATE" 2>/dev/null
    log_info "booster: speed mode ON"
    return 0
}

booster_speed_off() {
    [ -f "$BOOSTER_STATE" ] || return 0
    rm -f "$BOOSTER_STATE" 2>/dev/null

    booster_vm_off
    booster_restore_settings

    # Back to the user's baseline profile.
    apply_profile "$(battery_adjust_profile "${MODE:-balanced}")" quiet >/dev/null 2>&1
    log_info "booster: speed mode OFF"
    return 0
}

booster_active() {
    [ -f "$BOOSTER_STATE" ]
}
