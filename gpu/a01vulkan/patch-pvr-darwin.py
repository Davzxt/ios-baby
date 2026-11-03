#!/usr/bin/env python3
"""Darwin fixes for Mesa's PowerVR Vulkan driver (iOS build of the A01 Core)."""
import pathlib, sys

mesa = pathlib.Path(sys.argv[1])
f = mesa / "src/imagination/vulkan/pvr_image.c"
t = f.read_text()
old = "   if (pCreateInfo->tiling == VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT) {"
if old in t and "A01: DRM format modifiers" not in t:
    i = t.index(old)
    j = t.index("\n   }\n", i) + len("\n   }\n")
    t = t[:i] + "#if DETECT_OS_LINUX || DETECT_OS_BSD /* A01: DRM format modifiers are Linux/BSD only (vk_image.h) */\n" + t[i:j] + "#endif\n" + t[j:]
    f.write_text(t)
    print("pvr_image.c: DRM modifier block guarded")

# Mesa's weak entrypoints may stay undefined on Darwin; only the driver's own link allows it
# (a global -undefined dynamic_lookup would fool meson's compiler checks).
f = mesa / "src/imagination/vulkan/meson.build"
t = f.read_text()
old = "  link_args : [\n    vulkan_icd_link_args,"
if old in t and "dynamic_lookup" not in t:
    t = t.replace(old, "  link_args : [\n    '-Wl,-undefined,dynamic_lookup',\n    vulkan_icd_link_args,", 1)
    f.write_text(t)
    print("meson.build: driver links with -undefined dynamic_lookup")

# PMR CPU mappings: Linux mmaps the render node at offset = handle; on iOS the A01CoreGPU user
# client maps the PMR (a01drm_map_pmr in gpu/a01vulkan/a01drm.c). The fixed address hint is not
# honoured: the kernel picks the address.
f = mesa / "src/imagination/vulkan/winsys/pvrsrvkm/pvr_srv_bo.c"
t = f.read_text()
old = """   result = pvr_mmap(addr,
                     bo->size,
                     prot,
                     MAP_SHARED,
                     ws->render_fd,
                     (off_t)srv_bo->pmr << ws->log2_page_size,
                     &bo->map);
"""
new = """#if defined(__APPLE__)
   {
      extern int a01drm_map_pmr(int fd, uint64_t pmr_handle, void **map);
      (void)addr;
      (void)prot;
      result = a01drm_map_pmr(ws->render_fd, (uint64_t)(uintptr_t)srv_bo->pmr, &bo->map)
                  ? VK_ERROR_MEMORY_MAP_FAILED
                  : VK_SUCCESS;
   }
#else
""" + old + "#endif\n"
if old in t and "a01drm_map_pmr" not in t:
    t = t.replace(old, new, 1)
    f.write_text(t)
    print("pvr_srv_bo.c: PMR maps through A01CoreGPU")
elif "a01drm_map_pmr" not in t:
    raise SystemExit("pvr_srv_bo.c: mmap call not found")

# vk_drm_syncobj.c is Linux-only, but Mesa still references two of its functions: the common runtime
# compares sync types with vk_drm_syncobj_finish, and the upstream-DRM winsys (pvr_drm.c, unused with
# the srv backend) calls vk_drm_syncobj_get_type. Left undefined, dyld refuses to load the driver on
# iOS. pvr_drm.c includes vk_drm_syncobj.h, so the definitions there use the real prototypes; the empty
# sync type returned has no features, so nothing selects it.
f = mesa / "src/imagination/vulkan/winsys/powervr/pvr_drm.c"
t = f.read_text()
if "A01: Linux-only vk_drm_syncobj" not in t:
    t += """
#if defined(__APPLE__) /* A01: Linux-only vk_drm_syncobj.c is not built on Darwin */
void vk_drm_syncobj_finish(struct vk_device *device, struct vk_sync *sync)
{
   (void)device;
   (void)sync;
}

struct vk_sync_type vk_drm_syncobj_get_type(int drm_fd)
{
   (void)drm_fd;
   return (struct vk_sync_type){ 0 };
}
#endif
"""
    f.write_text(t)
    print("pvr_drm.c: vk_drm_syncobj stubs for Darwin")

