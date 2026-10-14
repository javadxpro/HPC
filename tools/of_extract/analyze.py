#!/usr/bin/env python3
"""Analyze an Android boot/recovery image (vayu).

Tries several known boot-image header layouts, scores each by sanity,
extracts the data regions of the best layout, lists the ramdisk cpio,
and writes to <outdir>:
  analysis.json  all layouts + scores + generic scans + cpio listing
  analysis.md    human-readable report
  kernel         raw kernel region
  ramdisk.gz     raw ramdisk region (gzip)
  ramdisk/       unpacked cpio entries (best effort)
  recovery_dtbo  if present
  dtb            if present
  sha256.txt     image + part hashes

Usage: python3 analyze.py <image> <outdir> [zipdir]
"""
import sys, os, struct, json, gzip, hashlib, io, zipfile

IMG, OUTDIR = sys.argv[1], sys.argv[2]
ZIPDIR = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(OUTDIR, exist_ok=True)
data = open(IMG, "rb").read()
N = len(data)

def u32(o):
    return struct.unpack_from("<I", data, o)[0] if 0 <= o + 4 <= N else None
def u64(o):
    return struct.unpack_from("<Q", data, o)[0] if 0 <= o + 8 <= N else None
def cstr(o, n):
    if o < 0 or o + n > N:
        return ""
    e = data.find(b"\x00", o, o + n)
    return data[o:(e if e >= 0 else o + n)].decode("utf-8", "replace")
def is_pow2(x):
    return bool(x) and (x & (x - 1)) == 0

# Each layout: offset -> (kind) for integer fields; string fields marked.
# kind: "I" u32, "Q" u64, "S:<len>" string
LAYOUTS = {
    "aosp_v0_v1": {  # classic 1128-byte header (TWRP-legacy, old mkbootimg)
        "version": 0, "header_size": 0x1000,
        "fields": {
            "kernel_size": 8, "kernel_addr": 12,
            "ramdisk_size": 16, "ramdisk_addr": 20,
            "second_size": 24, "second_addr": 28,
            "tags_addr": 32, "page_size": 36, "image_size": 40, "base": 44,
            "cmdline": "S:512@76",
        },
    },
    "aosp_v2": {  # AOSP bootimage.h v2 (Android 11/12 mkbootimg), 4404 bytes
        "version": 2, "header_size": 0x1000,
        "fields": {
            "kernel_size": 8, "kernel_addr": 12,
            "ramdisk_size": 16, "ramdisk_addr": 20,
            "second_size": 24, "second_addr": 28,
            "tags_addr": 32, "page_size": 36, "image_size": 40, "base": 44,
            "kernel_pa": 48, "ramdisk_pa": 52, "tags_pa": 56,
            "recovery_dtbo_size": 60, "recovery_dtbo_addr": 64,
            "extra_cmdline_size": 68,
            "cmdline": "S:764@72",
            "extra_cmdline": "S:1024@836",
            "os_version": "S:64@1860",
            "header_version": 1924, "header_size_field": 1928,
            "header_crc32": 1932,
        },
    },
    "kernel_v2_linux": {  # Linux kernel bootimage.h v2 (has dtb/dtbo), 1676 bytes
        "version": 2, "header_size": 0x1000,
        "fields": {
            "kernel_size": 8, "kernel_addr": 12,
            "ramdisk_size": 16, "ramdisk_addr": 20,
            "second_size": 24, "second_addr": 28,
            "tags_addr": 32, "page_size": 36, "image_size": 40, "base": 44,
            "kernel_load": 52, "ramdisk_load": 56, "tags_load": 60,
            "os_version": "S:16@64",
            "header_size_field": 80, "header_version": 84, "header_crc32": 88,
            "name": "S:16@608",
            "cmdline": "S:512@624",
            "recovery_dtbo_size": 1136, "recovery_dtbo_offset": 1144,
            "dtb_size": 1152, "dtb_offset": 1160,
        },
    },
    "custom_hamedis_v2": {  # layout used by the first custom build (osm0sis-style)
        "version": 2, "header_size": 0x1000,
        "fields": {
            "kernel_size": 8, "kernel_addr": 12,
            "ramdisk_size": 16, "ramdisk_addr": 20,
            "second_size": 24, "second_addr": 28,
            "tags_addr": 32, "page_size": 36, "header_version": 40,
            "base": 44,
            "cmdline": "S:512@64",
            "recovery_dtbo_size": 1608, "recovery_dtbo_offset": 1612,
            "header_size_field": 1620, "dtb_size": 1624, "dtb_offset": 1632,
        },
    },
}

