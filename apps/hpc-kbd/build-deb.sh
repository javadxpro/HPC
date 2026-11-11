#!/bin/sh
# Build hpc-kbd.deb (Architecture: all — pure python, uinput backend).
set -e
cd "$(dirname "$0")"
VER=0.2.0
PKG=hpc-kbd
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/$PKG" \
         "$STAGE/usr/lib/python3/dist-packages/hpc_kbd" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/polkit-1/rules.d"

cp packaging/control "$STAGE/DEBIAN/control"

# launcher
cat > "$STAGE/usr/bin/hpc-kbd" <<'LNCH'
#!/bin/sh
exec /usr/bin/python3 /usr/share/hpc-kbd/main.py "$@"
LNCH
chmod 755 "$STAGE/usr/bin/hpc-kbd"

# app
cp main.py "$STAGE/usr/share/hpc-kbd/"

# python package (uinput backend + layouts)
cp hpc_kbd/uinput_kbd.py hpc_kbd/layouts.py "$STAGE/usr/lib/python3/dist-packages/hpc_kbd/"
cp hpc_kbd/__init__.py "$STAGE/usr/lib/python3/dist-packages/hpc_kbd/"

# desktop entry + polkit rule (passwordless pkexec for /usr/bin/hpc-kbd)
cp packaging/hpc-kbd.desktop "$STAGE/usr/share/applications/"
cp packaging/49-hpc-kbd.rules "$STAGE/usr/share/polkit-1/rules.d/"

chmod 755 "$STAGE/DEBIAN"
dpkg-deb --build --root-owner-group "$STAGE" "hpc-kbd_${VER}_all.deb"
echo "built: $(pwd)/${PKG}_${VER}_all.deb"
