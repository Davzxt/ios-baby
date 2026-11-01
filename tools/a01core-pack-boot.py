#!/usr/bin/env python3
"""Inspect or repack a Galaxy A01 Core (SM-A013F/G/M, MT6739) boot image.

Host-side only: it never opens a block device and never flashes the phone.
Keep the stock boot.img and every output off Git (they carry device data).

  info  STOCK
        print the Android header (v0..v2), MediaTek part headers, kernel
        format and the bootopt in the command line.
  pack  STOCK IMAGE OUT [--append PAYLOAD] [--raw] [--partition-size N]
        replace the kernel with IMAGE (shim/a01core/out/a01core.Image),
        optionally appending the SWEETXNU payload (tools/mkpayload.py) at
        the Image's 4 KiB-aligned end, as shim/herolte does. Keeps the stock
        ramdisk, recovery DTBO and DTB sections (LK patches that DTB and
        hands it to us). Rewrites bootopt to 64S3,32N2,64N2 so MediaTek LK
        starts a 64-bit kernel (the stock A01 Core kernel is 32-bit), and
        gzips the kernel like the stock one unless --raw.

Sections, page alignment and the SHA-1 id follow AOSP mkbootimg; the
MediaTek 512-byte part header (magic 0x58881688) is kept when the stock
kernel has one. Unverified on the phone: whether this LK accepts a 64-bit
kernel at all is milestone 1 of docs/A01CORE_PORTING.md.
"""
import argparse
import gzip
import hashlib
from pathlib import Path
import re
import struct
import sys

ARM64_MAGIC = b"ARMd"
MTK_MAGIC = 0x58881688
BOOTOPT_64 = "bootopt=64S3,32N2,64N2"


def mtk_split(blob):
    """(header or None, body) for a MediaTek part header."""
    if len(blob) >= 512 and struct.unpack_from("<I", blob, 0)[0] == MTK_MAGIC:
        size = struct.unpack_from("<I", blob, 4)[0]
        return blob[:512], blob[512:512 + size]
    return None, blob


def mtk_join(header, body):
    if header is None:
        return body
    h = bytearray(header)
    struct.pack_into("<I", h, 4, len(body))
    return bytes(h) + body


def parse(boot):
    if boot[:8] != b"ANDROID!":
        raise SystemExit("not an Android boot image")
    (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size,
     second_addr, tags_addr, page, version, os_version) = struct.unpack_from("<10I", boot, 8)
    if page not in (2048, 4096):
        raise SystemExit(f"unexpected page size {page}")
    if version > 2:
        raise SystemExit(f"boot header v{version} is not handled (A01 Core uses v0-v2)")
    align = lambda n: (n + page - 1) // page * page
    dtbo_size = dtb_size = 0
    dtbo_off_field = dtb_addr = header_size = 0
    if version >= 1:
        dtbo_size, dtbo_off_field, header_size = struct.unpack_from("<IQI", boot, 1632)
    if version >= 2:
        dtb_size, dtb_addr = struct.unpack_from("<IQ", boot, 1648)
    off = page
    parts = {}
    for name, size in (("kernel", kernel_size), ("ramdisk", ramdisk_size),
                       ("second", second_size), ("dtbo", dtbo_size), ("dtb", dtb_size)):
        parts[name] = boot[off:off + size]
        if len(parts[name]) != size:
            raise SystemExit(f"image truncated in {name}")
        off += align(size)
    return {
        "version": version, "page": page, "align": align,
        "kernel_addr": kernel_addr, "ramdisk_addr": ramdisk_addr,
        "tags_addr": tags_addr, "dtb_addr": dtb_addr, "os_version": os_version,
        "name": boot[48:64].split(b"\0")[0].decode(errors="replace"),
        "cmdline": boot[64:576].split(b"\0")[0].decode(errors="replace"),
        "extra": boot[608:1632].split(b"\0")[0].decode(errors="replace") if version >= 0 else "",
        "parts": parts, "end": off, "tail": boot[off:],
    }


def kernel_info(kernel):
    hdr, body = mtk_split(kernel)
    fmt = "gzip" if body[:2] == b"\x1f\x8b" else ("arm64 Image" if body[56:60] == ARM64_MAGIC
                                                  else ("arm zImage" if body[36:40] == b"\x18\x28\x6f\x01" else "unknown"))
    return hdr, body, fmt


def cmd_info(args):
    b = parse(args.stock.read_bytes())
    print(f"header v{b['version']} page {b['page']} name {b['name']!r}")
    print(f"cmdline {b['cmdline']!r}")
    print(f"kernel_addr {b['kernel_addr']:#x} ramdisk_addr {b['ramdisk_addr']:#x} "
          f"tags {b['tags_addr']:#x} dtb_addr {b['dtb_addr']:#x}")
    for name, data in b["parts"].items():
        hdr, body = mtk_split(data)
        extra = f" (MTK header {hdr[8:40].split(b'\0')[0].decode(errors='replace')!r})" if hdr else ""
        print(f"{name:8} {len(data):10} bytes{extra}")
    hdr, body, fmt = kernel_info(b["parts"]["kernel"])
    print(f"kernel format {fmt}")
    m = re.search(r"bootopt=\S+", b["cmdline"])
    print(f"bootopt {m.group(0) if m else 'absent'} -> {BOOTOPT_64} after pack")
    print(f"tail {len(b['tail'])} bytes ({b['tail'][:16]!r})")