# Mesa's Darwin build_id_find_nhdr_for_addr returns the Mach-O LC_UUID (16 bytes), while pvr wants an
# ELF SHA-1 build-id (20) and fails vkCreateInstance ("Build-id too short"). copy_build_id_to_sha1
# zero-pads shorter ids, so the 16-byte UUID is enough on Darwin.
f = mesa / "src/imagination/vulkan/pvr_instance.c"
t = f.read_text()
old = "   if (build_id_len < BUILD_ID_EXPECTED_HASH_LENGTH) {"
if old in t and "A01: Mach-O LC_UUID" not in t:
    t = t.replace(old, """#if defined(__APPLE__) /* A01: Mach-O LC_UUID is 16 bytes */
   if (build_id_len < 16) {
#else
""" + old + "\n#endif", 1)
    f.write_text(t)
    print("pvr_instance.c: 16-byte Mach-O UUID accepted as build-id")
elif "A01: Mach-O LC_UUID" not in t:
    raise SystemExit("pvr_instance.c: build-id length check not found")

# CPU unmaps: the A01CoreGPU kernel keeps every user mapping of a PMR (IOMemoryMap) and removes it
# when the PMR is freed. A munmap here first gives the range back to the task; malloc then reuses
# it, and the kernel's later unmap destroys malloc's memory (on the phone: stuck in free() inside
# vkCreateDevice). So the range stays mapped until the PMR goes; a01drm_map_pmr hands the same
# address back if the BO is mapped again.
f = mesa / "src/imagination/vulkan/winsys/pvrsrvkm/pvr_srv_bo.c"
t = f.read_text()
old = "   result = pvr_munmap(bo->map, bo->size, reserve);\n"
new = """#if defined(__APPLE__)
   /* A01: the kernel unmaps when the PMR is freed (see a01drm_map_pmr) */
   (void)reserve;
   result = VK_SUCCESS;
#else
   result = pvr_munmap(bo->map, bo->size, reserve);
#endif
"""
if old in t and "A01: the kernel unmaps" not in t:
    t = t.replace(old, new, 1)
    f.write_text(t)
    print("pvr_srv_bo.c: CPU unmap left to the kernel")
elif "A01: the kernel unmaps" not in t:
    raise SystemExit("pvr_srv_bo.c: munmap in buffer_unmap not found")

# vkCreateDevice compiles 20 SPM load shaders up front (2 sample modes x (3 output-reg counts +
# 7 tile-buffer counts)). On the single A53 that alone took minutes (phone: sampled in
# pvr_uscgen_spm_load -> pco_nir_opt). They only run when the parameter buffer overflows mid
# render. On Darwin one shader, the widest single-sample one without tile buffers, fills every
# slot.
f = mesa / "src/imagination/vulkan/pvr_arch_spm.c"
t = f.read_text()
if "A01: one SPM load shader" not in t:
    i = t.index("   for (unsigned is_multisampled = 0; is_multisampled <= 1; ++is_multisampled) {")
    j = t.index("   result = pvr_bo_suballoc(&device->suballoc_usc,", i)
    loops = t[i:j]
    t = t[:i] + """#if defined(__APPLE__) /* A01: one SPM load shader for every slot */
   props = (struct pvr_spm_load_props){
      .output_reg_count = 4,
      .tile_buffer_count = 0,
      .is_multisampled = 0,
   };
   {
      pco_shader *one = pvr_uscgen_spm_load(device->pdevice->pco_ctx, &props);
      for (unsigned u = 0; u < ARRAY_SIZE(shaders); ++u) {
         shaders[u] = one;
         usc_allocation_size += pco_shader_binary_size(one);
      }
   }
#else
""" + loops + "#endif\n\n" + t[j:]
    old = "   for (unsigned u = 0; u < ARRAY_SIZE(shaders); ++u)\n      ralloc_free(shaders[u]);\n"
    if old not in t:
        raise SystemExit("pvr_arch_spm.c: shader free loop not found")
    t = t.replace(old, "#if defined(__APPLE__)\n   ralloc_free(shaders[0]);   /* A01: the one shared shader */\n#else\n" + old + "#endif\n", 1)
    f.write_text(t)
    print("pvr_arch_spm.c: one SPM load shader on Darwin")