def parse_layout(name, L):
    out = {"layout": name, "expected_version": L["version"], "score": 0, "problems": []}
    vals = {}
    for f, spec in L["fields"].items():
        if isinstance(spec, str) and spec.startswith("S:"):
            ln_s, off_s = spec.split(":")[1].split("@")
            ln, off = int(ln_s), int(off_s)
            vals[f] = cstr(off, ln)
        else:
            v = u64(spec) if spec >= 64 and (f.endswith("offset") or f.endswith("_addr") and name in ("kernel_v2_linux",)) else None
            if f.endswith("offset"):
                v = u64(spec)
            else:
                v = u32(spec)
            vals[f] = v
    out["values"] = vals
    # sanity scoring
    ps = vals.get("page_size")
    if is_pow2(ps) and 512 <= ps <= 65536:
        out["score"] += 2
    else:
        out["problems"].append("page_size bad: %r" % ps)
    ks, rs = vals.get("kernel_size"), vals.get("ramdisk_size")
    if ks and 0 < ks < N:
        out["score"] += 2
    else:
        out["problems"].append("kernel_size bad: %r" % ks)
    if rs and 0 < rs < N:
        out["score"] += 2
    else:
        out["problems"].append("ramdisk_size bad: %r" % rs)
    cl = vals.get("cmdline", "")
    if cl and all(32 <= ord(c) < 127 or c in "\n\t" for c in cl[:80]):
        out["score"] += 1
    if "androidboot" in cl or "console=" in cl:
        out["score"] += 2
    else:
        out["problems"].append("cmdline lacks androidboot/console")
    if "header_version" in vals:
        hv = vals["header_version"]
        if hv == L["version"]:
            out["score"] += 3
        else:
            out["problems"].append("header_version=%r expected %r" % (hv, L["version"]))
    if "header_size_field" in vals and vals["header_size_field"] is not None:
        if vals["header_size_field"] in (0x80, 0x1000, 4096, 8192, 12288, 0x800):
            out["score"] += 2
        else:
            out["problems"].append("header_size field=%r" % vals["header_size_field"])
    rds = vals.get("recovery_dtbo_size")
    if rds is not None and 0 <= rds < N:
        out["score"] += 1
    else:
        out["problems"].append("rdtbo_size bad: %r" % rds)
    dts = vals.get("dtb_size")
    if dts is not None and 0 <= dts < N:
        out["score"] += 1
    return out

report = {"image": os.path.basename(IMG), "size": N,
          "sha256": hashlib.sha256(data).hexdigest(),
          "magic": data[:8].decode("ascii", "replace"),
          "layouts": {}}
if data[:8] != b"ANDROID!":
    report["fatal"] = "no ANDROID! magic"
