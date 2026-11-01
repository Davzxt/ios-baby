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
