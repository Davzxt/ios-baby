# Prompt de passagem para outro agente (Codex etc.) — Galaxy A01 Core, iOS 16 com GPU

> Cole tudo abaixo da linha no agente. Está em inglês de propósito (agentes de código rendem
> mais assim); a última seção diz para responder ao usuário em português do Brasil.

---

You are taking over a long-running bring-up project from another agent. Read this whole brief before
touching anything. The user is non-technical-ish, types slowly, often cannot photograph the phone, and
wants answers in **Brazilian Portuguese**. Be honest about what is verified versus guessed.

## 1. Goal

Run Apple's **iOS 16 userland on a Samsung Galaxy A01 Core (SM-A013M)** with a **GPU-accelerated UI**,
fluid, with touch. This is a hobby port: Apple's open-source **XNU** kernel (patched heavily) boots on the
phone; the iOS root filesystem lives on the phone's storage; graphics go through our own drivers.

Hardware: MediaTek **MT6739** (4x Cortex-A53), 1 GB RAM, eMMC, 720x1480 panel,
GPU **PowerVR GE8100**, BVNC **22.49.21.16**, Rogue XE, 1 cluster, 2 ISP IPP pipes, 8 KiB SLC,
kernel GPU driver = Imagination **DDK 1.11** (KM 1.11.5425693-style). Touch: **Novatek NT36525B** on SPI.

## 2. Repository and remotes

- Local checkout: `C:\Users\Admin\Desktop\ios_a03_v2` (Windows; tools: Git Bash, PowerShell, Python 3).
- Branch **`a01core`**, pushed to remote **`baby`** = GitHub **`Davzxt/ios-baby`**. Commit and push every
  finished step (`git push baby a01core`). End commit messages with a Co-Authored-By line for yourself.
- CI is GitHub Actions on that repo (`.github/workflows/`): `xnu.yml`, `a01vulkan.yml`, `a01gl.yml`,
  `a01metal.yml`, `a01core-shim.yml`. Builds run on macOS runners (Xcode, iPhoneOS SDK). A push that touches
  a workflow's paths starts it. Builds take 10-40 min. `gh` is NOT installed locally: use the REST API with
  the token from `git credential fill` (see `tools/a01core-pipeline/build_and_package.sh`).
- **Line endings:** files must be **LF**. Python's `write_text` on Windows writes CRLF; a CRLF bash script
  fails on the runner (`set: pipefail: invalid option`). Write with `path.write_bytes(text.encode())` or
  `write_text(..., newline="\n")`. Bash heredocs in this environment mangle backslashes (`\n`, `\0`):
  write Python helper scripts with a file-writing tool instead.

Key docs (read first): `A01CORE_PROGRESS.md` (evidence log, newest at the end), `docs/A01CORE_HARDWARE.md`,
`docs/A01CORE_PORTING.md`, `docs/a01core-gpu-stack-plan.md`, `docs/a01core-metal-research.md`,
`AGENTS.md` (rules). `NOTES.md` is history of a donor project (Xiaomi "sweet"), not this phone.

## 3. Hard safety rules (from AGENTS.md and the user)

- Only the **BOOT** image is flashed for trials (Odin `AP_*.tar.md5`). Never write EFS, RECOVERY,
  bootloader partitions; ask the user before any other partition write.
- Keep device dumps, private addresses, passwords and Apple binaries out of git.
- Do not copy code without a licence. `joranv1/ios-sailfish` has **no licence** (ideas only).
  `ry-diffusion/Chlorophyll` and `JimVulkan/img-pvr` are MIT. `OrchardLinux/mesa` has no licence.
- The user flashes packages themself with Odin. You produce `.tar.md5` files; you never flash.

## 4. How a build reaches the phone

1. Kernel: XNU source tree is a scratch git repo (on this PC:
   `C:/Users/Admin/AppData/Local/Temp/claude/C--Users-Admin-Desktop-ios-a03-v2/bf5e8092-86b8-476c-bc42-9b1fa226fbb8/scratchpad/build/xnu`).
   Changes are exported as numbered patches into `xnu/patches/NNNN-*.patch` (latest **0342**); `xnu.yml`
   applies them. If that scratch tree is gone, rebuild it by applying `xnu/patches` in order onto the
   XNU base the workflow uses, commit with `git -c user.name=a01core -c user.email=a01core@localhost`,
   and `git format-patch -1 --start-number N -o xnu/patches`.
