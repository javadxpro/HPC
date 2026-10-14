#!/usr/bin/env python3
"""Pack hamedis recovery v2 for vayu with the EXACT QCOM ABL (EDK2) v2 layout.

Ground truth:
  - QcomModulePkg/Include/Library/BootImage.h (Project-Aloha):
      struct boot_img_hdr (1632 B, used for v0/v1/v2):
        0: magic[8]
        8: kernel_size      12: kernel_addr
        16: ramdisk_size    20: ramdisk_addr
        24: second_size     28: second_addr
        32: tags_addr       36: page_size
        40: header_version  44: os_version
        48: name[16]        64: cmdline[512]
        576: id[8]          608: extra_cmdline[1024]
      v1 ext @1632: recovery_dtbo_size(u32), recovery_dtbo_offset(u64), header_size(u32)
      v2 ext @1648: dtb_size(u32), dtb_addr(u64)
      ABL validates header_size == 1632+16+12 == 1660 for v2.
  - Image layout (v2, all page-aligned, sequential):
      header(1 page) | kernel | ramdisk | second | recovery_dtbo | dtb.img
  - OF R12.0 device tree (momenabdulrazek/device_xiaomi_vayu-ofox BoardConfig.mk):
      --base 0 --pagesize 4096 --kernel_offset 0x8000 --ramdisk_offset 0x1000000
      --second_offset 0 --tags_offset 0x100 --dtb_offset 0x1f00000 --header_version 2
      kernel = prebuilt/Image.gz-dtb (gzip kernel package + appended dtbs)
"""
import struct, sys, hashlib

PAGE = 4096
TARGET = 134217728

def align(x, a=PAGE):
    return (x + a - 1) // a * a

def rd(p):
    return open(p, "rb").read()

kernel = rd("of-kernel.gz-dtb")
ramdisk = rd("tmp-ramdisk.gz")
dtbo = rd("of-dtbo.img")
dtb = rd("stock-dtb.img")

assert kernel[:2] == b"\x1f\x8b", "kernel must be a gzip package"
assert ramdisk[:2] == b"\x1f\x8b", "ramdisk must be gzip"
assert dtb[:4] == b"\xd0\x0d\xfe\xed", "dtb blob must start with DTB magic"

CMDLINE = ("ttyMSM0,115200n8 earlycon=msm_geni_serial,0xa90000 "
           "androidboot.hardware=qcom androidboot.console=ttyMSM0 "
           "androidboot.memcg=1 lpm_levels.sleep_disabled=1 "
           "video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 "
           "service_locator.enable=1 swiotlb=2048 "
           "androidboot.usbcontroller=a600000.dwc3 androidboot.selinux=permissive")
assert len(CMDLINE) < 512

# sequential page-aligned layout
o = PAGE
k_off = o; o = align(o + len(kernel))
r_off = o; o = align(o + len(ramdisk))
s_off = o                                   # second_size = 0
d_off = o; o = align(o + len(dtbo))         # recovery_dtbo
t_off = o; o = align(o + len(dtb))          # dtb
print(f"kernel  @ {k_off:#x} ({len(kernel)})")
print(f"ramdisk @ {r_off:#x} ({len(ramdisk)})")
print(f"dtbo    @ {d_off:#x} ({len(dtbo)})")
print(f"dtb     @ {t_off:#x} ({len(dtb)})")
print(f"content end {o:#x} ({o})")

hdr = bytearray(PAGE)
hdr[0:8] = b"ANDROID!"
struct.pack_into("<I", hdr, 8, len(kernel))
struct.pack_into("<I", hdr, 12, 0x8000)          # kernel_addr (OF --kernel_offset)
struct.pack_into("<I", hdr, 16, len(ramdisk))
struct.pack_into("<I", hdr, 20, 0x01000000)      # ramdisk_addr (OF --ramdisk_offset)
struct.pack_into("<I", hdr, 24, 0)               # second_size
struct.pack_into("<I", hdr, 28, 0)               # second_addr
struct.pack_into("<I", hdr, 32, 0x100)           # tags_addr (OF --tags_offset)
struct.pack_into("<I", hdr, 36, PAGE)            # page_size
struct.pack_into("<I", hdr, 40, 2)               # header_version
struct.pack_into("<I", hdr, 44, 0)               # os_version
hdr[48:52] = b"vayu"                              # name[16]
hdr[64:64+len(CMDLINE)+1] = CMDLINE.encode() + b"\x00"
# id[8]@576, extra_cmdline[1024]@608 stay zero
struct.pack_into("<I", hdr, 1632, len(dtbo))     # recovery_dtbo_size
struct.pack_into("<Q", hdr, 1636, d_off)         # recovery_dtbo_offset
struct.pack_into("<I", hdr, 1644, 1660)          # header_size (validated by ABL)
struct.pack_into("<I", hdr, 1648, len(dtb))      # dtb_size
struct.pack_into("<Q", hdr, 1652, 0x1f00000)     # dtb_addr (OF --dtb_offset)

img = bytearray()
img += hdr
img += kernel
img += b"\x00" * (r_off - (PAGE + len(kernel)))
img += ramdisk
img += b"\x00" * (d_off - (r_off + len(ramdisk)))
img += dtbo
img += b"\x00" * (t_off - (d_off + len(dtbo)))
img += dtb
assert len(img) == t_off + len(dtb)
img += b"\x00" * (TARGET - len(img))
assert len(img) == TARGET

open("hamedis-recovery-v2.img", "wb").write(bytes(img))
print("wrote hamedis-recovery-v2.img", len(img), "sha256",
      hashlib.sha256(bytes(img)).hexdigest())
