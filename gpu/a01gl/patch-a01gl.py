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

# Zink inside OSMesa. Mesa links only driver_swrast into libOSMesa, so GALLIUM_ZINK is undefined in
# osmesa_target.c and GALLIUM_DRIVER=zink finds no driver: every "Zink" package on the phone drew
# with the CPU (checked: no zink symbol in libOSMesa.8.dylib; the kernel saw no backboardd GPU
# open). Link driver_zink, and if Zink cannot start, log why (MESA_LOG_FILE, shown on the phone's
# console) and fall back to softpipe so the UI still comes up.
edit('src/gallium/targets/osmesa/meson.build',
     "    osmesa_hero_deps,\n",
     "    osmesa_hero_deps,\n"
     "    with_gallium_zink ? [driver_zink, idep_xmlconfig] : [],\n")

edit('src/gallium/auxiliary/target-helpers/sw_helper.h',
     "#if defined(GALLIUM_ZINK)\n"
     "   if (screen == NULL && strcmp(driver, \"zink\") == 0)\n"
     "      screen = zink_create_screen(winsys, config);\n"
     "#endif\n",
     "#if defined(GALLIUM_ZINK)\n"
     "   if (screen == NULL && strcmp(driver, \"zink\") == 0) {\n"
     "      screen = zink_create_screen(winsys, config);\n"
     "      mesa_loge(\"A01: zink %s\", screen ? \"ativo (GPU)\" : \"falhou ao abrir a GPU\");\n"
     "   }\n"
     "#endif\n")
edit('src/gallium/auxiliary/target-helpers/sw_helper.h',
     "      else if (i == 0 && drivers[i][0] != '\\0')\n"
     "         return NULL;\n",
     "      else if (i == 0 && drivers[i][0] != '\\0' && strcmp(drivers[i], \"zink\") != 0)\n"
     "         return NULL;\n")
edit('src/gallium/auxiliary/target-helpers/sw_helper.h',
     '#include "util/u_debug.h"\n',
     '#include "util/u_debug.h"\n#include "util/log.h"\n')

# OSMesa's osmesa_target.c uses inline_sw_helper.h, which calls zink_create_screen without
# including zink_public.h (no upstream target links Zink there). Same log + softpipe fallback.
edit('src/gallium/auxiliary/target-helpers/inline_sw_helper.h',
     '#ifdef GALLIUM_D3D12\n#include "d3d12/d3d12_public.h"\n#endif\n',
     '#ifdef GALLIUM_D3D12\n#include "d3d12/d3d12_public.h"\n#endif\n\n'
     '#ifdef GALLIUM_ZINK\n#include "zink/zink_public.h"\n#include "util/log.h"\n#endif\n')
edit('src/gallium/auxiliary/target-helpers/inline_sw_helper.h',
     "   if (screen == NULL && strcmp(driver, \"zink\") == 0)\n"
     "      screen = zink_create_screen(winsys, NULL);\n",
     "   if (screen == NULL && strcmp(driver, \"zink\") == 0) {\n"
     "      screen = zink_create_screen(winsys, NULL);\n"
     "      mesa_loge(\"A01: zink %s\", screen ? \"ativo (GPU)\" : \"falhou ao abrir a GPU\");\n"
     "   }\n")
edit('src/gallium/auxiliary/target-helpers/inline_sw_helper.h',
     "      else if (i == 0 && drivers[i][0] != '\\0')\n"
     "         return NULL;\n",
     "      else if (i == 0 && drivers[i][0] != '\\0' && strcmp(drivers[i], \"zink\") != 0)\n"
     "         return NULL;\n")
