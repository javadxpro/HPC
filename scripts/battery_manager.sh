#!/system/bin/sh
# Hamedis Performance Core (HPC) - battery awareness
#
# Decides whether the requested profile should be honoured or softened
# based on charge level and charging state.
# Returns the profile name that SHOULD be active. Never writes anything
# itself - the caller applies the result.
# shellcheck disable=SC3043

HPC_DATA="${HPC_DATA:-/data/adb/hamedis}"

# Thresholds (overridable from config.conf)
BATT_LOW="${BATT_LOW:-20}"
BATT_CRITICAL="${BATT_CRITICAL:-10}"

# battery_adjust_profile REQUESTED -> prints the profile to actually use
battery_adjust_profile() {
    _req="$1"

    # Feature off: honour the request verbatim.
    [ "${BATTERY_AWARE:-1}" = "1" ] || { printf '%s' "$_req"; return 0; }

    _cap=$(battery_capacity 2>/dev/null)
    _charging=0
    battery_charging 2>/dev/null && _charging=1

    # --- charge level policy
    if [ -n "$_cap" ]; then
        case "$_cap" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$_cap" -le "$BATT_CRITICAL" ] && [ "$_charging" -eq 0 ]; then
                    [ "$_req" != "cool" ] && \
                        log_info "battery ${_cap}%: forcing cool"
                    printf 'cool'
                    return 0
                fi
                if [ "$_cap" -le "$BATT_LOW" ] && [ "$_charging" -eq 0 ]; then
                    if [ "$_req" = "performance" ]; then
                        log_info "battery ${_cap}%: downgrading performance -> balanced"
                        printf 'balanced'
                        return 0
                    fi
                fi
                ;;
        esac
    fi

    printf '%s' "$_req"
    return 0
}

# Should a game be allowed the full gaming profile right now?
battery_allows_gaming() {
    [ "${BATTERY_AWARE:-1}" = "1" ] || return 0
    _cap=$(battery_capacity 2>/dev/null)
    case "$_cap" in
        ''|*[!0-9]*) return 0 ;;
    esac
    _charging=0
    battery_charging 2>/dev/null && _charging=1
    # Plugged in: allow, provided temperature is sane (checked elsewhere).
    [ "$_charging" -eq 1 ] && return 0
    [ "$_cap" -gt "$BATT_LOW" ]
}
