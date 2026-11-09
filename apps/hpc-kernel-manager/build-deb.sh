#!/bin/bash
# Build the hpc-kernel-manager .deb (ARM64, Droidian). No root needed.
set -e
cd "$(dirname "$0")"
V=0.1.7
T=hpc-kernel-manager_${V}_arm64

rm -rf build/$T
mkdir -p build/$T/DEBIAN
mkdir -p build/$T/usr/lib/python3/dist-packages
mkdir -p build/$T/usr/bin
mkdir -p build/$T/usr/share/applications
mkdir -p build/$T/usr/share/icons/hicolor/scalable/apps

cp -r hpc_km build/$T/usr/lib/python3/dist-packages/
rm -rf build/$T/usr/lib/python3/dist-packages/hpc_km/__pycache__

cp hpc-kernel-manager build/$T/usr/bin/hpc-kernel-manager
chmod 755 build/$T/usr/bin/hpc-kernel-manager

cp hpc-kernel-manager.desktop build/$T/usr/share/applications/
cp data/hpc-kernel-manager.svg build/$T/usr/share/icons/hicolor/scalable/apps/

cat > build/$T/DEBIAN/control <<EOF
Package: hpc-kernel-manager
Version: $V
Section: utils
Priority: optional
Architecture: arm64
Depends: python3, python3-gi, gir1.2-gtk-4.0
Maintainer: javadxpro
Description: A/B kernel flash manager for Droidian (HPC)
 GTK4 manager to flash HPC kernels (4.14.355 LTS / 4.14.190) on
 A/B-slot devices: backs up the current boot partition, downloads the
 kernel Image (size+magic verified), repacks the boot image (kernel
 swap, self-verified, ramdisk/dtb/cmdline preserved), dd-writes it to
 the OTHER slot and puts it in boot-control attempt mode so the ABL
 automatically rolls back if the new kernel fails to boot. Restore and
 mark-successful included. Run as root: sudo hpc-kernel-manager.
EOF

dpkg-deb --build --root-owner-group build/$T >/dev/null
mv build/$T.deb "hpc-kernel-manager_${V}_arm64.deb"
rm -rf build
echo "built: hpc-kernel-manager_${V}_arm64.deb"
