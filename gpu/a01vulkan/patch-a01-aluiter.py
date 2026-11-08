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
   bool a01_alu = false, a01_posxy = false;
#if defined(__APPLE__)
   /* A01: the hardware iterators are used again for ordinary varyings. The measurements that
    * suggested they were broken were read back through the TQ copy, which itself sampled at the
    * wrong position (X_P/Y_P count half pixels); the later "coordinates zero" result matched only
    * because every sample point sat on a 16x16 tile corner, and drew 16x16 blocks on the UI.
    * A01_PVR_ALU_ITER=1 keeps the ALU interpolation for experiments. gl_FragCoord.xy always comes
    * from X_P/Y_P x 0.5 below (that fixed the TQ copy and V6). */
   {
      bool a01_pix = bary->intrinsic == nir_intrinsic_load_barycentric_pixel ||
                     bary->intrinsic == nir_intrinsic_load_barycentric_centroid ||
                     bary->intrinsic == nir_intrinsic_load_barycentric_sample;
      const char *a01_a = getenv("A01_PVR_ALU_ITER");
      a01_alu = a01_pix && a01_a && a01_a[0] == '1';
      a01_posxy = a01_pix && nir_intrinsic_io_semantics(intr).location == VARYING_SLOT_POS &&
                  nir_intrinsic_component(intr) + intr->def.num_components <= 2;
   }
#endif
   if (bary->intrinsic != nir_intrinsic_load_barycentric_at_offset && !a01_alu && !a01_posxy)
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
   if (!a01_alu && !a01_posxy)
      coords = nir_fadd(b, coords, bary->src[0].ssa);

#if defined(__APPLE__)
   /* A01: gl_FragCoord.xy has no coefficients (pos.x/y are not iterated): it is the position itself */
   if ((a01_alu || a01_posxy) && nir_intrinsic_io_semantics(intr).location == VARYING_SLOT_POS) {
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
   /* Phone V9, with coordinates zeroed: 2020 at (16,16), 6020 at
    * (48,16), close to the expected 2121 and 6121. The coefficient term
    * appears already interpolated for this draw. Do not add the gradients a
    * second time. This is a device-specific trial; other draws remain untested. */
   if (a01_alu) {
      const char *a01_s = getenv("A01_PVR_UNSCALED_ITER");
      const char *a01_z = getenv("A01_PVR_ITER_ZERO");
      const char *a01_old = getenv("A01_PVR_ITER_TWO_THIRDS");
      if (a01_z && a01_z[0] == '1')
         coords = nir_fmul_imm(b, coords, 0.0f);
      else if (a01_old && a01_old[0] == '1')
         coords = nir_fmul_imm(b, coords, 2.0f / 3.0f);
      else if (!(a01_s && a01_s[0] == '1'))
         coords = nir_fmul_imm(b, coords, 0.0f);
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
rep("""      comps[u] = alu_iter(b, coords, u, nir_intrinsic_io_semantics(intr));
""", """      unsigned a01_component = u;
#if defined(__APPLE__)
      /* The input may start at a nonzero component. Our A01 path lowers
       * ordinary interpolated inputs too; unlike the original hardware path,
       * using u alone loses their component offset and reads another lane. */
      if (a01_alu)
         a01_component += nir_intrinsic_component(intr);
#endif
      comps[u] = alu_iter(b, coords, a01_component, nir_intrinsic_io_semantics(intr));
""")
f.write_text(t, newline="\n")
print("pco_nir_pvfio.c: interpolated inputs by ALU on Darwin")