2. GPU userland (CI artifacts):
   - `gpu/a01vulkan/` → `libvulkan_powervr.dylib` + `libdrm.2.dylib`. `build-pvr.sh` fetches
     **JimVulkan/img-pvr @ 9e1c0279** (Mesa 27-devel, PowerVR on DDK 1.11) and applies, in order:
     `../mesa/patch-mesa.py`, `patch-ge8100.py`, `patch-pvr-darwin.py`, `patch-a01-sync.py`,
     `patch-a01-opt.py`, `patch-a01-texdiag.py`, `patch-a01-nopersp.py`, `patch-a01-aluiter.py`,
     `patch-a01-screeniter.py` (see section 7). The pco_nir_opt cap, texture descriptor dump, linear varyings, ALU interpolation and screen position are all in these patches.
   - `gpu/a01gl/` → `libOSMesa.8.dylib` (Mesa **25.0.7** OSMesa with **Zink**), `libvulkan.1.dylib`
     (`a01vkloader.c`, a tiny loader exporting vkGetInstanceProcAddr/vkGetDeviceProcAddr),
     `libheroeagl.dylib` (EAGL shim injected into backboardd; source in `gpu/eagl`).
     Mesa 27 has no OSMesa, so a01gl stays on 25.0.7.
   - `gpu/a01metal/` → `libA01Metal.dylib`, `A01Metal.bundle`, and the test program `a01metal-test`
     (installed as `/private/var/herolte/autorun`, run at boot; prints `A01 >>>` lines on the console).
     Test sources in `gpu/a01metal/test/` (`a01metal-test.m`, `a01vktex.c`, GLSL shaders compiled with
     glslang on CI).
   - `gpu/ddk-1.11/` → the DDK 1.11 kernel GPU driver compiled into XNU as the `A01CoreGPU` IOKit
     driver (`env/xnu/pvr_xnu_entry.c`), with diagnostics in `rgxdebug.c`, `rgxfwutils.c`, etc.
3. Packaging: `tools/a01core-pipeline/build_and_package.sh` (copied from the agent's scratchpad; paths
   inside point at that scratchpad — adjust `S=`/`MB=`) waits for the CI runs by commit SHA, downloads
   artifacts, builds the drop with `tools/a01core-drop.py`, then calls
   `tools/a01core-pipeline/make_boot.sh XNU_RUN SHIM_RUN OUTDIR` which writes the Odin packages to
   `C:\A01CORE_RECOVERY\IOS_ROOT\AP_IOS16_BOOT_1GB_RAM_<VARIANT>.tar.md5`. Edit the `XNU= MT= VK= GL=`
   line to reuse previous run IDs and avoid slow rebuilds (the user asked for that). Shim run: 41338560241.
4. Variants (boot-args in `make_boot.sh`): `GPU_DIAG` (cpus=2, `a01gpu=2 herogl=1 a01gl=zink`, console on,
   the main test package), `GPU_DIAG_3CPU` (same, cpus=3; boots), `3CPU_SEM_GPU` (cpus=3, no GPU, console
   off: **stuck on the Apple logo**, untested further), `1GB_RAM` (cpus=1, CPU-drawn UI: works).
   `a01quiet=1` shows only `A01 >>>`/panic lines on screen.

## 5. Reading results from the phone

The user reads the screen. The kernel prints a status block every 30 s:
`A01 >>> GPU: <processes> TA<n> 3D<n> CDM<n>`, `A01 >>> CODIGO: abcd-r-...` (GPU letters + test result),
`A01 >>> FALHA1/FALHA2: DM<n> R|W <gpu addr> <requester>` (first/last GPU MMU fault),
`A01 >>> GL: <last backboardd Mesa log line>`, and
`A01 >>> TESTES: GL <marks> V3 <pix> <pix>` — marks are GL1..GL7 then V1..V3 (`+` ok, `-` wrong,
`?` running, `.` not run). Single-shot lines (V1..V6, VD1..VD4) scroll away fast; put anything you need
into that TESTES line (first line of `/private/var/herolte/autorun.out`, between quotes, read by
`bsd/dev/a01core_drop.c` in the kernel). Ask the user for short typed values.

## 6. What works (verified on the phone)

