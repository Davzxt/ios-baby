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

# vk_drm_syncobj.c is Linux-only, but the common runtime still references vk_drm_syncobj_finish
# (vk_sync_type_is_drm_syncobj compares a type's finish hook with it). Left undefined, dyld refuses
# to load the driver on iOS. No sync type uses it here, so an empty definition keeps the
# comparison false. The asm label avoids clashing with the prototype in vk_drm_syncobj.h.
f = mesa / "src/imagination/vulkan/pvr_device.c"
t = f.read_text()
if "a01_vk_drm_syncobj_finish" not in t:
    t += """
#if defined(__APPLE__)
void a01_vk_drm_syncobj_finish(void *device, void *sync) __asm__("_vk_drm_syncobj_finish");
void a01_vk_drm_syncobj_finish(void *device, void *sync)
{
   (void)device;
   (void)sync;
}
#endif
"""
    f.write_text(t)
    print("pvr_device.c: vk_drm_syncobj_finish defined for Darwin")
