#!/usr/bin/env python3
"""ALU interpolation by screen position on the GE8100 (Galaxy A01 Core).

With patch-a01-aluiter.py (C + A*x + B*y from the coefficient registers) the phone's V3 read
uv = 0.5/64 (0x02) at pixels (16,16) and (48,48), both at the corner of their 16x16 tile: A and B are
per pixel and right, but C is the value at the screen origin, so x/y must be the pixel's position on
the screen (X_P/Y_P, gl_FragCoord's registers, which the TQ copy already relies on), not in the tile
(TILE_X_P/TILE_Y_P). On Darwin load_tile_coord_pco reads the screen position. A01_PVR_TILE_ITER=1
restores the tile position.

  patch-a01-screeniter.py MESA_DIR
"""
import pathlib
import sys

f = pathlib.Path(sys.argv[1]) / "src/imagination/pco/pco_trans_nir.c"
t = f.read_text()
old = """      pco_ref xy[] = {
         pco_ref_hwreg(PCO_SR_TILE_X_P, PCO_REG_CLASS_SPEC),
         pco_ref_hwreg(PCO_SR_TILE_Y_P, PCO_REG_CLASS_SPEC),
      };
"""
if t.count(old) != 1:
    raise SystemExit("pco_trans_nir.c: load_tile_coord_pco registers not found")
new = """      pco_ref xy[] = {
         pco_ref_hwreg(PCO_SR_TILE_X_P, PCO_REG_CLASS_SPEC),
         pco_ref_hwreg(PCO_SR_TILE_Y_P, PCO_REG_CLASS_SPEC),
      };
#if defined(__APPLE__)
      /* A01: GE8100 coefficients' C is at the screen origin: iterate by screen position */
      {
         const char *a01_t = getenv("A01_PVR_TILE_ITER");
         if (!(a01_t && a01_t[0] == '1')) {
            xy[0] = pco_ref_hwreg(PCO_SR_X_P, PCO_REG_CLASS_SPEC);
            xy[1] = pco_ref_hwreg(PCO_SR_Y_P, PCO_REG_CLASS_SPEC);
         }
      }
#endif
"""
t = t.replace(old, new, 1)
if "#include <stdlib.h>" not in t:
    t = "#include <stdlib.h>\n" + t
f.write_text(t, newline="\n")
print("pco_trans_nir.c: tile coordinate = screen position on Darwin")
