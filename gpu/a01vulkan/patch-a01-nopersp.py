#!/usr/bin/env python3
"""Linear (non-perspective) varyings on the GE8100 (Galaxy A01 Core).

a01vktex on the phone: a varying that is the same at the three vertices arrives right, smooth or
flat (V4, V5), while one that differs between them arrives as 0 at every pixel (V3: uv from
(0,0)/(2,0)/(0,2) read back 0). Every texture lookup therefore read texel (0,0) or, with Zink's
coordinates, garbage addresses (the UI's TCU faults). Perspective-correct iteration divides by an
interpolated 1/w: if that term is wrong, a constant cancels out and anything else does not.

The iOS UI is 2D (w = 1), where linear and perspective-correct interpolation agree, so on Darwin
smooth varyings are iterated without perspective. A01_PVR_PERSP=1 restores perspective.

  patch-a01-nopersp.py MESA_DIR
"""
import pathlib
import sys

f = pathlib.Path(sys.argv[1]) / "src/imagination/pco/pco_nir.c"
t = f.read_text()
old = ("      } else if (in_var->data.interpolation == INTERP_MODE_NONE) {\n"
       "         in_var->data.interpolation = INTERP_MODE_SMOOTH;\n"
       "      }\n")
if t.count(old) != 1:
    raise SystemExit("pco_nir.c: pco_rev_link_nir interpolation site not found")
new = old + ("#if defined(__APPLE__)\n"
             "      /* A01: GE8100 perspective-correct iteration returns 0 for varying values */\n"
             "      if (in_var->data.interpolation == INTERP_MODE_SMOOTH) {\n"
             "         const char *a01_p = getenv(\"A01_PVR_PERSP\");\n"
             "         if (!(a01_p && a01_p[0] == '1'))\n"
             "            in_var->data.interpolation = INTERP_MODE_NOPERSPECTIVE;\n"
             "      }\n"
             "#endif\n")
t = t.replace(old, new, 1)
if "#include <stdlib.h>" not in t:
    t = "#include <stdlib.h>\n" + t
f.write_text(t, newline="\n")
print("pco_nir.c: smooth varyings iterated without perspective on Darwin")
