# -*- coding: utf-8 -*-
"""bootimg — swap the kernel Image inside an Android boot.img.

Module form of tools/repack-boot.py (same logic, keep in sync).
Pure stdlib. Raises BootImgError on any inconsistency and never
writes a partially-verified output.

Layout (AOSP boot_img_hdr v0/v1/v2, verified against AOSP mkbootimg
and osm0sis/mkbootimg sources):

    header (1 page) | kernel | ramdisk | second |
    (v0: dt) | (v1+: recovery dtbo) | (v2: dtb)
"""
import struct

MAGIC = b'ANDROID!'
# arm64 Image header: 64 bytes, magic "ARM\x64" (0x644d5241 LE) @56.
ARM64_IMAGE_MAGIC = 0x644d5241
ARM64_MAGIC_OFF = 56
DTB_MAGIC = b'\xd0\x0d\xfe\xed'
RAMDISK_MAGICS = (b'\x1f\x8b', b'070701', b'\x28\xb5\x2f\xfd',
                  b'\xfd7zXZ\x00', b'BZh')
GZIP_MAGIC = b'\x1f\x8b'


class BootImgError(Exception):
    pass


# packed header field offsets (boot_img_hdr_v2, the superset layout)
F_KERNEL_SIZE = 8
F_KERNEL_ADDR = 12
F_RAMDISK_SIZE = 16
F_RAMDISK_ADDR = 20
F_SECOND_SIZE = 24
F_SECOND_ADDR = 28
F_TAGS_ADDR = 32
F_PAGE_SIZE = 36
F_VER_OR_DTSZ = 40
F_OS_VERSION = 44
F_NAME = 48
F_CMDLINE = 64
F_ID = 576
F_EXTRA_CMDLINE = 608
F_REC_DTBO_SIZE = 1632
F_REC_DTBO_OFF = 1636
F_HEADER_SIZE = 1644
F_DT_SIZE = 1648
F_DT_ADDR = 1652
HDR_V2_SIZE = 1660


def die(msg):
    raise BootImgError(msg)


def u32(b, off):
    return struct.unpack_from('<I', b, off)[0]


def u64(b, off):
    return struct.unpack_from('<Q', b, off)[0]


def align(v, p):
    return (v + p - 1) & ~(p - 1)


def kernel_kind(data):
    """Classify a kernel blob: 'arm64-image', 'gzip', 'unknown'."""
    if len(data) >= 60 and \
            struct.unpack_from('<I', data, ARM64_MAGIC_OFF)[0] == \
            ARM64_IMAGE_MAGIC:
        return 'arm64-image'
    if data[:2] == GZIP_MAGIC:
        return 'gzip'
    return 'unknown'


def is_arm64_image(data):
    return kernel_kind(data) == 'arm64-image'


def find_magic(data, limit=4096):
    off = 0
    while off + 8 <= min(len(data), limit):
        if data[off:off + 8] == MAGIC:
            return off
        off += 4
    return None


def parse_header(data):
    base = find_magic(data)
    if base is None:
        die('ANDROID! magic not found in first 4 KB — not a boot image')
    if base + HDR_V2_SIZE > len(data):
        die('image too small for a boot header')
    d = data[base:]
    h = {}
    h['base'] = base
    h['kernel_size'] = u32(d, F_KERNEL_SIZE)
    h['kernel_addr'] = u32(d, F_KERNEL_ADDR)
    h['ramdisk_size'] = u32(d, F_RAMDISK_SIZE)
    h['ramdisk_addr'] = u32(d, F_RAMDISK_ADDR)
    h['second_size'] = u32(d, F_SECOND_SIZE)
    h['second_addr'] = u32(d, F_SECOND_ADDR)
    h['tags_addr'] = u32(d, F_TAGS_ADDR)
    h['page_size'] = u32(d, F_PAGE_SIZE)
    raw = u32(d, F_VER_OR_DTSZ)
    h['dt_size_v0'] = raw if raw > 2 else 0
    h['ver'] = raw if raw <= 2 else 0
    h['os_version'] = u32(d, F_OS_VERSION)
    h['name'] = d[F_NAME:F_NAME + 16].rstrip(b'\x00')
    h['cmdline'] = (d[F_CMDLINE:F_ID].rstrip(b'\x00') +
                    d[F_EXTRA_CMDLINE:F_REC_DTBO_SIZE].rstrip(b'\x00'))
    if h['page_size'] < 2048 or h['page_size'] > 131072 or \
            h['page_size'] & (h['page_size'] - 1):
        die('implausible page size %d' % h['page_size'])
    if h['ver'] >= 1:
        h['rec_dtbo_size'] = u32(d, F_REC_DTBO_SIZE)
        h['rec_dtbo_off'] = u64(d, F_REC_DTBO_OFF)
        h['header_size'] = u32(d, F_HEADER_SIZE)
    else:
        h['rec_dtbo_size'] = 0
        h['rec_dtbo_off'] = 0
        h['header_size'] = 0
    if h['ver'] >= 2:
        h['dt_size'] = u32(d, F_DT_SIZE)
        h['dt_addr'] = u64(d, F_DT_ADDR)
    else:
        h['dt_size'] = 0
        h['dt_addr'] = 0
    return h