- XNU boots iOS 16 userland; 2 and 3 CPUs boot with the GPU stack (4 untested recently).
- GPU: firmware runs, render/transfer/compute kicks complete, sync-prim fences, freelist panic fixed.
- Metal-side tests 1-3 (memory copy, render-pass clear, shaded triangle) pass.
- Zink opens the GPU from backboardd ("zink Vulkan 1.3 PowerVR Rogue GE8100").
- GL1 (clears), GL2 (flat-colour quad), GL4 (720x1480 clear) correct.
- Shader compile hang fixed (pco NIR opt loop 1000 rounds x ~12 calls → capped at 16).

## 7. THE current blocker: varyings / textures (UI black or blue with noise)

Every textured draw failed (GL3, GL5-GL7, UI). Findings, in order:
1. Texture descriptor words (printed as VD lines) are **correct**: 2x2, RGBA8, right address, clamp.
2. Direct Vulkan test `a01vktex.c`: V1 (optimal + GPU copy) and V2 (linear CPU-written) read texel (0,0)
   at every pixel. V3 (uv as colour) = 0. **V4 constant smooth varying and V5 flat = correct (0x80,0x40).**
   ⇒ the hardware coefficient **iterators return only the constant term**; a varying that differs between
   vertices comes out as vertex 0's value.
