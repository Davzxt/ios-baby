#!/usr/bin/env python3
"""Galaxy A01 Core additions to a Mesa 25.0.x tree already patched by gpu/mesa/patch-mesa.py.

  patch-a01gl.py MESA_DIR

- OSMesa without Panfrost: gpu/a01gl/a01_hw_stub.c answers the HeroGPU hooks that
  osmesa_hero.inc calls ("no hardware blit"), so the EAGL shim takes its CPU-copy path.
- Zink loads Vulkan from /private/var/a01/lib/libvulkan.1.dylib (gpu/a01gl/a01vkloader.c, which
  hands Zink the GE8100 ICD); iOS has no Khronos loader and no library search path for it.
"""
import shutil
import sys
from pathlib import Path

mesa = Path(sys.argv[1])
here = Path(__file__).resolve().parent


def edit(rel, old, new):
    path = mesa / rel
    text = path.read_text()
    assert text.count(old) == 1, f'{rel}: expected text found {text.count(old)} times:\n{old}'
    path.write_text(text.replace(old, new))
    print('patched', rel)


edit('src/gallium/targets/osmesa/meson.build',
     "if host_machine.system() == 'darwin' and with_gallium_panfrost\n"
     "  osmesa_hero_files += 'hero_hw.c'\n",
     "if host_machine.system() == 'darwin' and not with_gallium_panfrost\n"
     "  osmesa_hero_files += 'a01_hw_stub.c'\n"
     "endif\n"
     "if host_machine.system() == 'darwin' and with_gallium_panfrost\n"
     "  osmesa_hero_files += 'hero_hw.c'\n")
shutil.copy(here / 'a01_hw_stub.c', mesa / 'src/gallium/targets/osmesa/a01_hw_stub.c')
print('copied a01_hw_stub.c')

hits = 0
for path in sorted((mesa / 'src/gallium/drivers/zink').rglob('*.[ch]')):
    text = path.read_text(errors='surrogateescape')
    if '"libvulkan.1.dylib"' in text:
        path.write_text(text.replace('"libvulkan.1.dylib"', '"/private/var/a01/lib/libvulkan.1.dylib"'),
                        errors='surrogateescape')
        hits += 1
        print('patched', path.relative_to(mesa))
assert hits > 0, 'zink: no "libvulkan.1.dylib" found (Mesa changed how Zink names the loader)'
