#!/usr/bin/env python3
"""Compile the DDK 1.11 kernel services core for arm64 against the XNU OS layer (gpu/ddk-1.11/env/xnu)
and list what is still missing: compile errors per file, then every symbol the core calls that
nothing defines (the OS layer still to write).

  python tools/ddk-xnu-check.py [--clang PATH] [--out DIR]

Needs only clang (no XNU tree): system headers come from env/xnu/sysinc.
"""
import argparse, pathlib, re, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "gpu" / "ddk-1.11"

CORE = """
services/server/common/devicemem_heapcfg.c services/shared/common/devicemem.c
services/shared/common/devicemem_utils.c services/shared/common/hash.c services/shared/common/ra.c
services/shared/common/sync.c services/shared/common/mem_utils.c services/server/common/devicemem_server.c
services/server/common/handle.c services/server/common/lists.c services/server/common/mmu_common.c
services/server/common/connection_server.c services/server/common/physheap.c services/server/common/physmem.c
services/server/common/physmem_lma.c services/server/common/physmem_hostmem.c services/server/common/pmr.c
services/server/common/power.c services/server/common/process_stats.c services/server/common/pvr_notifier.c
services/server/common/pvrsrv.c services/server/common/srvcore.c services/server/common/sync_checkpoint.c
services/server/common/sync_server.c services/shared/common/htbuffer.c services/server/common/htbserver.c
services/server/common/tlintern.c services/shared/common/tlclient.c services/server/common/tlserver.c
services/server/common/tlstream.c services/server/common/cache_km.c services/shared/common/uniq_key_splay_tree.c
services/server/common/pvrsrv_pool.c services/server/common/pvrsrv_bridge_init.c services/server/common/info_page_km.c
services/shared/common/pvrsrv_error.c services/server/common/handle_generic.c
services/server/devices/rgx/rgxfwdbg.c services/server/devices/rgx/rgxbreakpoint.c services/server/devices/rgx/rgxccb.c
services/server/devices/rgx/rgxdebug.c services/server/devices/rgx/rgxfwutils.c services/server/devices/rgx/rgxinit.c
services/server/devices/rgx/rgxbvnc.c services/server/devices/rgx/rgxkicksync.c services/server/devices/rgx/rgxlayer_impl.c
services/server/devices/rgx/rgxmem.c services/server/devices/rgx/rgxmmuinit.c services/server/devices/rgx/rgxregconfig.c
services/server/devices/rgx/rgxta3d.c services/server/devices/rgx/rgxsyncutils.c services/server/devices/rgx/rgxtransfer.c
services/server/devices/rgx/rgxtdmtransfer.c services/server/devices/rgx/rgxutils.c services/server/devices/rgx/rgxmipsmmuinit.c
services/server/devices/rgx/rgxhwperf.c services/server/devices/rgx/rgxpower.c services/server/devices/rgx/rgxstartstop.c
services/server/devices/rgx/rgxtimecorr.c services/server/devices/rgx/rgxcompute.c services/server/devices/rgx/rgxsignals.c
services/server/devices/rgx/rgxfwimageutils.c services/server/devices/rgx/rgxsrvinit.c services/server/devices/rgx/rgxshader.c
services/server/common/devicemem_history_server.c services/shared/devices/rgx/rgx_hwperf_table.c
generated/cache_bridge/client_cache_direct_bridge.c generated/devicememhistory_bridge/client_devicememhistory_direct_bridge.c
generated/htbuffer_bridge/client_htbuffer_direct_bridge.c generated/mm_bridge/client_mm_direct_bridge.c
generated/pvrtl_bridge/client_pvrtl_direct_bridge.c generated/sync_bridge/client_sync_direct_bridge.c
generated/synctracking_bridge/client_synctracking_direct_bridge.c
""".split()

BRIDGES = ["cache", "cmm", "devicememhistory", "dmabuf", "htbuffer", "mm", "pvrtl", "rgxbreakpoint", "rgxcmp",
           "rgxfwdbg", "rgxhwperf", "rgxkicksync", "rgxregconfig", "rgxsignals", "rgxta3d", "rgxtq2", "rgxtq",
           "srvcore", "sync", "synctracking"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clang", default=shutil.which("clang") or r"C:\Program Files\LLVM\bin\clang.exe")
    ap.add_argument("--out", default=str(ROOT / "env" / "xnu" / "build-check"))
    a = ap.parse_args()
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    nm = str(pathlib.Path(a.clang).with_name("llvm-nm" + pathlib.Path(a.clang).suffix))
    res = subprocess.run([a.clang, "-print-resource-dir"], capture_output=True, text=True).stdout.strip()

    srcs = [s for s in CORE if (ROOT / s).exists()]
    srcs += [f"generated/{b}_bridge/server_{b}_bridge.c" for b in BRIDGES]
    srcs += [str(p.relative_to(ROOT)).replace("\\", "/") for p in sorted((ROOT / "env/xnu").glob("*.c"))]
    incs = ["env/xnu", "env/xnu/sysinc", "include", "include/public", "hwdefs", "hwdefs/km",
            "services/include", "services/include/shared", "services/shared/include", "services/server/include",
            "services/server/devices/rgx", "services/system/include", "services/shared/devices/rgx", "services/server/common"]
    incs += [f"generated/{b}_bridge" for b in BRIDGES]
    flags = ["--target=arm64-apple-ios16.0", "-ffreestanding", "-nostdinc", "-fno-builtin", "-std=gnu99",
             "-isystem", res + "/include", "-include", "config_kernel_a01core.h",
             "-DPVRSRV_A01_XNU", "-D__KERNEL__", "-Wno-everything", "-Werror=implicit-function-declaration"] + [f"-I{ROOT / i}" for i in incs]

    errors, objs = {}, []
    for s in srcs:
        o = out / (s.replace("/", "_") + ".o")
        r = subprocess.run([a.clang] + flags + ["-c", str(ROOT / s), "-o", str(o)], capture_output=True, text=True)
        if r.returncode:
            errors[s] = [l for l in r.stderr.splitlines() if "error" in l][:6]
        else:
            objs.append(str(o))
    print(f"compiled {len(objs)}/{len(srcs)} files")
    for s, e in errors.items():
        print(f"\nFAIL {s}")
        for l in e:
            print("   ", l.split("ddk-1.11")[-1][:220])
    if objs:
        defined, undefined = set(), set()
        for o in objs:
            for l in subprocess.run([nm, o], capture_output=True, text=True).stdout.splitlines():
                p = l.split()
                if len(p) >= 2 and p[-2] == "U":
                    undefined.add(p[-1])
                elif len(p) >= 3:
                    defined.add(p[-1])
        missing = sorted(u.lstrip("_") for u in undefined - defined)
        print(f"\n{len(missing)} symbols used but not defined (OS layer to write):")
        print(" ".join(missing))


if __name__ == "__main__":
    sys.exit(main())
