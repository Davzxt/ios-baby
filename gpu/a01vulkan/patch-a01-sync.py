#!/usr/bin/env python3
"""GPU completion fences for img-pvr on iOS (Galaxy A01 Core).

iOS has no /dev/pvr_sync, so on Darwin every job's out-fence is -1 and img-pvr treated each job as
finished the moment it was submitted (pvr_srv_set_sync_payload(-1) = signaled). Tests survived with
a 300 ms settle, but Zink (the iOS UI) reads frames back right after its fence "signals" and showed
half-drawn frames.

The DDK's own completion mechanism needs no fences: the firmware writes a value into a sync prim
(client update UFO) when a job ends. Render jobs already carry one (the RT dataset's sync prim,
geometry and fragment update values); transfer and compute jobs get one per context here. The sync
prim block is a PMR, mapped into the process through A01CoreGPU, so a fence becomes
"address + value" and a wait polls until the firmware has written it (2 s cap, so a GPU fault
cannot freeze the UI forever).

  patch-a01-sync.py MESA_DIR
"""
import pathlib
import sys

mesa = pathlib.Path(sys.argv[1])
W = mesa / "src/imagination/vulkan/winsys/pvrsrvkm"


def edit(path, old, new, count=1):
    t = path.read_text()
    if t.count(old) != count:
        raise SystemExit(f"{path.name}: expected {count} match(es), found {t.count(old)}:\n{old}")
    path.write_text(t.replace(old, new))


# ---- sync prim block: CPU mapping ------------------------------------------------------------
edit(W / "pvr_srv_sync_prim.h",
     "   /* Top limit for how many sync prims can be allocated from the block. */\n   uint32_t max_count;\n",
     "   /* Top limit for how many sync prims can be allocated from the block. */\n   uint32_t max_count;\n"
     "   /* A01: CPU mapping of the block (NULL if it could not be mapped). */\n"
     "   volatile uint32_t *a01_cpu;\n")

edit(W / "pvr_srv_sync_prim.c",
     "   srv_ws->sync_prim_ctx.max_count = max_size / PVR_SRV_SYNC_PRIM_VALUE_SIZE;\n",
     "   srv_ws->sync_prim_ctx.max_count = max_size / PVR_SRV_SYNC_PRIM_VALUE_SIZE;\n"
     "#if defined(__APPLE__)\n"
     "   {\n"
     "      extern int a01drm_map_pmr(int fd, uint64_t pmr_handle, void **map);\n"
     "      void *a01_map = NULL;\n"
     "      srv_ws->sync_prim_ctx.a01_cpu =\n"
     "         a01drm_map_pmr(srv_ws->base.render_fd, (uint64_t)(uintptr_t)sync_block_pmr, &a01_map) == 0\n"
     "            ? (volatile uint32_t *)a01_map\n"
     "            : NULL;\n"
     "      mesa_logi(\"A01: sync prim block %s\", srv_ws->sync_prim_ctx.a01_cpu ? \"mapped\" : \"NOT mapped\");\n"
     "   }\n"
     "#endif\n")

# ---- fences: address + value ----------------------------------------------------------------
edit(W / "pvr_srv_sync.h", "#include <stddef.h>\n", "#include <stddef.h>\n#include <stdint.h>\n")
edit(W / "pvr_srv_sync.h",
     "   int fd;\n};\n",
     "   int fd;\n"
     "#if defined(__APPLE__)\n"
     "   /* A01: pending until the firmware writes a01_value (or later) here. */\n"
     "   volatile const uint32_t *a01_addr;\n"
     "   uint32_t a01_value;\n"
     "   uint64_t a01_t0;\n"
     "#endif\n"
     "};\n")
edit(W / "pvr_srv_sync.h",
     "void pvr_srv_set_sync_payload(struct pvr_srv_sync *srv_sync, int payload);\n",
     "void pvr_srv_set_sync_payload(struct pvr_srv_sync *srv_sync, int payload);\n"
     "#if defined(__APPLE__)\n"
     "struct pvr_srv_sync_prim;\n"
     "void pvr_srv_set_sync_prim_payload(struct pvr_srv_sync *srv_sync,\n"
     "                                   const struct pvr_srv_sync_prim *prim,\n"
     "                                   uint32_t value);\n"
     "#endif\n")

S = W / "pvr_srv_sync.c"
edit(S,
     "   srv_sync->signaled = initial_value ? true : false;\n   srv_sync->fd = -1;\n",
     "   srv_sync->signaled = initial_value ? true : false;\n   srv_sync->fd = -1;\n"
     "#if defined(__APPLE__)\n   srv_sync->a01_addr = NULL;\n#endif\n")
edit(S,
     "   srv_sync->signaled = signaled;\n}\n",
     "   srv_sync->signaled = signaled;\n"
     "#if defined(__APPLE__)\n   srv_sync->a01_addr = NULL;\n#endif\n}\n")
