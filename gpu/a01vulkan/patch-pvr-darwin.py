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
