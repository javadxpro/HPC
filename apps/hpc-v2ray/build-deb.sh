#!/bin/bash
# Build the hpc-v2ray .deb (ARM64 — bundles the official signed
# v2ray core v5.53.0 + geo data). No root needed.
set -e
cd "$(dirname "$0")"
V=0.1.0
T=hpc-v2ray_${V}_arm64
DIST="${DIST_DIR:-/home/user/v2ray-dist}"
V2RAY_ZIP="$DIST/v2ray-linux-arm64-v8a.zip"

# allow building from repo checkout (no /home/user paths)
[ -f "$V2RAY_ZIP" ] || V2RAY_ZIP="$(dirname "$0")/v2ray-linux-arm64-v8a.zip"
[ -f "$V2RAY_ZIP" ] || { echo "missing $V2RAY_ZIP — clone github.com/v2ray/dist first"; exit 1; }

rm -rf build/$T
mkdir -p build/$T/DEBIAN
mkdir -p build/$T/usr/lib/python3/dist-packages
mkdir -p build/$T/usr/bin
mkdir -p build/$T/usr/share/applications
mkdir -p build/$T/usr/share/icons/hicolor/scalable/apps
mkdir -p build/$T/usr/lib/hpc-v2ray

# python app
cp -r hpc_v2ray build/$T/usr/lib/python3/dist-packages/
rm -rf build/$T/usr/lib/python3/dist-packages/hpc_v2ray/__pycache__

# launcher
cp hpc-v2ray build/$T/usr/bin/hpc-v2ray
chmod 755 build/$T/usr/bin/hpc-v2ray

# desktop + icon
cp hpc-v2ray.desktop build/$T/usr/share/applications/
cp data/hpc-v2ray.svg build/$T/usr/share/icons/hicolor/scalable/apps/

# official signed v2ray core (arm64) + geo data
WORK=$(mktemp -d)
unzip -q "$V2RAY_ZIP" -d "$WORK"
# locate the inner dir (v2ray-linux-arm64-v8a/)
INNER=$(find "$WORK" -maxdepth 2 -type f -name v2ray | head -1)
INNER=$(dirname "$INNER")
cp "$INNER/v2ray" build/$T/usr/lib/hpc-v2ray/v2ray
chmod 755 build/$T/usr/lib/hpc-v2ray/v2ray
for gf in geoip.dat geosite.dat geoip-only-cn-private.dat; do
  [ -f "$INNER/$gf" ] && cp "$INNER/$gf" build/$T/usr/lib/hpc-v2ray/
done
rm -rf "$WORK"

cat > build/$T/DEBIAN/control <<EOF
Package: hpc-v2ray
Version: $V
Section: net
Priority: optional
Architecture: arm64
Depends: python3, python3-gi, gir1.2-gtk-4.0
Maintainer: javadxpro
Description: VLESS proxy client for Linux (V2Ray core v5.53.0, HPC)
 GTK4 VLESS client with profile/subscription management, vless+tcp/ws/
 grpc/kcp/reality transports, local SOCKS5+HTTP inbounds, optional
 system-wide TUN mode, Iran-domain bypass routing, geoip/geosite rules.
 Bundles the official signed V2Fly v2ray core (linux-arm64-v8a).
EOF

dpkg-deb --build --root-owner-group build/$T >/dev/null
mv build/$T.deb "hpc-v2ray_${V}_arm64.deb"
rm -rf build
echo "built: hpc-v2ray_${V}_arm64.deb"