# Timelines: DDK 1.11 creates them by opening Linux's /dev/pvr_sync, which XNU does not have; the
# failed open made vkCreateDevice return VK_ERROR_UNKNOWN when the queues' contexts were created
# (phone: VkResult -13 with no bridge error). On Darwin a context gets no timeline (-1, the DDK's
# PVRSRV_NO_TIMELINE): kicks then return no fence and Mesa treats the job's sync as signalled.
# Completion is not tracked by fences yet (A01Metal waits after a submit).
f = mesa / "src/imagination/vulkan/winsys/pvrsrvkm/pvr_srv_job_common.c"
t = f.read_text()
old = '   fd = open("/dev/pvr_sync", O_CLOEXEC | O_RDWR);\n'
if old in t and "A01: no /dev/pvr_sync" not in t:
    t = t.replace(old, '#if defined(__APPLE__) /* A01: no /dev/pvr_sync on XNU */\n   *fd_out = -1;\n   return VK_SUCCESS;\n#endif\n' + old, 1)
    f.write_text(t)
    print("pvr_srv_job_common.c: no timelines on Darwin")
elif "A01: no /dev/pvr_sync" not in t:
    raise SystemExit("pvr_srv_job_common.c: /dev/pvr_sync open not found")
f = mesa / "src/imagination/vulkan/winsys/pvrsrvkm/pvr_srv_bridge.c"
t = f.read_text()
old = "   if (ioctl(sw_timeline_fd, _IO('W', 5)) < 0) {\n"
if old in t and "A01: no timeline" not in t:
    t = t.replace(old, "   if (sw_timeline_fd < 0) /* A01: no timeline on XNU */\n      return VK_SUCCESS;\n" + old, 1)
    f.write_text(t)
    print("pvr_srv_bridge.c: FORCE_SW_ONLY skipped without a timeline")
elif "A01: no timeline" not in t:
    raise SystemExit("pvr_srv_bridge.c: FORCE_SW_ONLY ioctl not found")

