#!/usr/bin/env python3
"""Add the PowerVR GE8100 (BVNC 22.49.21.16, Galaxy A01 Core) to Mesa's pvr device table.

Based on Mesa's ge8300.h (same Rogue 8XE family). Confirmed against the DDK m1.11ED5425693
hwdefs/km/configs/rgxconfig_km_22.V.21.16.h: NUM_CLUSTERS 1, NUM_RASTER_PIPES 1,
SLC_CACHE_LINE_SIZE_BITS 512, SIMPLE_PARAMETER_FORMAT_VERSION 1, ROGUEXE, PBE2_IN_XE, COMPUTE,
GS_RTA_SUPPORT. The USC/UVS sizes are GE8300's: UNVERIFIED for the GE8100.
"""
import pathlib, re, sys

mesa = pathlib.Path(sys.argv[1])
info = mesa / "src/imagination/common/device_info"
src = (info / "ge8300.h").read_text()
# keep only the first device (22.67.54.30): ge8300.h also describes 22.68.54.30 and 22.102.54.38
lines = src.splitlines(keepends=True)
cut = next(i for i, l in enumerate(lines) if "pvr_device_enhancements" in l and i > 0
           and "22_68_54_30" in "".join(lines[i:i + 2]))
src = "".join(lines[:cut]) + "\n#endif\n"
ge = src.replace("GE8300_H", "GE8100_H").replace('"GE8300"', '"GE8100"')
ge = ge.replace("22_V_54_30", "22_V_21_16").replace("22_67_54_30", "22_49_21_16")
ge = ge.replace("0x22054030", "0x22021016")
ge = re.sub(r"\.v = 67,", ".v = 49,", ge)
ge = re.sub(r"\.n = 54,", ".n = 21,", ge)
ge = re.sub(r"\.c = 30,", ".c = 16,", ge)
ge = "/* GE8100: derived from ge8300.h, see gpu/a01vulkan/patch-ge8100.py */\n" + ge
(info / "ge8100.h").write_text(ge)

tab = mesa / "src/imagination/common/pvr_device_info.c"
t = tab.read_text()
if "ge8100.h" not in t:
    t = t.replace('#include "device_info/ge8300.h"', '#include "device_info/ge8100.h"\n#include "device_info/ge8300.h"')
    m = re.search(r"\n(\s*)(CASE_PACKED_BVNC_DEVICE_INFO\(22, 67, 54, 30\)[^\n]*)", t)
    if not m:
        sys.exit("pvr_device_info.c: GE8300 case not found")
    t = t.replace(m.group(0), m.group(0) + f"\n{m.group(1)}CASE_PACKED_BVNC_DEVICE_INFO(22, 49, 21, 16);")
    tab.write_text(t)
print("GE8100 added")

# Processes that load the Metal plugin (SpringBoard, apps) cannot get
# PVR_I_WANT_A_BROKEN_VULKAN_DRIVER in their environment, so the GE8100 is listed with img-pvr's
# own bring-up entries. This does not make it conformant.
pd = mesa / "src/imagination/vulkan/pvr_physical_device.c"
if pd.exists():
    t = pd.read_text()
    anchor = "   case PVR_BVNC_PACK(22, 87, 104, 18):\n"
    if anchor in t and "PVR_BVNC_PACK(22, 49, 21, 16)" not in t:
        t = t.replace(anchor, anchor + "   /* A01 Core: GE8100 (22.49.21.16), DDK 1.11, bring-up only, not conformant */\n"
                      "   case PVR_BVNC_PACK(22, 49, 21, 16):\n", 1)
        pd.write_text(t)
        print("pvr_physical_device.c: GE8100 loads without the env override")