3. Perspective off (`patch-a01-nopersp.py`) changed nothing.
4. `patch-a01-aluiter.py`: interpolate every input by ALU (`C + A*x + B*y` from the coefficient registers,
   pco's own interpolateAtOffset path, `alu_iter` in `pco_nir_pvfio.c`). UI went from blue+noise to
   **black**; V3 read **0x02 0x02** (= 0.5/64) at pixels (16,16) and (48,48), both tile corners ⇒ A and B
   are right per pixel, **C is at the screen origin**, but the code used the tile position.
5. `patch-a01-screeniter.py` (latest, commit c9f28de, **result not yet seen**): `load_tile_coord_pco` reads
   the screen position (`PCO_SR_X_P/Y_P`, gl_FragCoord's registers) instead of `TILE_X_P/Y_P`.
   Expected: V3 `424200ff c1c100ff`, V1/V2 the four colours, UI drawn correctly.
   Env knobs: `A01_PVR_HW_ITER=1`, `A01_PVR_TILE_ITER=1`, `A01_PVR_PERSP=1` restore upstream behaviour.

6. Step 5 result (V3 now halved in the shader, V6 = gl_FragCoord/128, LINEAR render target read
   directly by the CPU; the GPU copy back reported separately as `c`): `V3 4141 c0c0`, `c 0303` ⇒
   X_P/Y_P count **half pixels** (exactly 2x). V6 was 0 because the ALU path also iterated POS.xy.
7. `patch-a01-aluiter.py` now multiplies X_P/Y_P by 0.5 and returns them directly for gl_FragCoord.xy
   (commit after c9f28de, Vulkan run 41739185875). **Latest phone result:**
   `TESTES: GL ++-+-+-++-  V3 3030 9090  V6 2121 6161  c 3030`, and the **UI shows the gesture bar**
   (first real UI element drawn by the GPU). Reading: GL1 GL2 GL4 GL6 V1 V2 pass; GL3 GL5 GL7 V3 fail.
   **V6 is exactly right** (screen position fixed). V3 (uv*0.5, uv = vertex position 0..2 across the
   64x64 target) reads ~1.5x the expected 0x21/0x61 at pixels (16,16)/(48,48). The GPU copy (`c`) now
   matches V3's first pixel, so the TQ copy path is fixed. V1/V2 pass only because NEAREST on a 2x2
   texture tolerates the scale error.

### Next steps to get the WHOLE UI right (do these in order)
A. **Separate x from y.** All test pixels are on the diagonal, so `uv.x = A*x + B*y + C` cannot tell
   A from B. Add sample points off the diagonal, e.g. (16,48) and (48,16) (already read as px[1],
   px[2] in `a01vktex.c`), and put them in the TESTES line (it holds ~47 characters after "GL ").
   Also add a V7 with a varying that depends on x only (`uv = vec2(p.x, 0)`) and a V8 for y only.
   Then fit A, B, C per component. Likely causes of 1.5x: Y_P is not half pixels (only X_P is), or
   the coefficient set order is not (A, B, C) as `alu_iter` assumes (`coeffs` channel 0 * x, channel 1 * y,
   channel 2 constant), or the plane is relative to a different origin (pixel corner vs centre).
   Fix it in `patch-a01-aluiter.py`, rebuild only Vulkan (`a01vulkan.yml`), reuse the other run IDs.
B. **Perspective.** `patch-a01-nopersp.py` forces linear iteration; with ALU interpolation working,
   re-enable perspective (rhw = alu_iter of POS.w) and check it with a test that has w != 1, or keep
   linear if the UI never needs it (CoreAnimation 3D transforms do use perspective).
C. **Textures at real sizes.** GL5 (512x512 NEAREST) and GL7 (40x 256x256) must pass; GL6 (LINEAR +
   blend) already does. Then mipmaps, CLAMP vs REPEAT, BGRA formats (CoreAnimation uses BGRA8 and
   IOSurface-backed textures through the EAGL shim in `gpu/eagl/src/osm.c`).
D. **Remaining faults.** `FALHA DM3 R c0c0c0f140 TCU` and `DM2 R 65c0eaf000 VDM`: re-check after A;
   if they stay, log the faulting process/draw (kernel `a01pvr_gpu_fault`) and find which buffer or
   texture is unmapped (likely freed memory reused while the GPU still reads it, or a 16 KiB-page
   rounding issue in `pvr_srv_bo.c`).
E. **Full UI check.** Boot `GPU_DIAG_3CPU`, compare with the CPU-drawn UI (`1GB_RAM` package): lock
   screen wallpaper, clock, gesture bar, notifications, app icons after unlock. Ask the user what is
   missing or wrong; every remaining artefact is a separate GL feature (blend modes, scissor,
   stencil masks for rounded corners, YUV, gaussian blur shaders). Add a GLx test per feature.
F. **Speed.** Then profile: shader cache (`-Dshader-cache` off now), avoid per-frame shader compiles,
   zero-copy present, `cpus=3`/4.

If the coefficient approach keeps failing: (a) check whether C is per tile but offset by half a pixel
(try coords = screen position − 0.5); (b) the real root cause is probably a GE8100 difference in how the TSP/
iterators get per-tile coefficients — compare our device info (`patch-ge8100.py`, derived from GE8300;
USC/UVS values UNVERIFIED) and the 3D firmware command layout (GE8100 RGXFWIF_CMD3D is 336 bytes vs 328;
8 zero bytes are inserted before `flags`; TA 136 vs 128, pad after `partial_render_ta_3d_fence`). The
vendor userspace (`C:\A01CORE_RECOVERY\VENDOR_EXTRACT\vendor\lib\libsrv_um.so`, `libusc.so`,
`libIMGegl.so`, 32-bit, built only for 22.49.21.16) is a reference for reverse engineering (do not commit it).
Other open GPU symptoms: `FALHA DM2 R 65c0eaf000 VDM` (vertex fetch of an unmapped general-heap page),
`FINISHME tpu_border_colour_enhanced` (harmless, compressed formats only).
Already ruled out: texture upload path, descriptor contents, DOUTD cache mode, page-unit mapping,
Zink version (26.x PowerVR changes are minor), ISP tiles in flight (fixed to 2 anyway).

## 8. Other open work (after the UI renders)

- **Touch NT36525B**: every SPI read returns 0xFF (`TOQUE` lines). Suspects: pin input-enable/pull,
  touch block not powered/reset, SPI mode. Firmware blob path in `make_boot.sh`
  (`TouchFirmwareNVT=...nt36525_a01core_tp.bin`). The user believes touch once worked in an older
  GPU_DIAG build: check git history of the touch driver (xnu patches 0336, 0340) before rewriting.
- Performance: shader cache, zero-copy present (ideas from ios-sailfish, no copying), more CPUs.
- Metal UI: Chlorophyll (MIT) is Adreno/freedreno-specific (IOSurface import through the Adreno
  kernel); porting it onto Zink only makes sense once Zink textures work.
- Wi-Fi: no driver at all (MediaTek CONNSYS) — a large separate project.

## 9. Working style the user expects

- Reply in **Brazilian Portuguese**, short, outcome first, no jargon; the user types slowly.
- Reuse existing CI runs; rebuild only what changed. Record evidence in `A01CORE_PROGRESS.md`; commit.
- Each test package should answer one question with a value the user can read off the status line.
- Never claim it works until the phone shows it.
