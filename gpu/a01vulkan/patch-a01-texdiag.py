#!/usr/bin/env python3
"""Texture descriptor diagnostics (Galaxy A01 Core).

Every textured draw faults on the GE8100 (TCU reads of c0c0c0f140 / 240), even a 2x2 LINEAR
texture written by the CPU (a01vktex V2), while untextured draws are right. To see whether the
texture state the driver writes is already wrong, the first 4 combined image/sampler descriptors
are printed (stderr, which A01's test shows on the console): the descriptor's GPU address, the
image's GPU address and the two image state words plus the first sampler word.

  patch-a01-texdiag.py MESA_DIR
"""
import pathlib
import sys

f = pathlib.Path(sys.argv[1]) / "src/imagination/vulkan/pvr_arch_descriptor_set.c"
t = f.read_text()
old = "   memcpy(desc_mapping, &image_sampler_desc, sizeof(image_sampler_desc));\n}\n"
if t.count(old) != 1:
    raise SystemExit("pvr_arch_descriptor_set.c: write_image_sampler memcpy not found")
new = ("   memcpy(desc_mapping, &image_sampler_desc, sizeof(image_sampler_desc));\n"
       "#if defined(__APPLE__)\n"
       "   {\n"
       "      static int a01_n;\n"
       "      if (a01_n < 4 && image_info->imageView != VK_NULL_HANDLE) {\n"
       "         VK_FROM_HANDLE(pvr_image_view, a01_v, image_info->imageView);\n"
       "         const struct pvr_image *a01_i = pvr_image_view_get_image(a01_v);\n"
       "         a01_n++;\n"
       "         fprintf(stderr, \"A01 >>> VD%d: d %llx i %llx W %016llx %016llx S %016llx <<<\\n\", a01_n,\n"
       "                 (unsigned long long)(set->dev_addr.addr + desc_offset),\n"
       "                 (unsigned long long)a01_i->dev_addr.addr,\n"
       "                 (unsigned long long)image_sampler_desc.image.words[0],\n"
       "                 (unsigned long long)image_sampler_desc.image.words[1],\n"
       "                 (unsigned long long)image_sampler_desc.sampler.words[0]);\n"
       "      }\n"
       "   }\n"
       "#endif\n"
       "}\n")
t = t.replace(old, new, 1)
if "#include <stdio.h>" not in t:
    t = "#include <stdio.h>\n" + t
f.write_text(t, newline="\n")
print("pvr_arch_descriptor_set.c: first 4 image/sampler descriptors printed")
