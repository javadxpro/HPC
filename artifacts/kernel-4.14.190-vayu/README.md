# Droidian Vayu kernel 4.14.190 — rebuilt from source (device-matching)

Built 2026-11-04, **relinked 2026-11-05 (v2 — boot-complete)** (HPC sandbox,
zig cross toolchain) from `droidian-vayu/linux-halium-xiaomi-vayu @ droidian
= d01cee634` with `vayu_lastworking_defconfig` (COMPAT_VDSO off — no ARM32
toolchain; CIFS off — it references `wcslen`, which does not exist in 4.14
and cannot link with `--no-undefined`; the phone never needs SMB client).

Matches the kernel the phone currently runs: `uname -r` =
`4.14-190-xiaomi-vayu`, dtb `model=VAYU`, `compatible=qcom,sm8150`.

## v2 (2026-11-05): the missing-drivers defect, fixed
The v1 Image (13,007,460 B) was boot-incomplete: the linker wrapper
reordered `--whole-archive built-in.o --no-whole-archive` and lld silently
dropped all self-contained built-in drivers. Fixed in
`toolchain/bin/aarch64-none-elf-ld` (original flag/file order preserved)
and relinked. Verified:

- System.map: 175,157 symbols. ufshcd ×442, ufs_ ×286, ext4 ×1753,
  f2fs_ ×1272, qca_wlan ×16 + wlan_ (WLAN built-in), xiaomi ×32,
  qcom_pdc ×15, msm_drm ×23, spmi ×250, pmic_ ×219, usb_ ×2207,
  netdev_ ×382, start_kernel present.
- Raw-byte controls in Image: "ufshcd" ×70, "ext4" ×89, "qca" ×40,
  "xiaomi" ×14, "msm_drm" ×10.
- modpost clean; Image + all 5 dtbs regenerated.

## Files
| file | size | note |
|---|---|---|
| Image | 61,335,144 B | bootable ABL image (vmlinux→Image) |
| sm8150.dtb / sm8150-v2.dtb / sm8150p.dtb / sm8150p-v2.dtb | board DTBs |
| vayu-sm8150-overlay.dtbo | Droidian board overlay |
| System.map | 7,545,703 B | symbol table |

`vmlinux` (with debug) stays in the sandbox build dir, not committed.

## Verification performed (v1, still valid)
- All `.inst` encodings keystone-engine verified (smc #0 = 0xd4000003,
  hvc #0 = 0xd4000002, VHE regs vpidr/vttbr/vbar/ttbr0_el2).
- Final pass: `SMCCC_SMC_INST` in include/linux/arm-smccc.h corrected
  from 0xd4000001 (which is `hvc #1`!) to 0xd4000003 — the CPU errata
  path (cpu_errata.o) now emits smc #0. Full-tree audit: the byte
  sequence 0xd4000001 does not occur in any .text section of any
  object (only in data/relocation tables, as elsewhere in kernels).
- Byte-level check of every patched object in the build (little-endian
  opcode present in the compiled .o): smccc-call, bpi, head, hyp-stub,
  hyp-init, hyp-entry, kvm/hyp, qcom scm — all OK.
- No raw `smc #0` / VHE mnemonics remain in any compiled path.
- vmlinux: ET_DYN AArch64, entry 0xffffff8008080000, start_kernel present.

## Source patch set
`toolchain/kernel-patches/droidian-zig-asm-compat-4.14.190.patch`
(zig assembler compatibility; applies to the droidian tree above.)
Linker wrapper: `toolchain/bin/aarch64-none-elf-ld` (fixed 2026-11-05).

## How to flash (on-device, from a root shell)
1. Pull the current `boot.img` (e.g. from /dev/block by-partition-name, or
   from the last Droidian OTA), unpack it (mkbootimg --unpack).
2. Replace `zImage`/`Image` with this `Image`; keep the existing ramdisk
   and `vayu-sm8150-overlay.dtbo` (or swap in this dtbo — same name).
3. Repack and flash: `flash boot <repacked.img>` (fastboot) or
   `dd` from recovery. Test with a non-destructive `fastboot boot` first.
