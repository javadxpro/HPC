# Droidian Vayu kernel 4.14.190 — built artifacts (device-matching)

Built 2026-11-05 (HPC sandbox, zig cross toolchain) from
`droidian-vayu/linux-halium-xiaomi-vayu @ droidian = d01cee634`
with `vayu_lastworking_defconfig` (COMPAT_VDSO off — no ARM32 toolchain).

This matches the kernel the Vayu Droidian device currently runs:
`uname -r` = `4.14-190-xiaomi-vayu` (model VAYU, qcom,sm8150).

Files:
  Image                 13,007,460 B  (bootable, ABL layout)
  sm8150*.dtb           board device trees
  vayu-sm8150-overlay.dtbo  droidian board overlay
  System.map            symbol table
  (vmlinux 95 MB kept in the build dir, not committed)

Kernel source patch set (zig assembler compat, keystone-verified
encodings): toolchain/kernel-patches/droidian-zig-asm-compat-4.14.190.patch
Rebuild: toolchain/docs/REBUILD.md
