# Fresh-sandbox rebuild (exact commands)

```sh
# 1. zig (venv due to PEP 668)
python3 -m venv /home/user/zigenv
/home/user/zigenv/bin/pip install ziglang==0.17.0
# NOTE: wrappers hardcode
#   /home/user/zigenv/lib/python3.11/site-packages/ziglang/zig
#   (python3.11 venv; adjust ZIG= in bin/cc-dispatch + bin/ld-dispatch if different)

# 2. toolchain
git clone https://github.com/javadxpro/hpc-toolchain /home/user/hpc-toolchain
sh /home/user/hpc-toolchain/restore.sh

# 3. kernel
git clone https://github.com/droidian/linux-android-xiaomi-vayu-l4v3nx /home/user/kernel
cd /home/user/kernel
git apply /home/user/hpc-toolchain/kernel-patches/droidian-zig-asm-compat.patch

# 4. build dir + config
mkdir -p /home/user/kernel-build/out/KERNEL_OBJ
cp /home/user/hpc-toolchain/docs/vayu-lts-4.14.355.config /home/user/kernel-build/.config
ln -sf .config /home/user/kernel-build/out/KERNEL_OBJ/.config

# 5. build
export CROSS_COMPILE=/home/user/toolchain/bin/aarch64-none-elf-
make ARCH=arm64 O=/home/user/kernel-build -j2
# expect ~30-60 min on 2 CPU; BUILD-RC=0
```

Artifacts:
```
/home/user/kernel-build/vmlinux                      108,609,160 B
/home/user/kernel-build/arch/arm64/boot/Image        14,185,336 B
/home/user/kernel-build/arch/arm64/boot/dts/qcom/
    sm8150.dtb sm8150-v2.dtb sm8150p.dtb sm8150p-v2.dtb
    vayu-sm8150-overlay.dtbo
/home/user/kernel-build/System.map
```
