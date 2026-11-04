# HPC cross toolchain (zig-based) — Droidian Vayu kernel 4.14.355

A complete userland cross toolchain that builds the Droidian
`linux-android-xiaomi-vayu-l4v3nx` kernel (4.14.355) for the Xiaomi 11
Lite 5G NE (SM8150 / Adreno 620) **without any GNU aarch64 binutils or
binutils-gold** — everything runs on:

- **zig 0.17.0** (pip `ziglang` package) — clang 18.1 + lld 18.1 inside
- **host GNU binutils 2.40** (x86-only ld, but nm/ar/readelf/size/strip
  read aarch64 ELFs fine; objcopy handles ihex)
- **python3**

Verified: full `make ARCH=arm64 O=... -j2` → vmlinux (108.6 MB,
start_kernel at ffffff8008a0ff40) + Image (14,185,336 B) + all 5
qcom dtbs (sm8150, sm8150-v2, sm8150p, sm8150p-v2,
vayu-sm8150-overlay.dtbo) + System.map. Config is 100% built-in (0 =m).

## Layout

```
bin/                    all wrappers (aarch64-none-elf-*) + helpers
  cc-dispatch           C/C++/asm compiler (zig cc), GCC-10.5 banner
  ld-dispatch           linker (zig cc -nostdlib), LLD banner, -r support
  objcopy-dispatch      zig objcopy + host-objcopy ihex/-R fallbacks
  hpc-objcopy-bin       python ELF64 -> binary dumper (-R/--gap-fill)
  hpc-extract-cert      python cert->DER (empty input => empty output)
  hpc-probe.o           trivial aarch64 obj used by ld flag probes
  bc, bc-py             bc replacements (kernel timeconst/Makefile pipe)
  aarch64-none-elf-*    cross name aliases (gcc,cc,c++,as,ld,nm,ar,...)
kernel-patches/
  droidian-zig-asm-compat.patch   8-file patch: smc/VHE .inst encodings
                                  + extract-cert C stub (required for zig)
shims/                  /usr/local/bin shims (bc, bc-py, pkg-config)
docs/REBUILD.md         exact commands for a fresh sandbox
```

## One-time setup (fresh sandbox)

```sh
pip install ziglang==0.17.0            # into a venv if PEP 668
# wrappers hardcode: /home/user/zigenv/lib/python3.11/site-packages/ziglang/zig
#   (adjust ZIG= line in cc-dispatch/ld-dispatch if the path differs)
git clone https://github.com/javadxpro/hpc-toolchain /home/user/hpc-toolchain
sh /home/user/hpc-toolchain/restore.sh # recreates /home/user/toolchain + shims
```

## Kernel build

```sh
git clone https://github.com/droidian/linux-android-xiaomi-vayu-l4v3nx /home/user/kernel
cd /home/user/kernel
git apply /home/user/hpc-toolchain/kernel-patches/droidian-zig-asm-compat.patch
mkdir -p /home/user/kernel-build/out/KERNEL_OBJ
cp /path/to/vayu_defconfig /home/user/kernel-build/.config
# (known-good config + LTO_NONE + COMPAT_VDSO off + SYSTEM_TRUSTED_KEYS="")
ln -sf .config /home/user/kernel-build/out/KERNEL_OBJ/.config
export CROSS_COMPILE=/home/user/toolchain/bin/aarch64-none-elf-
make ARCH=arm64 O=/home/user/kernel-build -j2
```

Artifacts: `vmlinux`, `arch/arm64/boot/Image`,
`arch/arm64/boot/dts/qcom/*.dtb{,o}`, `System.map`.

## What the wrappers do (empirical, zig 0.17 / LLVM 18.1)

cc-dispatch:
- `-v`/`--version` with no inputs → GCC 10.5 banner (kernel greps for
  "clang version"; must NOT see it)
- `-dumpmachine` → aarch64-unknown-linux-gnu
- drops `-fno-pic` (zig a64 requires PIC), bare `-Werror` (QCOM techpack),
  `-fmacro-prefix-map=*=*` (empty target breaks zig path handling)
- `-mcpu/-mtune cortex*|*.*` → `a64fx` (LSE+RCpc superset-safe for Kryo470)
- `-fno-sanitize=undefined` (zig default is ubsan; kernel has no runtime)
- **`-D` values containing quotes → `-include` generated header** (zig's -D
  parser breaks on embedded quotes at macro expansion time; header must
  persist — the depfile references it)
- `-S` compiles: strip depflags from the cc invocation (zig then skips
  the .s output) and synthesize a fixdep-compatible .d
- `-c` compiles: keep `-Wp,-MD` (zig writes the depfile natively)

ld-dispatch:
- version iff `-v/-V/--version` with only droppable flags; otherwise a
  trivial real link probe of hpc-probe.o (kernel `ld-option` truth —
  answering version to `ld <flag> -v` poisons LDFLAGS with flags the
  real link rejects later)
- drops bfd-only: -X -pie -EL -EB -nostdlib -maarch64* --fix-cortex-a53
  --no-apply-dynamic-relocs **--pack-dyn-relocs** (BFD-only opt, static
  kernel image)
- `-r` → zig cc driver flag (`-Wl,-r` is on zig's reject list)
- `-shared` → driver flag; `-z/-T/-L/-l/-I` → `-Wl,x,val`; positional
  non-object → `-Wl,-T,`
- zig cc -Wl allowlist: accepts -T -L -l -z --build-id --no-undefined;
  rejects -r -pie -X --no-warn-rwx-segments -nostdlib

objcopy-dispatch:
- `-I/-O ihex` → host /usr/bin/objcopy (zig objcopy lacks ihex)
- `-R/--remove-section` → hpc-objcopy-bin (zig objcopy can't remove
  sections; python dumper implements GNU `objcopy -O binary` semantics:
  SHF_ALLOC sections only, gap-fill, NOBITS = gap)
- `-S` dropped; no remaining transform → byte copy
