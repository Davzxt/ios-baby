#!/usr/bin/env python3
"""Varyings interpolated by shader arithmetic on the GE8100 (Galaxy A01 Core).

a01vktex on the phone: a varying equal at the three vertices arrives right (V4 smooth, V5 flat), one
that differs arrives as its first vertex's value at every pixel (V3), with perspective and without
it (patch-a01-nopersp.py changed nothing). The coefficient iterators give only the constant term.
The pixel position in the tile works (the TQ copy samples by it), and pco already interpolates by
ALU for interpolateAtOffset: C + A*x + B*y from the coefficient registers (alu_iter). On Darwin every
interpolated input takes that path (offset 0). A01_PVR_HW_ITER=1 restores the iterators.

  patch-a01-aluiter.py MESA_DIR
"""
import pathlib
import sys

f = pathlib.Path(sys.argv[1]) / "src/imagination/pco/pco_nir_pvfio.c"
t = f.read_text()


def rep(old, new):
    global t
    if t.count(old) != 1:
        raise SystemExit("pco_nir_pvfio.c: not found:\n" + old)
    t = t.replace(old, new, 1)


rep("""   /* Skip cases that don't need handling. */
   if (bary->intrinsic != nir_intrinsic_load_barycentric_at_offset)
      return false;

   assert(nir_src_as_uint(intr->src[1]) == 0);

   nir_def *coords = nir_load_tile_coord_pco(b, 2);
   coords = nir_fadd(b, coords, bary->src[0].ssa);

   enum glsl_interp_mode interp_mode = nir_intrinsic_interp_mode(bary);
   nir_def *rhw = alu_iter(b,
                           coords,
                           3,
                           (struct nir_io_semantics){
                              .location = VARYING_SLOT_POS,
                              .num_slots = 1,
                           });
""", """   /* Skip cases that don't need handling. */
   bool a01_alu = false;
#if defined(__APPLE__)
   /* A01: GE8100 iterators return only the constant term; interpolate by ALU */
   {
      const char *a01_h = getenv("A01_PVR_HW_ITER");
      a01_alu = !(a01_h && a01_h[0] == '1') &&
                (bary->intrinsic == nir_intrinsic_load_barycentric_pixel ||
                 bary->intrinsic == nir_intrinsic_load_barycentric_centroid ||
                 bary->intrinsic == nir_intrinsic_load_barycentric_sample);
   }
#endif
   if (bary->intrinsic != nir_intrinsic_load_barycentric_at_offset && !a01_alu)
      return false;

   assert(nir_src_as_uint(intr->src[1]) == 0);

   nir_def *coords = nir_load_tile_coord_pco(b, 2);
#if defined(__APPLE__)
   /* A01: with patch-a01-screeniter.py this is X_P/Y_P, which count half pixels on the GE8100
    * (phone: uv read back exactly 2x at (16,16) and (48,48)) */
   {
      const char *a01_t = getenv("A01_PVR_TILE_ITER");
      if (!(a01_t && a01_t[0] == '1'))
         coords = nir_fmul_imm(b, coords, 0.5f);
   }
#endif
   if (!a01_alu)
      coords = nir_fadd(b, coords, bary->src[0].ssa);

#if defined(__APPLE__)
   /* A01: gl_FragCoord.xy has no coefficients (pos.x/y are not iterated): it is the position itself */
   if (a01_alu && nir_intrinsic_io_semantics(intr).location == VARYING_SLOT_POS) {
      unsigned a01_c = nir_intrinsic_component(intr);
      if (a01_c + intr->def.num_components <= 2) {
         nir_def *a01_xy = nir_channels(b, coords, BITFIELD_RANGE(a01_c, intr->def.num_components));
         nir_def_replace(&intr->def, a01_xy);
         nir_instr_free(&intr->instr);
         return true;
      }
      /* z/w: leave them to the hardware path */
      return false;
   }
#endif

 #if defined(__APPLE__)
   /* Phone V3: (16,16), (48,16), (16,48) -> 3030, 9030, 3090;
    * expected 2121, 6121, 2161. V6 confirms coords themselves are correct.
    * Compensate the measured varying gradients only; do not alter FragCoord.
    * The cause and validity for other primitives remain to be tested. */
   if (a01_alu) {
      const char *a01_s = getenv("A01_PVR_UNSCALED_ITER");
      if (!(a01_s && a01_s[0] == '1'))
         coords = nir_fmul_imm(b, coords, 2.0f / 3.0f);
   }
 #endif

   enum glsl_interp_mode interp_mode = nir_intrinsic_interp_mode(bary);
   nir_def *rhw = NULL;
   if (interp_mode != INTERP_MODE_NOPERSPECTIVE)
      rhw = alu_iter(b,
                     coords,
                     3,
                     (struct nir_io_semantics){
                        .location = VARYING_SLOT_POS,
                        .num_slots = 1,
                     });
""")
if "#include <stdlib.h>" not in t:
    t = "#include <stdlib.h>\n" + t
f.write_text(t, newline="\n")
print("pco_nir_pvfio.c: interpolated inputs by ALU on Darwin")
