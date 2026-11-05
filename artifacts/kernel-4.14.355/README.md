# Droidian Vayu kernel 4.14.355 (LTS) — rebuilt & verified complete

Rebuilt 2026-11-05 (v2). The previous artifact (920cc44) was **boot-incomplete**:
the linker wrapper reordered `--whole-archive built-in.o --no-whole-archive`
into `--whole-archive --no-whole-archive built-in.o`, which silently disabled
whole-archive. lld then fell back to reference-based archive extraction and
dropped every self-contained built-in driver (UFS, EXT4, WLAN, touch, PMIC,
SCM). No .ko modules could compensate — the phone could not mount its root.

**Root cause fixed in `toolchain/bin/aarch64-none-elf-ld`** (preserve the
original interleaving of `-Wl` flags and input files) and the kernel was
relinked. Verified:

- System.map: 119,495 symbols (was 39,425).
  ufshcd ×202, ufs_ ×241, ext4 ×1719, f2fs_ ×1296, qca_wlan ×16 + wlan_ ×1736,
  xiaomi_/touch ×26/48, qcom_pdc ×13, msm_drm ×17, spmi ×169, pmic_ ×203,
  scm_ ×177, usb_ ×1115, start_kernel present.
- Raw-byte controls in Image: "ufshcd" ×68, "ext4" ×88, "qca" ×30,
  "xiaomi" ×14, "msm_drm" ×10.
- modpost clean (0 errors), Image + all 5 dtbs regenerated.
- CONFIG_CC_STACKPROTECTOR_STRONG=y kept (matches hamedis_defconfig).
- COMPAT_VDSO=n, IKCONFIG off (O= build requirement).

Source: `berbascum/linux-android-xiaomi-vayu-l4v3nx @ droidian = 4c4a03ef3`
(13-file zig-asm-compat patch, full `arch/arm64/configs/vayu_defconfig`).

Files: Image (47,661,056 B), sm8150*.dtb, vayu-sm8150-overlay.dtbo,
System.map (4,872,956 B). vmlinux (409 MB) kept in the sandbox build dir.

Patch set: toolchain/kernel-patches/droidian-zig-asm-compat.patch
Linker wrapper: toolchain/bin/aarch64-none-elf-ld (fixed 2026-11-05).