else:
    for name, L in LAYOUTS.items():
        try:
            report["layouts"][name] = parse_layout(name, L)
        except Exception as e:
            report["layouts"][name] = {"layout": name, "error": str(e), "score": -100}
    ranked = sorted([r for r in report["layouts"].values() if "values" in r],
                    key=lambda r: -r.get("score", 0))
    if not ranked:
        raise SystemExit("no parseable layout found")
    best = ranked[0]
    report["best_layout"] = best["layout"]
    L = LAYOUTS[best["layout"]]
    v = best["values"]
    page = v.get("page_size") or 4096
    # region extraction
    def align(x, a):
        return (x + a - 1) // a * a
    parts = {}
    hdr = v.get("header_size_field") or L["header_size"]
    start = align(max(hdr, page), page) if hdr else page
    # kernel must start at page boundary right after header
    start = page
    ks, rs = v.get("kernel_size") or 0, v.get("ramdisk_size") or 0
    ss = v.get("second_size") or 0
    p = start
    parts["kernel"] = [p, p + ks]
    p2 = align(p + ks, page)
    parts["ramdisk"] = [p2, p2 + rs]
    p3 = align(p2 + rs, page)
    parts["second"] = [p3, p3 + ss]
    p4 = align(p3 + ss, page)
    if "recovery_dtbo_size" in v and v.get("recovery_dtbo_size"):
        parts["recovery_dtbo"] = [p4, p4 + v["recovery_dtbo_size"]]
        p5 = align(p4 + v["recovery_dtbo_size"], page)
    else:
        p5 = p4
    if "dtb_size" in v and v.get("dtb_size"):
        parts["dtb"] = [p5, p5 + v["dtb_size"]]
    report["regions"] = parts
    # verify declared offsets match sequential layout
    if "recovery_dtbo_offset" in v and "recovery_dtbo" in parts:
        if v["recovery_dtbo_offset"] != parts["recovery_dtbo"][0]:
            report["offset_mismatch_rdtbo"] = (v["recovery_dtbo_offset"], parts["recovery_dtbo"][0])
    if "dtb_offset" in v and "dtb" in parts:
        if v["dtb_offset"] != parts["dtb"][0]:
            report["offset_mismatch_dtb"] = (v["dtb_offset"], parts["dtb"][0])
    # magic checks on parts
    for pn, (a, b) in parts.items():
        if b > N:
            report.setdefault("part_out_of_bounds", []).append(pn)
            continue
        blob = data[a:b]
        fn = {"kernel": "kernel", "ramdisk": "ramdisk.gz",
              "recovery_dtbo": "recovery_dtbo", "dtb": "dtb", "second": "second"}.get(pn, pn)
        open(os.path.join(OUTDIR, fn), "wb").write(blob)
        head = blob[:16].hex()
        tag = ""
        if blob[:2] == b"\x1f\x8b":
            tag = "gzip"
        elif blob[:4] == b"\xd0\x0d\xfe\xed":
            tag = "dtb"
        elif blob[:3] == b"\x7fELF":
            tag = "elf"
        report.setdefault("part_magics", {})[pn] = {"hex": head, "tag": tag, "size": len(blob)}
    # ramdisk cpio listing
    rd_a, rd_b = parts.get("ramdisk", [0, 0])
    if rd_a and rd_b <= N:
        try:
            raw = gzip.decompress(data[rd_a:rd_b])
            report["ramdisk"] = {"gzip_size": rd_b - rd_a, "cpio_size": len(raw),
                                 "format": raw[:6].decode("ascii", "replace")}
            entries = []
            off = 0
            while off + 110 <= len(raw) and raw[off:off + 6] == b"070701":
                nsize = int(raw[off + 94:off + 102], 16)
                fname = raw[off + 110:off + 110 + nsize].decode("utf-8", "replace")
                padded = (110 + nsize + 3) & ~3
                size = int(raw[off + 54:off + 62], 16)
                mode = int(raw[off + 14:off + 22], 16)
                entries.append({"name": fname, "size": size, "mode": oct(mode)})
                off = padded + ((size + 3) & ~3)
            report["ramdisk"]["cpio_entries"] = entries
            report["ramdisk"]["entry_count"] = len(entries)
            d = os.path.join(OUTDIR, "ramdisk")
            os.makedirs(d, exist_ok=True)
            # unpack best-effort
            off = 0
            while off + 110 <= len(raw) and raw[off:off + 6] == b"070701":
                nsize = int(raw[off + 94:off + 102], 16)
                fname = raw[off + 110:off + 110 + nsize].decode("utf-8", "replace")
                padded = (110 + nsize + 3) & ~3
                size = int(raw[off + 54:off + 62], 16)
                body = raw[off + padded: off + padded + size]
                off = off + padded + ((size + 3) & ~3)
                safe = fname.strip("/").replace("..", "_")
                if safe and safe != "TRAILER!!!":
                    pth = os.path.join(d, safe)
                    os.makedirs(os.path.dirname(pth), exist_ok=True) if "/" in safe else None
                    open(pth, "wb").write(body)
        except Exception as e:
            report["ramdisk"] = {"error": str(e)}
    # extra cmdline (aosp_v2)
    if "extra_cmdline" in v and v.get("extra_cmdline"):
        open(os.path.join(OUTDIR, "extra_cmdline.txt"), "w").write(v["extra_cmdline"])

