#!/system/bin/sh
# action.sh — Action مگیسک: شروع WebUI و باز کردن مرورگر
MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="."
case "$MODDIR" in
    /*) ;;
    *)  MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" || MODDIR="${0%/*}" ;;
esac
export HPC_MODDIR="$MODDIR"

# shellcheck source=/dev/null
. "$MODDIR/scripts/common.sh"
hpc_bootstrap

PORT="${WEBUI_PORT:-1111}"
URL="http://localhost:$PORT"

if web_start; then
    echo ""
    echo "  HPC Kernel Manager"
    echo "  ─────────────────────────────"
    echo "  $URL"
    echo ""
    web_open && echo "  Opening browser..." || \
        echo "  Open that address in your browser."
    echo ""
else
    echo ""
    echo "  Could not start the WebUI."
    echo "  Check: sh $MODDIR/hpc.sh log 20"
    echo ""
fi
exit 0
