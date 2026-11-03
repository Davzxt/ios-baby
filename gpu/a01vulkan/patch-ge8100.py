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
# ISP tiles in flight follow the core's ISP IPP pipes (GE8300 4, GE8320 7; rgxconfig NUM_ISP_IPP_PIPES):
# the GE8100 has 2. With the GE8300's 4, ISP_CTL.PIPE_ENABLE switched on two pipes the core lacks.
if ge.count(".isp_max_tiles_in_flight = 4U,") != 1:
    raise SystemExit("ge8100.h: isp_max_tiles_in_flight not found")
ge = ge.replace(".isp_max_tiles_in_flight = 4U,", ".isp_max_tiles_in_flight = 2U,")
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

# GE8100 erratum BRN 65273: the DDK gives every memory context two extra heaps, "MMU INIA BRN65273"
# (0xF800000000) and "MMU INIB BRN65273" (0xF900000000), "two Region Header buffers 4GB apart"
# (rgxheapconfig.h). On the phone the first GPU fault was a TA write to 0xF800000000, the INIA
# base, with nothing mapped there: the vendor UM driver maps memory at both bases, img-pvr
# (written for a GE8320 without this erratum) does not know these heaps. Map 4 MiB of zeroed GPU
# memory at the base of each heap when the device's memory context is created.
srv = mesa / "src/imagination/vulkan/winsys/pvrsrvkm/pvr_srv.c"
t = srv.read_text()
if "A01: BRN 65273" not in t:
    helper = '''
/* A01: BRN 65273 (GE8100): map zeroed memory at the base of the MMU INIA/INIB heaps, where the
 * firmware/hardware write region headers (gpu/a01vulkan/patch-ge8100.py). */
static void a01_map_brn65273_heap(struct pvr_srv_winsys *srv_ws, int idx, const char *name)
{
   const struct pvr_winsys_static_data_offsets none = { 0 };
   const uint64_t size = 4ULL << 20;
   struct pvr_srv_winsys_heap *heap;
   struct pvr_srv_winsys_vma *vma;
   struct pvr_winsys_bo *bo;
   pvr_dev_addr_t addr;
   VkResult result;

   if (idx < 0)
      return;
   heap = vk_zalloc(srv_ws->base.alloc, sizeof(*heap), 8, VK_SYSTEM_ALLOCATION_SCOPE_DEVICE);
   vma = vk_zalloc(srv_ws->base.alloc, sizeof(*vma), 8, VK_SYSTEM_ALLOCATION_SCOPE_DEVICE);
   if (!heap || !vma)
      return;
   result = pvr_srv_heap_init(srv_ws, heap, idx, &none);
   if (result == VK_SUCCESS)
      result = pvr_srv_winsys_buffer_create(&srv_ws->base, size, srv_ws->base.page_size,
                                            PVR_WINSYS_BO_TYPE_GPU, 0, &bo);
   if (result == VK_SUCCESS)
      result = pvr_srv_int_reserve_addr(srv_ws->base.render_fd, heap->server_heap,
                                        heap->base.base_addr, size, &vma->reservation);
   if (result == VK_SUCCESS) {
      vma->base.dev_addr = heap->base.base_addr;
      vma->base.heap = &heap->base;
      vma->base.size = size;
      vma->base.bo = NULL;
      p_atomic_inc(&heap->base.ref_count);
      result = pvr_srv_winsys_vma_map(&vma->base, bo, 0, size, &addr);
   }
   fprintf(stderr, "A01VK: BRN65273 heap %s @0x%llx: %s\\n", name,
           (unsigned long long)heap->base.base_addr.addr,
           result == VK_SUCCESS ? "mapped 4 MiB" : "FAILED");
}

'''
    anchor = "static VkResult pvr_srv_memctx_init(struct pvr_srv_winsys *srv_ws)"
    if t.count(anchor) != 1:
        sys.exit("pvr_srv.c: memctx_init not found")
    t = t.replace(anchor, helper + anchor, 1)
    old = "   int usc_heap_idx = -1;\n"
    if t.count(old) != 1:
        sys.exit("pvr_srv.c: heap idx declarations not found")
    t = t.replace(old, old + "   int a01_inia_idx = -1, a01_inib_idx = -1;\n", 1)
    old = "         vis_test_heap_idx = i;\n      }\n"
    if t.count(old) != 1:
        sys.exit("pvr_srv.c: heap name loop not found")
    t = t.replace(old, "         vis_test_heap_idx = i;\n"
                  "      } else if (strcmp(heap_name, \"MMU INIA BRN65273\") == 0) {\n"
                  "         a01_inia_idx = i;\n"
                  "      } else if (strcmp(heap_name, \"MMU INIB BRN65273\") == 0) {\n"
                  "         a01_inib_idx = i;\n"
                  "      }\n", 1)
    old = "      srv_ws->rgn_hdr_heap_present = false;\n   }\n"
    if t.count(old) != 1:
        sys.exit("pvr_srv.c: optional heap setup not found")
    t = t.replace(old, old + "\n   a01_map_brn65273_heap(srv_ws, a01_inia_idx, \"INIA\");\n"
                  "   a01_map_brn65273_heap(srv_ws, a01_inib_idx, \"INIB\");\n", 1)
    if "#include <stdio.h>" not in t:
        t = t.replace("#include <assert.h>\n", "#include <assert.h>\n#include <stdio.h>\n#include <string.h>\n", 1)
    srv.write_text(t)
    print("pvr_srv.c: BRN 65273 INIA/INIB heaps mapped")