# generic scans
def find_all(sig):
    out, off = [], 0
    while True:
        i = data.find(sig, off)
        if i < 0:
            return out
        out.append(i)
        off = i + 1
        if len(out) > 200:
            return out
report["gzip_mags"] = find_all(b"\x1f\x8b\x08")
report["dtb_mags"] = find_all(b"\xd0\x0d\xfe\xed")
i = data.find(b"console=")
report["first_console_at"] = i
if i >= 0:
    j = data.find(b"\x00", i)
    report["cmdline_at_console"] = data[i:(j if j >= 0 else i + 600)].decode("utf-8", "replace")

# zipdir listing
if ZIPDIR and os.path.isdir(ZIPDIR):
    zlist = []
    for root, _, files in os.walk(ZIPDIR):
        for f in files:
            p = os.path.join(root, f)
            zlist.append({"path": os.path.relpath(p, ZIPDIR), "size": os.path.getsize(p)})
    report["zip_contents"] = sorted(zlist, key=lambda z: -z["size"])

open(os.path.join(OUTDIR, "analysis.json"), "w").write(json.dumps(report, indent=1))

# human-readable md
md = []
md.append("# Boot image analysis: %s\n" % os.path.basename(IMG))
md.append("- size: %d (%#x)\n- sha256: %s\n" % (N, N, report["sha256"]))
md.append("- best layout: **%s**\n" % report.get("best_layout"))
for name, r in report.get("layouts", {}).items():
    md.append("\n## %s (score %s)\n" % (name, r.get("score")))
    if r.get("problems"):
        md.append("problems: " + "; ".join(r["problems"]) + "\n")
    for k, val in r.get("values", {}).items():
        if isinstance(val, str):
            val = val[:160]
        md.append("- %s = %s\n" % (k, val))
if report.get("regions"):
    md.append("\n## regions (best layout)\n")
    for pn, (a, b) in report["regions"].items():
        mag = report.get("part_magics", {}).get(pn, {})
        md.append("- %s: %#x .. %#x (%d) %s\n" % (pn, a, b, b - a, mag.get("tag", "")))
rd = report.get("ramdisk", {})
if rd:
    md.append("\n## ramdisk cpio (%d entries)\n" % rd.get("entry_count", 0))
    for e in rd.get("cpio_entries", [])[:60]:
        md.append("- %s (%s, %s)\n" % (e["name"], oct(e["mode"]), e["size"]))
    if rd.get("entry_count", 0) > 60:
        md.append("- ... %d more\n" % (rd["entry_count"] - 60))
if report.get("zip_contents"):
    md.append("\n## zip contents\n")
    for z in report["zip_contents"]:
        md.append("- %s (%d)\n" % (z["path"], z["size"]))
md.append("\n## scans\n- gzip mags: %s\n- dtb mags: %s\n- first console= at %#x\n" %
          ([hex(x) for x in report.get("gzip_mags", [])[:20]],
           [hex(x) for x in report.get("dtb_mags", [])[:20]],
           report.get("first_console_at", -1) & 0xFFFFFFFFFFFFFFFF))
if report.get("cmdline_at_console"):
    md.append("\ncmdline found in image:\n```\n%s\n```\n" % report["cmdline_at_console"])
open(os.path.join(OUTDIR, "analysis.md"), "w").write("".join(md))
print("best layout:", report.get("best_layout"))
print(open(os.path.join(OUTDIR, "analysis.md")).read()[:3000])
