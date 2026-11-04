#!/bin/sh
# Build hpc-kbd.deb (Architecture: all — pure python).
set -e
cd "$(dirname "$0")"
VER=0.1.0
PKG=hpc-kbd
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/$PKG" \
         "$STAGE/usr/lib/python3/dist-packages/hpc_kbd" \
         "$STAGE/usr/share/applications" "$STAGE/etc/xdg/autostart"

cp packaging/control "$STAGE/DEBIAN/control"

# launcher
cat > "$STAGE/usr/bin/hpc-kbd" <<'LNCH'
#!/bin/sh
exec /usr/bin/python3 /usr/share/hpc-kbd/main.py "$@"
LNCH
chmod 755 "$STAGE/usr/bin/hpc-kbd"

# app
cp main.py layouts.json "$STAGE/usr/share/hpc-kbd/"

# python package (im client + generated wayland bindings)
cp hpc_kbd/im_client.py "$STAGE/usr/lib/python3/dist-packages/hpc_kbd/"
touch "$STAGE/usr/lib/python3/dist-packages/hpc_kbd/__init__.py"
mkdir -p "$STAGE/usr/lib/python3/dist-packages/hpc_kbd/wl"
cp hpc_kbd/wl/*.py "$STAGE/usr/lib/python3/dist-packages/hpc_kbd/wl/"

# desktop entries
cp packaging/hpc-kbd.desktop "$STAGE/usr/share/applications/"
cp packaging/autostart-hpc-kbd.desktop "$STAGE/etc/xdg/autostart/"

chmod 755 "$STAGE/DEBIAN"
dpkg-deb --build --root-owner-group "$STAGE" "hpc-kbd_${VER}_all.deb"
echo "built: $(pwd)/${PKG}_${VER}_all.deb"
