# HPC — Hamedis Performance Core (Linux / Droidian)

Performance platform for the **Xiaomi 11 Lite 5G NE (Vayu, SM8150,
Adreno 620)** running **Droidian** (Linux on ARM). Kernel + native
Linux applications.

> **History:** the Android (Magisk) version of this project ended at
> **v1.12.2** — preserved at tag **`v1.12.2-final`** and in git history.
> The device now runs Droidian (Linux), so this repository is the
> Linux continuation.

## Contents

```
toolchain/            zig-based aarch64 cross toolchain
  bin/                cc/ld/objcopy wrappers (zig 0.17 clang+lld 18.1)
  kernel-patches/     droidian .inst asm patches (zig assembler compat)
  docs/REBUILD.md     exact fresh-sandbox kernel build recipe
  docs/vayu-lts-4.14.355.config   known-good kernel config (100% built-in)
apps/                 native Droidian applications (.deb) — in progress
docs/kernel_platform.md   kernel platform mission & design notes
```

## Kernel build (Droidian l4v3nx 4.14.355)

Full recipe: `toolchain/docs/REBUILD.md`. Proven build output:

```
vmlinux  108,609,160 B   (entry 0xffffff8008080000, start_kernel verified)
Image    14,185,336 B    (bootable, ABL layout)
dtbs     sm8150, sm8150-v2, sm8150p, sm8150p-v2, vayu-sm8150-overlay.dtbo
```

No GNU aarch64 binutils required — everything runs on zig + host x86
binutils (nm/ar/readelf) + python3.

## Status

- [x] Cross toolchain (full kernel build, verified twice)
- [x] Kernel patches for the zig assembler (smc/VHE `.inst` encodings)
- [ ] hpc-kbd — replacement on-screen keyboard for phosh (GTK4, .deb)
- [ ] kgsl devfreq governor work (Adreno 620, base 600 / max 675 MHz)
- [ ] HPC kernel management suite for the 4.14.355 base