def section_offsets(h, kernel_size):
    """Standard AOSP layout, file offsets relative to magic position."""
    p = h['page_size']
    off_k = p
    off_r = off_k + align(kernel_size, p)
    off = off_r + align(h['ramdisk_size'], p)
    off_rec = None
    off_dtb = None
    if h['second_size']:
        off += align(h['second_size'], p)
    if h['ver'] == 0:
        if h['dt_size_v0']:
            off_dtb = off
    else:
        if h['rec_dtbo_size']:
            off_rec = off
            off += align(h['rec_dtbo_size'], p)
        if h['ver'] >= 2 and h['dt_size']:
            off_dtb = off
    return {'kernel': off_k, 'ramdisk': off_r,
            'second': off_r + align(h['ramdisk_size'], p),
            'rec': off_rec, 'dtb': off_dtb}


def magic_ok(data, off, kind):
    if off is None:
        return True
    if off >= len(data):
        return False
    head = data[off:off + 8]
    if kind == 'kernel':
        return kernel_kind(data[off:]) == 'arm64-image'
    if kind == 'dtb':
        return head.startswith(DTB_MAGIC)
    return any(head.startswith(m) for m in RAMDISK_MAGICS)


def parse_image(data):
    h = parse_header(data)
    o = section_offsets(h, h['kernel_size'])
    khead = data[o['kernel']:o['kernel'] + 128]
    kk = kernel_kind(khead)
    if kk == 'gzip':
        die('the ORIGINAL kernel in this boot image is gzip-compressed '
            '(zImage). This tool expects an uncompressed ARM64 Image. '
            'Aborting.')
    if kk != 'arm64-image':
        die('the ORIGINAL kernel in this boot image is not a '
            'recognizable ARM64 Image. Aborting.')
    for off, kind in ((o['kernel'], 'kernel'), (o['ramdisk'], 'ramdisk'),
                      (o['second'], 'dtb') if h['second_size']
                      else (None, ''),
                      (o['rec'], 'dtb') if o['rec'] is not None
                      else (None, ''),
                      (o['dtb'], 'dtb') if o['dtb'] is not None
                      else (None, '')):
        if kind and not magic_ok(data, off, kind):
            die('%s section magic mismatch at offset %d — layout not '
                'understood, aborting (no output written)' % (kind, off))

    def rd(off, size):
        return bytes(data[off:off + size])

    if o['ramdisk'] + h['ramdisk_size'] > len(data):
        die('ramdisk runs past end of image')
    dt_eff = h['dt_size_v0'] if h['ver'] == 0 else h['dt_size']
    sect = {
        'header': bytes(data[h['base']:h['base'] + h['page_size']]),
        'kernel': rd(o['kernel'], h['kernel_size']),
        'ramdisk': rd(o['ramdisk'], h['ramdisk_size']),
        'second': rd(o['second'], h['second_size']) if h['second_size']
                  else None,
        'rec': rd(o['rec'], h['rec_dtbo_size']) if o['rec'] is not None
               else None,
        'dtb': rd(o['dtb'], dt_eff) if o['dtb'] is not None else None,
    }
    return h, sect, o


