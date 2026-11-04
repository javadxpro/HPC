# Droidian Vayu kernel 4.14.355 (LTS) — rebuilt & re-verified

Rebuilt 2026-11-04 after a correctness fix:
1. All `.inst` encodings replaced with keystone-engine verified values
   (previous build shipped smc #0 = 0xd4000001 = UNDEFINED instruction;
   correct = 0xd4000003. VHE regs fixed as well).
2. The first 355 build silently dropped the qcom SCM driver (orphan
   symbol-less scm.o). Now verified: scm_call/scm_call2 linked in
   vmlinux with the correct smc #0 bytes (23 sites in scm.o).

Source: `berbascum/linux-android-xiaomi-vayu-l4v3nx @ droidian = 4c4a03ef3`
(zig cross toolchain, droidian defconfig, COMPAT_VDSO off).

Files: Image (14,185,336 B), sm8150*.dtb, vayu-sm8150-overlay.dtbo,
System.map. (vmlinux 109 MB kept in sandbox build dir.)

Patch set: toolchain/kernel-patches/droidian-zig-asm-compat.patch
