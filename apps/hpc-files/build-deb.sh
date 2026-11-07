#!/bin/bash
# Build the hpc-files .deb (no root needed).
set -e
cd "$(dirname "$0")"
V=0.1.0
T=hpc-files_${V}_all
rm -rf build/$T
mkdir -p build/$T/DEBIAN
mkdir -p build/$T/usr/lib/python3/dist-packages
mkdir -p build/$T/usr/bin
mkdir -p build/$T/usr/share/applications
mkdir -p build/$T/usr/share/icons/hicolor/scalable/apps

cp -r hpc_files build/$T/usr/lib/python3/dist-packages/
rm -rf build/$T/usr/lib/python3/dist-packages/hpc_files/__pycache__
cp hpc-files build/$T/usr/bin/hpc-files
chmod 755 build/$T/usr/bin/hpc-files
cp hpc-files.desktop build/$T/usr/share/applications/
cp data/hpc-files.svg build/$T/usr/share/icons/hicolor/scalable/apps/

cat > build/$T/DEBIAN/control <<EOF
Package: hpc-files
Version: $V
Section: utils
Priority: optional
Architecture: all
Depends: python3, python3-gi, gir1.2-gtk-4.0, gir1.2-gdkpixbuf-4.0
Maintainer: javadxpro
Description: Powerful dual-pane file manager & archive tool for Linux (HPC)
 Dual-pane browsing, archive manager (zip/tar/7z/rar, passwords, browse
 inside archives), trash with restore, favorites, recents, disk usage,
 bulk rename, chmod, checksums (md5/sha1/sha256), text & image preview,
 open in terminal, search/sort/filter, dark theme, progress + cancel.
EOF

dpkg-deb --build --root-owner-group build/$T
echo "built: build/hpc-files_${V}_all.deb"