def build(h, sect, new_kernel, out_path):
    p = h['page_size']
    img = bytearray(sect['header'])

    def put(blob):
        nonlocal img
        pad = align(len(img), p)
        img += b'\x00' * (pad - len(img))
        img += blob

    put(new_kernel)
    put(sect['ramdisk'])
    if sect['second'] is not None:
        put(sect['second'])
    if h['ver'] == 0:
        if sect['dtb'] is not None:
            put(sect['dtb'])
    else:
        if sect['rec'] is not None:
            put(sect['rec'])
        if h['ver'] >= 2 and sect['dtb'] is not None:
            put(sect['dtb'])
    pad = align(len(img), p)
    img += b'\x00' * (pad - len(img))

    # header field updates (inside the first page)
    struct.pack_into('<I', img, h['base'] + F_KERNEL_SIZE, len(new_kernel))
    if h['ver'] >= 1 and h['rec_dtbo_size']:
        o = section_offsets(h, len(new_kernel))
        struct.pack_into('<Q', img, h['base'] + F_REC_DTBO_OFF, o['rec'])

    img = bytes(img)

    # ---------------- self-verify the rebuilt image
    h2, sect2, o2 = parse_image(img)
    if h2['kernel_size'] != len(new_kernel):
        die('internal error: kernel_size did not stick')
    if sect2['ramdisk'] != sect['ramdisk']:
        die('internal error: ramdisk changed')
    if sect2['second'] != sect['second']:
        die('internal error: second changed')
    if sect2['rec'] != sect['rec']:
        die('internal error: recovery dtbo changed')
    if sect2['dtb'] != sect['dtb']:
        die('internal error: dtb changed')
    if sect2['kernel'] != new_kernel:
        die('internal error: kernel mismatch')
    a, b = sect['header'], img[:h['page_size']]
    skip = set(range(h['base'] + F_KERNEL_SIZE,
                     h['base'] + F_KERNEL_SIZE + 4))
    if h['ver'] >= 1 and h['rec_dtbo_size']:
        skip.update(range(h['base'] + F_REC_DTBO_OFF,
                          h['base'] + F_REC_DTBO_OFF + 8))
    for i in range(h['page_size']):
        if i in skip:
            continue
        if a[i] != b[i]:
            die('internal error: header byte %d changed' % i)
    with open(out_path, 'wb') as f:
        f.write(img)
    return len(img)


def repack(src_path, new_image_path, out_path, log=None):
    """High-level: swap the kernel Image. Returns output size (bytes).
    Raises BootImgError without writing on any failure."""
    log = log or (lambda m: None)
    with open(src_path, 'rb') as f:
        data = f.read()
    with open(new_image_path, 'rb') as f:
        new_kernel = f.read()

    if not is_arm64_image(new_kernel):
        die('new Image is not a valid ARM64 kernel Image '
            '(missing the "ARM\\x64" magic at offset 56) — '
            'is this the output of "make Image"?')

    h, sect, o = parse_image(data)
    log('boot header  : v%d, page %d' % (h['ver'], h['page_size']))
    log('image name   : %r' % h['name'].decode('utf-8', 'replace'))
    log('cmdline      : %r'
        % h['cmdline'].decode('utf-8', 'replace')[:200])
    log('kernel       : %d bytes -> NEW %d bytes'
        % (h['kernel_size'], len(new_kernel)))
    log('ramdisk      : %d bytes (preserved)' % h['ramdisk_size'])
    if h['second_size']:
        log('second/dt    : %d bytes (preserved)' % h['second_size'])
    if h['rec_dtbo_size']:
        log('recovery dtbo: %d bytes (preserved)' % h['rec_dtbo_size'])
    if h['dt_size'] or (h['ver'] == 0 and h['dt_size_v0']):
        log('dtb/dt       : %d bytes (preserved)'
            % (h['dt_size'] or h['dt_size_v0']))

    size = build(h, sect, new_kernel, out_path)
    log('repack OK    : %d bytes, self-verified' % size)
    return size
