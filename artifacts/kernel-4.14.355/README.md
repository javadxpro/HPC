# Droidian Vayu kernel 4.14.355 — built artifacts

Built 2026-11-04 (HPC sandbox, zig cross toolchain) from
`berbascum/linux-android-xiaomi-vayu-l4v3nx @ droidian = 4c4a03ef3`
(the Droidian lts tree; same HEAD as the droidian channel).

Files:
  Image                 14,185,336 B  (bootable, ABL layout)
  sm8150*.dtb           board device trees (vayu board-id 47 0 = sm8150)
  vayu-sm8150-overlay.dtbo  droidian board overlay
  System.map            symbol table
  (vmlinux 109 MB kept in the build dir, not committed)

Config: toolchain/docs/vayu-lts-4.14.355.config (100% built-in).
Rebuild: toolchain/docs/REBUILD.md (repo source: use the 4c4a03ef3 tree).