edit(S,
     "   srv_sync->fd = payload;\n   srv_sync->signaled = (payload == -1);\n}\n",
     "   srv_sync->fd = payload;\n   srv_sync->signaled = (payload == -1);\n"
     "#if defined(__APPLE__)\n   srv_sync->a01_addr = NULL;\n#endif\n}\n\n"
     "#if defined(__APPLE__)\n"
     "#include \"pvr_srv_sync_prim.h\"\n"
     "void pvr_srv_set_sync_prim_payload(struct pvr_srv_sync *srv_sync,\n"
     "                                   const struct pvr_srv_sync_prim *prim,\n"
     "                                   uint32_t value)\n"
     "{\n"
     "   if (srv_sync->fd != -1) {\n"
     "      close(srv_sync->fd);\n"
     "      srv_sync->fd = -1;\n"
     "   }\n"
     "   if (!prim || !prim->ctx || !prim->ctx->a01_cpu) {\n"
     "      srv_sync->a01_addr = NULL;\n"
     "      srv_sync->signaled = true;   /* no mapping: old behaviour */\n"
     "      return;\n"
     "   }\n"
     "   srv_sync->a01_addr = prim->ctx->a01_cpu + prim->offset / 4U;\n"
     "   srv_sync->a01_value = value;\n"
     "   srv_sync->a01_t0 = os_time_get_nano();\n"
     "   srv_sync->signaled = false;\n"
     "}\n"
     "#endif\n")
edit(S,
     "   /* If fd is -1 and this is not signaled, the fence is in pending mode */\n",
     "#if defined(__APPLE__)\n"
     "   if (srv_sync->a01_addr) {\n"
     "      /* the firmware writes increasing values; compare with wrap-around */\n"
     "      if ((int32_t)(*srv_sync->a01_addr - srv_sync->a01_value) >= 0 ||\n"
     "          os_time_get_nano() - srv_sync->a01_t0 > 2000000000ULL) {\n"
     "         srv_sync->a01_addr = NULL;\n"
     "         srv_sync->signaled = true;\n"
     "         return VK_SUCCESS;\n"
     "      }\n"
     "      return VK_TIMEOUT;\n"
     "   }\n"
     "#endif\n\n"
     "   /* If fd is -1 and this is not signaled, the fence is in pending mode */\n")
edit(S,
     "      pvr_srv_set_sync_payload(srv_dst_sync, srv_src_sync->fd);\n      srv_src_sync->fd = -1;\n",
     "      pvr_srv_set_sync_payload(srv_dst_sync, srv_src_sync->fd);\n      srv_src_sync->fd = -1;\n"
     "#if defined(__APPLE__)\n"
     "      if (srv_src_sync->a01_addr) {\n"
     "         srv_dst_sync->a01_addr = srv_src_sync->a01_addr;\n"
     "         srv_dst_sync->a01_value = srv_src_sync->a01_value;\n"
     "         srv_dst_sync->a01_t0 = srv_src_sync->a01_t0;\n"
     "         srv_dst_sync->signaled = false;\n"
     "      } else {\n"
     "         srv_dst_sync->signaled = srv_src_sync->signaled;\n"
     "      }\n"
     "#endif\n")

# ---- render: geometry / fragment update values -----------------------------------------------
R = W / "pvr_arch_srv_job_render.c"
edit(R,
     "      pvr_srv_set_sync_payload(srv_signal_sync_geom, fence_geom);\n",
     "#if defined(__APPLE__)\n"
     "      if (fence_geom == -1)\n"
     "         pvr_srv_set_sync_prim_payload(srv_signal_sync_geom, sync_prim, geom_sync_update_value);\n"
     "      else\n"
     "#endif\n"
     "      pvr_srv_set_sync_payload(srv_signal_sync_geom, fence_geom);\n")
edit(R,
     "      pvr_srv_set_sync_payload(srv_signal_sync_frag, fence_frag);\n",
     "#if defined(__APPLE__)\n"
     "      if (fence_frag == -1)\n"
     "         pvr_srv_set_sync_prim_payload(srv_signal_sync_frag, sync_prim,\n"
     "                                       frag_sync_update_count ? frag_sync_update_value\n"
     "                                                              : geom_sync_update_value);\n"
     "      else\n"
     "#endif\n"
     "      pvr_srv_set_sync_payload(srv_signal_sync_frag, fence_frag);\n")

# ---- compute: one sync prim per context, client update on each kick --------------------------
edit(W / "pvr_srv_job_compute.h",
     "   void *handle;\n\n   int timeline;\n};\n",
     "   void *handle;\n\n   int timeline;\n"
     "#if defined(__APPLE__)\n   struct pvr_srv_sync_prim *a01_prim;\n#endif\n};\n")