# GE8100 firmware command layouts. Its alignment checks (printed by the A01 kernel at boot) give
# RGXFWIF_CMDTA 136 and RGXFWIF_CMD3D 336 bytes; img-pvr's DDK 1.11 structs, reverse-engineered on
# a GE8320, are 128 and 328 (transfer 208 and compute 64 agree). The GE8100 firmware is built with
# errata the GE8320's is not (BRN 60084, 61450, 63027, 65168, 65273). BRN 63027 adds the 64-bit
# dummy region header register after the TA's partial-render fence (DDK 1.17 keeps it there);
# the 3D one sits at the end of the 3D registers, before the flags, where DDK errata registers go:
# the firmware then read hw_rt_data 8 bytes later, where img-pvr has a zero, and discarded every 3D
# command ("Discarded cmd on DM3 (reason=0) HWRTData=0x00000000"). On Darwin each command is sent
# with 8 zero bytes inserted at those offsets; A01_PVR_TA_PAD / A01_PVR_3D_PAD (byte offsets)
# move them without a rebuild.
f = mesa / "src/imagination/vulkan/winsys/pvrsrvkm/pvr_arch_srv_job_render.c"
t = f.read_text()
if "A01: GE8100 command layout" not in t:
    helper = """
#if defined(__APPLE__) /* A01: GE8100 command layout (TA 136, 3D 336 bytes) */
#include <stdlib.h>
static uint32_t
a01_pad_at(const char *env, uint32_t dflt, uint32_t size)
{
   const char *e = getenv(env);
   uint32_t v = e ? (uint32_t)strtoul(e, NULL, 0) : dflt;
   return v <= size ? v : dflt;
}

static void
a01_insert8(uint8_t *dst, const void *src, uint32_t size, uint32_t at)
{
   memcpy(dst, src, at);
   memset(dst + at, 0, 8);
   memcpy(dst + at + 8, (const uint8_t *)src + at, size - at);
}
#endif
"""
    anchor = "\nstatic void srv_geometry_cmd_init("
    if anchor not in t:
        anchor = "\nstatic void\nsrv_geometry_cmd_init("
    if anchor not in t:
        raise SystemExit("pvr_arch_srv_job_render.c: srv_geometry_cmd_init not found")
    t = t.replace(anchor, helper + anchor, 1)

    old = "   do {\n      /* The fw allows the ZS and MSAA scratch buffers to be lazily allocated in\n"
    if t.count(old) != 1:
        raise SystemExit("pvr_arch_srv_job_render.c: kick loop not found")
    pad = """#if defined(__APPLE__)
   uint8_t a01_geom[sizeof(geom_cmd) + 8], a01_pr[sizeof(pr_cmd) + 8], a01_frag[sizeof(frag_cmd) + 8];
   {
      const uint32_t ta_at = a01_pad_at("A01_PVR_TA_PAD",
         offsetof(struct ddk111_fwif_cmd_ta, partial_render_ta_3d_fence) + 8, sizeof(geom_cmd));
      const uint32_t f_at = a01_pad_at("A01_PVR_3D_PAD",
         offsetof(struct ddk111_fwif_cmd_3d, flags), sizeof(pr_cmd));
      a01_insert8(a01_geom, &geom_cmd, sizeof(geom_cmd), ta_at);
      a01_insert8(a01_pr, &pr_cmd, sizeof(pr_cmd), f_at);
      if (frag_cmd_ptr) {
         a01_insert8(a01_frag, frag_cmd_ptr, frag_cmd_size, f_at);
         frag_cmd_ptr = a01_frag;
         frag_cmd_size += 8;
      }
   }
#endif
"""
    t = t.replace(old, pad + old, 1)

    old = """                                        sizeof(geom_cmd),
                                        (uint8_t *)&geom_cmd,
                                        sizeof(pr_cmd),
                                        (uint8_t *)&pr_cmd,
"""
    new = """#if defined(__APPLE__)
                                        sizeof(a01_geom),
                                        a01_geom,
                                        sizeof(a01_pr),
                                        a01_pr,
#else
                                        sizeof(geom_cmd),
                                        (uint8_t *)&geom_cmd,
                                        sizeof(pr_cmd),
                                        (uint8_t *)&pr_cmd,
#endif
"""
    if t.count(old) != 1:
        raise SystemExit("pvr_arch_srv_job_render.c: kick arguments not found")
    t = t.replace(old, new, 1)
    f.write_text(t)
    print("pvr_arch_srv_job_render.c: TA/3D commands padded to the GE8100 firmware layout")

# Page units: iOS's CPU page is 16 KiB (ws->page_size), the GPU heaps' pages are 4 KiB. The DDK's
# DevmemIntMapPages/UnmapPages count pages and offsets in the HEAP's page size, but img-pvr shifted
# by the winsys (CPU) page size, which is the same on Linux. On the phone a 16 KiB buffer got only
# its first 4 KiB mapped (and a 4 KiB buffer none): the GPU faulted writing 8 KiB into one
# (PBE write to 0x65C00C6000).
f = mesa / "src/imagination/vulkan/winsys/pvrsrvkm/pvr_srv_bo.c"
t = f.read_text()
if "A01: heap page units" not in t:
    pairs = [
        ("""      const uint32_t phys_page_offset = (offset - virt_offset) >>
                                        srv_ws->base.log2_page_size;
      const uint32_t phys_page_count = aligned_virt_size >>
                                       srv_ws->base.log2_page_size;
""",
         """      /* A01: heap page units (DevmemIntMapPages), not the CPU page size */
      const uint32_t phys_page_offset = (offset - virt_offset) >>
                                        vma->heap->log2_page_size;
      const uint32_t phys_page_count = aligned_virt_size >>
                                       vma->heap->log2_page_size;
"""),
        ("""                              vma->mapped_size >> srv_ws->base.log2_page_size);
""",
         """                              vma->mapped_size >> vma->heap->log2_page_size);
"""),
    ]
    for old, new in pairs:
        if t.count(old) != 1:
            raise SystemExit("pvr_srv_bo.c: page-unit site not found: " + old.strip()[:60])
        t = t.replace(old, new, 1)
    f.write_text(t)
    print("pvr_srv_bo.c: GPU map/unmap in heap page units")

