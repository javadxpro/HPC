#!/bin/sh
# Recreate /home/user/toolchain + /usr/local/bin shims from this repo.
set -e
R="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /home/user/toolchain/bin
cp -f "$R"/bin/* /home/user/toolchain/bin/
chmod +x /home/user/toolchain/bin/*
cp -f "$R"/hpc-probe.o /home/user/toolchain/hpc-probe.o
# libcrypto/libssl dev symlinks (kernel links host scripts/extract-cert with -lcrypto)
mkdir -p /usr/local/lib
[ -e /usr/lib/x86_64-linux-gnu/libcrypto.so.3 ] && ln -sf /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/local/lib/libcrypto.so
[ -e /usr/lib/x86_64-linux-gnu/libssl.so.3 ] && ln -sf /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/local/lib/libssl.so
# /usr/local/bin shims (world-writable, wiped by sandbox resets)
if [ -w /usr/local/bin ]; then
  for s in bc bc-py; do ln -sf /home/user/toolchain/bin/$s /usr/local/bin/$s; done
  ln -sf /home/user/toolchain/shims/pkg-config /usr/local/bin/pkg-config 2>/dev/null || true
fi
echo "hpc-toolchain restored."