C = W / "pvr_arch_srv_job_compute.c"
edit(C,
     "   do {\n      result = pvr_srv_rgx_kick_compute2(srv_ws->base.render_fd,\n"
     "                                         srv_ctx->handle,\n"
     "                                         0U,\n"
     "                                         NULL,\n"
     "                                         NULL,\n"
     "                                         NULL,\n",
     "#if defined(__APPLE__)\n"
     "   struct pvr_srv_sync_prim *a01_prim = srv_ctx->a01_prim;\n"
     "   if (!a01_prim) {\n"
     "      a01_prim = pvr_srv_sync_prim_alloc((struct pvr_srv_winsys *)srv_ws);\n"
     "      ((struct pvr_srv_winsys_compute_ctx *)srv_ctx)->a01_prim = a01_prim;\n"
     "   }\n"
     "   uint32_t a01_value = a01_prim ? a01_prim->value + 1U : 0U;\n"
     "#endif\n"
     "   do {\n      result = pvr_srv_rgx_kick_compute2(srv_ws->base.render_fd,\n"
     "                                         srv_ctx->handle,\n"
     "#if defined(__APPLE__)\n"
     "                                         a01_prim ? 1U : 0U,\n"
     "                                         a01_prim ? &a01_prim->ctx->block_handle : NULL,\n"
     "                                         a01_prim ? &a01_prim->offset : NULL,\n"
     "                                         a01_prim ? &a01_value : NULL,\n"
     "#else\n"
     "                                         0U,\n"
     "                                         NULL,\n"
     "                                         NULL,\n"
     "                                         NULL,\n"
     "#endif\n")
edit(C,
     "   if (signal_sync) {\n      srv_signal_sync = to_srv_sync(signal_sync);\n"
     "      pvr_srv_set_sync_payload(srv_signal_sync, fence);\n",
     "#if defined(__APPLE__)\n"
     "   if (a01_prim)\n      a01_prim->value = a01_value;\n"
     "#endif\n"
     "   if (signal_sync) {\n      srv_signal_sync = to_srv_sync(signal_sync);\n"
     "#if defined(__APPLE__)\n"
     "      if (fence == -1 && a01_prim)\n"
     "         pvr_srv_set_sync_prim_payload(srv_signal_sync, a01_prim, a01_value);\n"
     "      else\n"
     "#endif\n"
     "      pvr_srv_set_sync_payload(srv_signal_sync, fence);\n")

# ---- transfer: same, update on the last prepare of the submit --------------------------------
edit(W / "pvr_srv_job_transfer.h",
     "   void *handle;\n\n   int timeline_3d;\n};\n",
     "   void *handle;\n\n   int timeline_3d;\n"
     "#if defined(__APPLE__)\n   struct pvr_srv_sync_prim *a01_prim;\n#endif\n};\n")
T = W / "pvr_arch_srv_job_transfer.c"
edit(T,
     "   job_num = submit_info->job_num;\n",
     "   job_num = submit_info->job_num;\n"
     "#if defined(__APPLE__)\n"
     "   struct pvr_srv_sync_prim *a01_prim = srv_ctx->a01_prim;\n"
     "   if (!a01_prim) {\n"
     "      a01_prim = pvr_srv_sync_prim_alloc((struct pvr_srv_winsys *)srv_ws);\n"
     "      ((struct pvr_srv_winsys_transfer_ctx *)srv_ctx)->a01_prim = a01_prim;\n"
     "   }\n"
     "   uint32_t a01_value = a01_prim ? a01_prim->value + 1U : 0U;\n"
     "   if (a01_prim) {\n"
     "      const uint32_t last = submit_info->cmd_count - 1U;\n"
     "      client_update_count[last] = 1U;\n"
     "      update_ufo_syc_prims[last] = &a01_prim->ctx->block_handle;\n"
     "      update_sync_offsets[last] = &a01_prim->offset;\n"
     "      update_values[last] = &a01_value;\n"
     "   }\n"
     "#endif\n")
edit(T,
     "   if (signal_sync) {\n      srv_signal_sync = to_srv_sync(signal_sync);\n"
     "      pvr_srv_set_sync_payload(srv_signal_sync, fence);\n",
     "#if defined(__APPLE__)\n"
     "   if (a01_prim)\n      a01_prim->value = a01_value;\n"
     "#endif\n"
     "   if (signal_sync) {\n      srv_signal_sync = to_srv_sync(signal_sync);\n"
     "#if defined(__APPLE__)\n"
     "      if (fence == -1 && a01_prim)\n"
     "         pvr_srv_set_sync_prim_payload(srv_signal_sync, a01_prim, a01_value);\n"
     "      else\n"
     "#endif\n"
     "      pvr_srv_set_sync_payload(srv_signal_sync, fence);\n")

for path, inc in [(C, '#include "pvr_srv_sync_prim.h"'), (T, '#include "pvr_srv_sync_prim.h"')]:
    t = path.read_text()
    if inc not in t:
        t = t.replace('#include "pvr_srv_bridge.h"\n', '#include "pvr_srv_bridge.h"\n' + inc + "\n", 1)
        path.write_text(t)
print("A01 GPU completion fences (sync prims) applied")