# A01 diagnostics: the first TQ copy's source image state, as one console line the user can type
# (the GE8100 faults with a TCU read of 0x8DFBB2A940 on vkCmdCopyBuffer while fill, clear and
# a shaded triangle work). Printed to stderr, which the GPU test shows on the console.
f = mesa / "src/imagination/vulkan/pvr_arch_job_transfer.c"
t = f.read_text()
if "A01 >>> VK: src" not in t:
    old = """      result = pvr_sampler_image_state(ctx,
                                       transfer_cmd,
                                       sh_reg_layout,
                                       state,
                                       dma_space);
      if (result != VK_SUCCESS)
         return result;
"""
    if t.count(old) != 1:
        raise SystemExit("pvr_arch_job_transfer.c: sampler/image state call not found")
    new = old + """#if defined(__APPLE__)
      {
         static int a01_once;
         if (!a01_once++) {
            const struct pvr_transfer_cmd_surface *a01_s = &transfer_cmd->sources[0].surface;
            const uint32_t a01_io = sh_reg_layout->combined_image_samplers.offsets[0].image;
            const uint32_t a01_so = sh_reg_layout->combined_image_samplers.offsets[0].sampler;
            uint64_t a01_w[2];
            memcpy(a01_w, dma_space + a01_io, sizeof(a01_w));
            fprintf(stderr, "A01 >>> VK: src %llx L%u %ux%u cp%u n%u i%u s%u W1 %016llx <<<\\n",
                    (unsigned long long)a01_s->dev_addr.addr, (unsigned)a01_s->mem_layout,
                    a01_s->width, a01_s->height, state->common_ptr, tex_state_dma_size_dw,
                    a01_io, a01_so, (unsigned long long)a01_w[1]);
         }
      }
#endif
"""
    t = t.replace(old, new, 1)
    if "#include <stdio.h>" not in t:
        t = "#include <stdio.h>\n" + t
    f.write_text(t)
    print("pvr_arch_job_transfer.c: first TQ source state printed")

# A01 experiment: PDS DOUTD (the DMA that loads image/sampler state and constants into the USC
# common store) reads through the GPU caches in CMODE_CACHED. The GE8100 has an 8 KiB SLC set up
# differently from the GE8320 (SLCSIZE8 / BRN 61450 bypasses); its TQ copy faults with the image
# state written correctly by the CPU, as if the shader saw stale state. Bypass the caches for these
# DMAs on Darwin (A01_PDS_DMA_CACHED=1 restores the original).
f = mesa / "src/imagination/vulkan/pds/pvr_pds.c"
t = f.read_text()
if "A01: DOUTD cache bypass" not in t:
    old = """   dma_control[0] |= PVR_ROGUE_PDSINST_DOUT_FIELDS_DOUTD_SRC1_CMODE_CACHED |
                     PVR_ROGUE_PDSINST_DOUT_FIELDS_DOUTD_SRC1_DEST_COMMON_STORE;
"""
    if t.count(old) != 1:
        raise SystemExit("pvr_pds.c: DOUTD control word not found")
    new = """#if defined(__APPLE__) /* A01: DOUTD cache bypass (GE8100) */
   {
      const char *a01_c = getenv("A01_PDS_DMA_CACHED");
      dma_control[0] |= ((a01_c && a01_c[0] == '1')
                            ? PVR_ROGUE_PDSINST_DOUT_FIELDS_DOUTD_SRC1_CMODE_CACHED
                            : PVR_ROGUE_PDSINST_DOUT_FIELDS_DOUTD_SRC1_CMODE_BYPASS) |
                        PVR_ROGUE_PDSINST_DOUT_FIELDS_DOUTD_SRC1_DEST_COMMON_STORE;
   }
#else
""" + old + "#endif\n"
    t = t.replace(old, new, 1)
    if "#include <stdlib.h>" not in t:
        t = "#include <stdlib.h>\n" + t
    f.write_text(t)
    print("pvr_pds.c: DOUTD bypasses the GPU caches on Darwin")
