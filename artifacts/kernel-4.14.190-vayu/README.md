# Droidian Vayu kernel 4.14.190 — rebuilt from source (device-matching)

Built 2026-11-04 (HPC sandbox, zig cross toolchain) from
`droidian-vayu/linux-halium-xiaomi-vayu @ droidian = d01cee634`
with `vayu_lastworking_defconfig` (COMPAT_VDSO off — no ARM32 toolchain).

Matches the kernel the phone currently runs: `uname -r` =
`4.14-190-xiaomi-vayu`, dtb `model=VAYU`, `compatible=qcom,sm8150`.

## Files
| file | size | note |
|---|---|---|
| Image | 13,007,460 B | bootable ABL image (vmlinux→Image) |
| sm8150.dtb / sm8150-v2.dtb / sm8150p.dtb / sm8150p-v2.dtb | board DTBs |
| vayu-sm8150-overlay.dtbo | Droidian board overlay |
| System.map | symbol table |

`vmlinux` (95 MB, with debug) stays in the sandbox build dir, not committed.

## Verification performed
- All `.inst` encodings keystone-engine verified (smc #0 = 0xd4000003,
  hvc #0 = 0xd4000002, VHE regs vpidr/vttbr/vbar/ttbr0_el2).
- Byte-level check of every patched object in the build (little-endian
  opcode present in the compiled .o): smccc-call, bpi, head, hyp-stub,
  hyp-init, hyp-entry, kvm/hyp, qcom scm — all OK.
- No raw `smc #0` / VHE mnemonics remain in any compiled path.
- vmlinux: ET_DYN AArch64, entry 0xffffff8008080000, start_kernel present.

## Source patch set
`toolchain/kernel-patches/droidian-zig-asm-compat-4.14.190.patch`
(zig assembler compatibility; applies to the droidian tree above.)

## How to flash (on-device, from a root shell)
1. Pull the current `boot.img` (e.g. from /dev/block by-partition-name, or
   from the last Droidian OTA), unpack it (mkbootimg --unpack).
2. Replace `zImage`/`Image` with this `Image`; keep the existing ramdisk
   and `vayu-sm8150-overlay.dtbo` (or swap in this dtbo — same name).
3. Repack and flash: `flash boot <repacked.img>` (fastboot) or
   `dd` from recovery. Test with a non-destructive `fastboot boot` first.
