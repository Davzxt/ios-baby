#!/usr/bin/env python3
"""Build an A01 Core drop package: files the kernel writes into the iOS root at boot
(bsd/dev/a01core_drop.c, XNU patch 0322). The package goes into the boot payload with
  mkpayload.py ... --blob A01Drop=PKG

  a01core-drop.py OUT DEST=SRC [DEST=SRC ...] [--autorun DEST] [--env KEY=VALUE ...]

DEST is relative to /private/var/a01/ (parent directories are added). --autorun DEST also
installs /System/Library/LaunchDaemons/com.a01core.autorun.plist, which runs that program once
per boot as root; its output goes to /private/var/a01/autorun.txt, which the kernel prints
early in the following boot (launchd reads it from the next boot on).
Format (same as tools/herolte-drop.py): 32-byte header "HERODRP1" | u32 1 | u32 count |
u64 bytes | u64 id, payload from byte 4096: u32 path length | u32 mode (0 = directory) |
u64 size | path | data, each item 8-byte aligned. The id is a hash of the contents, so the
kernel rewrites the files only when they change.
"""
import argparse, hashlib, os, pathlib, plistlib, struct, sys

PREFIX = "/private/var/a01/"
PLIST = "/System/Library/LaunchDaemons/com.a01core.autorun.plist"
BUNDLE = "/System/Library/Extensions/A01Metal.bundle"
NATIVE_BUNDLE = "/System/Library/Extensions/A01NativeMetal.bundle"
NATIVE_SELFTEST = "/System/Library/Extensions/A01NativeMetal.selftest"
# launchd job the iOS root already has (tools/herolte-tune-ios-root.sh); output in autorun.out
AUTORUN = "/private/var/herolte/autorun"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("items", nargs="+", help="DEST=SRC")
    ap.add_argument("--autorun")
    ap.add_argument("--env", action="append", default=[])
    a = ap.parse_args()

    entries, dirs = [], set()
    for item in a.items:
        dest, src = item.split("=", 1)
        data = pathlib.Path(src).read_bytes()
        mode = 0o755 if os.access(src, os.X_OK) or dest.strip("/") == a.autorun or data[:4] in (b"\xcf\xfa\xed\xfe",) else 0o644
        if dest.startswith("/"):
            # absolute: only the Metal plugin bundle (the kernel refuses anything else)
            if dest == AUTORUN:
                dirs.add("/private/var/herolte")
            elif dest.startswith(NATIVE_BUNDLE + "/") and ".." not in dest.split("/"):
                parts = dest[len(NATIVE_BUNDLE) + 1:].split("/")
                dirs.add(NATIVE_BUNDLE)
                for i in range(1, len(parts)):
                    dirs.add(NATIVE_BUNDLE + "/" + "/".join(parts[:i]))
            elif dest == NATIVE_SELFTEST:
                pass
            elif dest.startswith(BUNDLE + "/") and ".." not in dest.split("/"):
                dirs.add(BUNDLE)
            else:
                sys.exit(f"{dest}: absolute destinations must be {AUTORUN} or inside {BUNDLE}")
            entries.append((dest, mode, data))
            continue
        dest = dest.strip("/")
        parts = dest.split("/")
        for i in range(1, len(parts)):
            dirs.add(PREFIX + "/".join(parts[:i]))
        entries.append((PREFIX + dest, mode, data))
    if a.autorun:
        env = dict(kv.split("=", 1) for kv in a.env)
        job = {
            "Label": "com.a01core.autorun",
            "ProgramArguments": [PREFIX + a.autorun.strip("/")],
            "RunAtLoad": True,
            "UserName": "root",
            "StandardOutPath": PREFIX + "autorun.txt",
            "StandardErrorPath": PREFIX + "autorun.txt",
            "EnvironmentVariables": env,
        }
        entries.append((PLIST, 0o644, plistlib.dumps(job, fmt=plistlib.FMT_XML)))

    items = [(d, 0, b"") for d in sorted(dirs, key=len)] + entries
    payload = bytearray()
    for path, mode, data in items:
        p = path.encode()
        head = struct.pack("<IIQ", len(p), mode, len(data)) + p
        payload += head + b"\0" * (-len(head) % 8) + data + b"\0" * (-len(data) % 8)
    pkg_id = int.from_bytes(hashlib.sha256(payload).digest()[:8], "little") or 1
    header = b"HERODRP1" + struct.pack("<IIQQ", 1, len(items), len(payload), pkg_id)
    pathlib.Path(a.out).write_bytes(header + b"\0" * (4096 - len(header)) + payload)
    print(f"{a.out}: {len(items)} entries, {len(payload)} bytes, id {pkg_id:#x}")
    for path, mode, data in items:
        print(f"  {oct(mode) if mode else 'dir  '} {len(data):>9} {path}")


if __name__ == "__main__":
    sys.exit(main())