def cmd_pack(args):
    if args.output.exists():
        raise SystemExit("output exists; choose a new path")
    stock = args.stock.read_bytes()
    b = parse(stock)
    image = bytearray(args.image.read_bytes())
    if image[56:60] != ARM64_MAGIC:
        raise SystemExit("IMAGE lacks the arm64 Image header (build shim/a01core first)")
    if args.append:
        payload = args.append.read_bytes()
        if payload[:8] != b"SWEETXNU":
            raise SystemExit("--append payload is not a SWEETXNU container")
        image.extend(b"\0" * (-len(image) % 4096))
        image.extend(payload)
    # image_size covers the file plus 64 KiB of zeroed headroom; flags:
    # little endian, 4 KiB pages, may be placed anywhere (Linux booting.rst).
    image_size = (len(image) + 0x10000 + 0xfff) & ~0xfff
    struct.pack_into("<3Q", image, 8, 0x80000, image_size, 0xa)
    kernel_body = bytes(image) if args.raw else gzip.compress(bytes(image), 9, mtime=0)
    stock_mtk, _, stock_fmt = kernel_info(b["parts"]["kernel"])
    kernel = mtk_join(stock_mtk, kernel_body)

    cmdline = b["cmdline"]
    cmdline = re.sub(r"bootopt=\S+", BOOTOPT_64, cmdline) if "bootopt=" in cmdline else \
        (BOOTOPT_64 + (" " + cmdline if cmdline else ""))
    if len(cmdline) >= 512:
        raise SystemExit("command line too long")

    page, align = b["page"], b["align"]
    header = bytearray(stock[:page])
    struct.pack_into("<I", header, 8, len(kernel))
    # The stock 32-bit zImage loads at base+0x8000; a 64-bit Image goes to
    # base+0x80000 (MediaTek's arm64 boot images use 0x40080000).
    if args.kernel_addr is not None:
        struct.pack_into("<I", header, 12, args.kernel_addr)
    header[64:576] = cmdline.encode().ljust(512, b"\0")
    parts = [kernel, b["parts"]["ramdisk"], b["parts"]["second"]]
    if b["version"] >= 1:
        parts.append(b["parts"]["dtbo"])
    if b["version"] >= 2:
        parts.append(b["parts"]["dtb"])
    digest = hashlib.sha1()
    for part in parts:
        digest.update(part)
        digest.update(struct.pack("<I", len(part)))
    header[576:596] = digest.digest()
    header[596:608] = b"\0" * 12
    if b["version"] >= 1 and b["parts"]["dtbo"]:
        # recovery_dtbo_offset is the absolute offset of the section.
        off = page + sum(align(len(p)) for p in parts[:3])
        struct.pack_into("<Q", header, 1636, off)
    out = bytearray(header)
    for part in parts:
        out.extend(part)
        out.extend(b"\0" * (align(len(part)) - len(part)))
    # Samsung's LK still looks for this marker; the stock signature is dropped.
    out.extend(b"SEANDROIDENFORCE")
    if args.partition_size and len(out) > args.partition_size:
        raise SystemExit(f"boot image {len(out)} bytes exceeds the partition ({args.partition_size})")
    args.output.write_bytes(out)
    print(f"stock kernel: {stock_fmt}{' + MTK header' if stock_mtk else ''}; "
          f"new kernel: {'raw' if args.raw else 'gzip'} {len(kernel_body)} bytes "
          f"(Image+payload {len(image)} bytes, image_size {image_size:#x})")
    print(f"cmdline: {cmdline}")
    print(f"wrote {args.output} ({len(out)} bytes) sha256={hashlib.sha256(out).hexdigest()}")
    if not args.partition_size:
        print("note: pass --partition-size to check the boot partition fit", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    info = sub.add_parser("info")
    info.add_argument("stock", type=Path)
    pack = sub.add_parser("pack")
    pack.add_argument("stock", type=Path)
    pack.add_argument("image", type=Path)
    pack.add_argument("output", type=Path)
    pack.add_argument("--append", type=Path, help="SWEETXNU payload appended to IMAGE")
    pack.add_argument("--raw", action="store_true", help="do not gzip the kernel")
    pack.add_argument("--partition-size", type=int, default=32 << 20,
                      help="boot partition bytes (A01 Core: 33554432)")
    pack.add_argument("--kernel-addr", type=lambda v: int(v, 0), default=0x40080000,
                      help="header kernel load address (default 0x40080000)")
    args = ap.parse_args()
    {"info": cmd_info, "pack": cmd_pack}[args.cmd](args)


if __name__ == "__main__":
    main()
