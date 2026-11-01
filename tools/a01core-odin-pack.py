#!/usr/bin/env python3
"""Make Odin packages for the Galaxy A01 Core port. Host side only.

  vbmeta OUT
      an empty AVB 2.0 vbmeta image with flags = 3 (hashtree and
      verification disabled), the usual way to let an UNLOCKED Samsung
      bootloader start a boot image that is not Samsung-signed.
  tar OUT.tar.md5 FILE [FILE ...]
      an Odin "AP" package: ustar archive + trailing md5 line, as Samsung
      firmware packages are. File names must be the partition image names
      Odin expects (boot.img, vbmeta.img, userdata.img, ...).

Nothing here talks to the phone. Flash with Odin in download mode, only
after the bootloader is unlocked (OEM unlock) and you have the full stock
firmware for your exact model at hand to go back.
"""
import argparse
import hashlib
import io
from pathlib import Path
import struct
import tarfile
import time


def vbmeta_disabled():
    h = bytearray(256)
    h[0:4] = b"AVB0"
    struct.pack_into(">II", h, 4, 1, 0)        # required libavb 1.0
    # auth/aux block sizes, algorithm NONE, all offsets/sizes 0
    struct.pack_into(">I", h, 120, 3)          # flags: HASHTREE_DISABLED | VERIFICATION_DISABLED
    rel = b"avbtool 1.1.0 (a01core disabled)"
    h[128:128 + len(rel)] = rel                # release_string[48]
    return bytes(h) + b"\0" * (4096 - 256)


def cmd_vbmeta(args):
    args.output.write_bytes(vbmeta_disabled())
    print(f"wrote {args.output} (4096 bytes, AVB flags 3)")


def cmd_tar(args):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for path in args.files:
            data = path.read_bytes()
            info = tarfile.TarInfo(path.name)
            info.size = len(data)
            info.mtime = int(time.time())
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    blob = buf.getvalue()
    name = args.output.name[:-len(".md5")] if args.output.name.endswith(".md5") else args.output.name
    md5 = hashlib.md5(blob).hexdigest()
    args.output.write_bytes(blob + f"{md5}  {name}\n".encode())
    print(f"wrote {args.output}: {', '.join(p.name for p in args.files)} md5 {md5}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("vbmeta")
    v.add_argument("output", type=Path)
    t = sub.add_parser("tar")
    t.add_argument("output", type=Path)
    t.add_argument("files", type=Path, nargs="+")
    args = ap.parse_args()
    {"vbmeta": cmd_vbmeta, "tar": cmd_tar}[args.cmd](args)


if __name__ == "__main__":
    main()
