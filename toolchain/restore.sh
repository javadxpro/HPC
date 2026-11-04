#!/bin/sh
# Recreate /home/user/toolchain + /usr/local/bin shims from this repo.
set -e
R="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /home/user/toolchain/bin
cp -f "$R"/bin/* /home/user/toolchain/bin/
chmod +x /home/user/toolchain/bin/*
cp -f "$R"/hpc-probe.o /home/user/toolchain/hpc-probe.o
# /usr/local/bin shims (world-writable, wiped by sandbox resets)
if [ -w /usr/local/bin ]; then
  for s in bc bc-py; do ln -sf /home/user/toolchain/bin/$s /usr/local/bin/$s; done
  ln -sf /home/user/toolchain/shims/pkg-config /usr/local/bin/pkg-config 2>/dev/null || true
fi
echo "hpc-toolchain restored."
