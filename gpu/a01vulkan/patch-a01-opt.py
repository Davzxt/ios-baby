#!/usr/bin/env python3
"""Bounded NIR optimisation loop in the PowerVR compiler (Galaxy A01 Core).

pco_nir_opt() repeats ~30 NIR passes while any of them reports progress, capped at 1000 rounds,
and runs about a dozen times per shader. When two passes keep undoing each other (the phone's
hang was in nir_opt_constant_folding / nir_shader_lower_instructions), each call spins the full
1000 rounds: minutes per shader on the MT6739's Cortex-A53 cores. That stalled A01Metal's TESTE 3,
Zink's first shader draw (GL2) and backboardd's UI shaders.

Every pass is correctness-preserving, so stopping early only leaves the shader less optimised.
Cap the loop at 16 rounds (well-behaved shaders converge in a few) and say so once in the log.

  patch-a01-opt.py MESA_DIR
"""
import pathlib
import sys

f = pathlib.Path(sys.argv[1]) / "src/imagination/pco/pco_nir.c"
t = f.read_text()
old = ('      if (count++ > 1000) {\n'
       '         printf("WARNING! Infinite opt loop!\\n");\n'
       '         break;\n'
       '      }\n')
new = ('      if (count++ > 16) {\n'
       '         static bool a01_warned;\n'
       '         if (!a01_warned) {\n'
       '            a01_warned = true;\n'
       '            mesa_logw("A01: pco opt loop capped at 16 rounds (%s shader)",\n'
       '                      _mesa_shader_stage_to_string(nir->info.stage));\n'
       '         }\n'
       '         break;\n'
       '      }\n')
if t.count(old) != 1:
    raise SystemExit(f"pco_nir.c: expected 1 match, found {t.count(old)}")
t = t.replace(old, new)
if '#include "util/log.h"' not in t:
    t = t.replace('#include "pco_internal.h"\n', '#include "pco_internal.h"\n#include "util/log.h"\n', 1)
f.write_text(t)
print("patch-a01-opt: pco_nir_opt capped at 16 rounds")
