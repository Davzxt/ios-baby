# A01CORE port progress

Galaxy A01 Core (SM-A013F/G/M, MediaTek MT6739, 2 GB). Base: `wardevsa/ios-a5xelte` branch
`herolte` at `3c67efc` (204 of its patches apply with `git apply`; `0031` and `0041` need the
staged HFS sources, as in CI). Keep observations from the phone, local builds and guesses apart.

## 2026-11-01: first port layer, nothing run on the phone yet

- **Hardware facts** from the public M013FDDU4AUG1 dump: boot DTB + dtbo, ikconfig, stock
  `boot.img` (header v2, 32-bit zImage at 0x40008000, `bootopt=64S3,32S1,32S1`, DT table with
  one FDT). Summary in `docs/A01CORE_HARDWARE.md`.
- **Kernel patches `0300`–`0303`** (written against the patched xnu-8796.141.3 tree; apply
  cleanly in order on top of the base; **not compiled**):
  - `0300` machine config `A01CORE` = A5XELTE + `ARM64_BOARD_CONFIG_A01CORE`: GICv3 (SWEET
    path) instead of the A5's GICv2, virtual timer INTID 27, MPIDR Aff0 topology up to 4 CPUs,
    GICv3 SGIs, `ICC_SRE_EL2` setup in `start.s`, 720×1520 framebuffer with
    `A01CORE_FB_PA`/`A01CORE_FB_STRIDE` from the build environment, scaled iPhone XR canvas,
    HID touch geometry, driver hook-up.
  - `0301` MSDC0 PIO back end (`bsd/dev/a01core_msdc.h`) under the shared `a5xelte_emmc.c`;
    lower-case GPT names, log in `cache`.
  - `0302` keys: keypad `KP_MEM1` bit 1 (Volume Up), MT6357 `TOPSTATUS` through pwrap WACS2
    (Power, Volume Down), self-disabling sanity checks.
  - `0303` touch: read-only probe and an opt-in SPI0 read, no protocol.
- **Loader** `shim/a01core`: EL2→EL1, TOPRGU watchdog off, FDT scan (memory, reserved-memory,
  memreserve, `atag,videolfb-*`), DISP_OVL0 layer readback, overlap checks, herolte payload
  format, boot_args.Video filled. Host-compiled: syntax clean with `-Wall -Wextra -Werror`.
  The FDT scanner was run on the stock A01 Core FDT and reproduced its memory and four
  reserved ranges. Not cross-compiled here (no aarch64 toolchain on this PC): CI does it.
- **Tools**: `mkadt_a01core.py` (generates a 6.8 KB ADT; dump checked), `a01core-pack-boot.py`
  (tested on the stock boot.img with a dummy Image: header v2 rebuilt, gzip kernel, bootopt
  rewritten, kernel_addr 0x40080000), `a01core-odin-pack.py` (vbmeta flags 3, Odin tar.md5).
- **Next on the phone (milestone 1):** flash the probe boot image with Odin and photograph
  the screen. Main unknown: whether this LK starts a 64-bit kernel.

## 2026-11-01 (tarde): kernel compila, driver de toque, tela fixa

- **CI (Davzxt/ios-baby, branch `a01core`):** o workflow `xnu` compilou
  `kernel.development.a01core` (17 MB) em macos-14 e macos-15-intel com `0300`–`0303`;
  0 instruções LSE no código. O shim falhava no assembler (`orr x1, x1, #0x9` não é
  imediato lógico): corrigido.
- **`0304` toque TD4150:** driver TCM completo por polling (SPI0 FIFO com pausa, host
  download ROMBOOT, `APP_CONFIG`/`DISPLAY` sob pedido do chip, formato de relatório fixo
  index/class/x/y, até 10 dedos, reinício automático se o chip resetar). Registradores
  conferidos no código GPL do SM-A013: clock do SPI0 é `INFRA_CG1` **bit 1** (o `0303`
  usava o bit 6 do MT6765). Firmware `td4150_a01core.img` (ROMBOOT_APP_CODE 100 KB,
  APP_CONFIG 4 KB, DISPLAY 8 KB, CRCs ok) entra pelo payload: `mkpayload.py --blob`.
  Compilação ainda a confirmar no CI; nada rodou no aparelho.
- **Shim:** se o LK desenhar fora de `A01CORE_FB_PA`/`A01CORE_FB_STRIDE`, o shim copia a
  imagem e reprograma `DISP_OVL0` (endereço e pitch da camada ativa), checando que o
  destino é DRAM livre ou a própria VRAM do LK. O kernel não precisa mais ser recompilado
  com os números da sonda.
- **Recuperação do aparelho do usuário (fora do git):** o brick vinha de um
  `userdata.img` do HakiOS gravado cru numa faixa errada do eMMC (~0x27EBC000–0x2AC30000):
  `tee1` inteiro e o início do `super` sobrescritos. Relatório em
  `C:\A01CORE_RECOVERY\CLAUDE_LOGS`.
- **Aparelho do usuario recuperado (01/11/2026, 11:28):** tee1 e super stock regravados e
  conferidos por leitura de volta; depois de tirar a bateria o aparelho saiu do BROM, o LK
  enumerou como Samsung 04E8:685D e o usuario confirmou que ligou.

## 2026-11-01 (noite): primeiro teste no aparelho

- Sondas de 64 bits (gzip @0x40080000, raw, @0x40008000): **nada na tela** (relato do usuario).
  O teste antigo do usuario que desenha e um zImage ARM32 com codigo anexado (bootopt 32S1).
- LK stock (A013MUBS3AWC1), desmontado: kernel de 64 bits so com endereco alinhado em 512 KiB
  e comprimido (descomprime ate 0x3200000 bytes), depois `lk_jump64(entrada, dtb, 0, 1)` ->
  SMC `0x82000115` (r1 entrada, r2 dtb, r3 0, r4 1). Kernels de 32 bits passam pela mesma SMC
  com r4 = 0. Logo, `--raw` e `--kernel-addr 0x40008000` nunca podiam funcionar.
- Shim: acha a tela so pelo DISP_OVL0 se o FDT falhar; sem tela, reinicia na hora (sinal).
- **Sonda V2 rodou no aparelho (foto do usuario):** EL2, FDT ok, DRAM 0x40000000+2 GiB,
  painel **720x1480**, LK desenha em **0x76740000** (L0, pitch 2944; L3 0x76b79000 pitch 2880),
  23 reservas. A janela antiga do XNU (0x60000000+1G) bate em 0x76000000: nova janela
  0x80000000+511 MiB. Patch `0306` e shim/ADT com os valores medidos.

## 2026-11-01 (noite): sistema iOS, drivers 0307-0308, auditoria

- Repositorio privado `Davzxt/ios-baby-root`: `ios-root` (macos-15-intel; macos-14 cancela na hora)
  montou o volume HFSX de 20480 MiB do iOS 16.7.16 (D22AP), release `ios-root-16.7.16-41324299453`.
  No PC: SHA256 ok, sparse 11,6 GB, LZ4 7,08 GB, `AP_IOS16_USERDATA.tar.md5` (fora do git).
- Boot do kernel A01CORE no aparelho (relato do usuario): drivers sobem, para em "mount root"
  (esperado: userdata ainda era Android).
- `0307`: bateria pela tensao do PMIC (AUXADC BATSNS), carregador (TOPSTATUS bit 2), vibracao
  (LDO VIBR), SweetBattery ligado no A01 Core, pwrap com trava compartilhada com os botoes.
- `0308`: mestre I2C do MT6739 (v1, FIFO) e barramento GPIO do acelerometro; fuel gauge S2MU005
  (i2c1 0x3b) alimenta o SweetBattery; identidades do AW8896 (i2c4 0x34) e LIS2DS (gpio 0x1d).
  CI: kernel 0300-0308 compilado (run 41328651620). Nao testado no aparelho.
- Auditoria `docs/A01CORE_DRIVER_AUDIT.md`: evidencias da `vendor` stock e do REA.

## 2026-11-01 (noite): **o iOS 16 bootou no SM-A013M**

- Odin: `AP_IOS16_USERDATA.tar.md5` (LZ4 com o cabecalho Samsung: FLG 0x6c, BD 0x60, content size;
  a versao com FLG 0x44/BD 0x70 deu "LZ4 is invalid") + boot 0300-0308. PASS em 8 min. Primeiro
  boot longo no logo da Apple; depois o usuario relatou: "O IOS BOOTOU".
- RAM: o LK reserva `reserve-memory-dram_r{0,1}_dummy_read` (leitura do DRAMC), firmware seguro,
  logs e modem. Experimento de 1 GiB: XNU em 0x80000000+1023 MiB atravessando o dummy-read do
  rank 1 (0x9fff0000+64K), superficie escalada em 0x78000000 (0309), shim mostra os nomes das
  reservas. Kernel/shim compilados (runs 41335809665/41335809692); nao testado.
- GPU: BVNC do GE8100 = **22.49.21.16** (`rgx_bvnc_table_km.h` do DDK 1.11 da Samsung; config
  22.V.21.16: 1 cluster, firmware MIPS). Mesa pvr nao tem esse BVNC; o fork JimVulkan/img-pvr roda
  o Vulkan aberto sobre o DDK 1.11 de kernel num GE8320 (22.87.104.18).
- **1 GiB, 2a tentativa:** a 1a parou em "RAM WINDOW NOT FREE" (reserva dentro da janela que nao e
  dummy-read). Agora o shim lista as reservas dentro da janela em /chosen a01core-ram-holes e o
  kernel (0310, 0312) nunca entrega essas paginas a VM. Compilado (run 41340185453), nao testado.
- **GPU passo 1 (0311):** liga MFG/MFG_CORE0 (sequencia do clk-mt6739-pg.c), libera a protecao de
  barramento e le RGX_CR_CORE_ID__PBVNC; espera 22.49.21.16. So com a01gpu=1. Nao testado.
- CI: ccache no workflow xnu (MakeInc.def CCACHE); 1o build com cache parcial: 14 min.

## 2026-11-01: 1 GiB RAM boots

- Patch 0313 (hole pages kept in vm_pages[], never freed) fixed the vm_resident.c:2627 panic. CI run 41342420423; packages AP_IOS16_BOOT_1GB_RAM*.tar.md5.
- User report: iOS 16 boots normally with 1023 MiB, feels faster. GPU BVNC line not yet read (scrolled too fast; next try: film the screen).
- GPU test (a01gpu=1) on the device: before status 0x3000434c, mfg_con 0x72, protect_sta 0xfe1f99b0; powered status 0xb000435c; core id 0x8470000, **BVNC 22.49.21.16 (GE8100) OK**. GE8100 powers on and answers under XNU.
- Same boot: S2MU005 fuel gauge 99.31%, AW8896 amp id 0x310 OK, LIS2DS accelerometer (bus 23 addr 0x1d reg 0xf) read id 0 UNEXPECTED.
- 0314+0315 on device: "GPU FW: loaded 122880 bytes at 0x834d2000; boot stage 0, mips exc 0x2 irq 0". EXCEPTION_STATUS 0x2 = SI_EXL: the MIPS left reset (ERL clear) and ran code, then took an exception before writing the boot stage. Next: NMI state dump (BOOT_DATA+0x100) to get EPC/cause.
- Metal research: docs/a01core-metal-research.md.
- 0316: NMI dump of the MIPS state after a failed boot (prints errEPC/cause/badvaddr, holds 15 s).
- gpu/a01metal: Metal layer on Vulkan (device, buffers, queue, command buffers, blit; pipelines pending metal2vulkan). Compiles for iOS in CI run 41350545878; not run on the phone (no Vulkan driver yet).
- 0316 NMI on device: cause 0x80000008 (TLBL, BD) bad/EPC 0xc001662c (microMIPS): bootloader ran and jumped into main code, first heap fetch missed. errEPC 0x9fc02241 (exception code page). PT was at PA 0x834fa000, not 32 KiB-aligned (DDK ui32BaseAlign 15). 0317 aligns it.
- 0317 on device: PT now 32 KiB-aligned (pt 0x83ed8000). Firmware gets further: TLBL at bad VA 0xc1ff0168, EPC 0xc0016632. 0xC1FF0000 = FW heap (32 MiB, RGX_FW_HEAP_SHIFT 25) minus RGX_FIRMWARE_CONFIG_HEAP_SIZE 64 KiB: the firmware main code runs and reads the host-built config heap (RGXFWIF OS/SYS init), which does not exist yet. Next: build the config heap structures (rgxfwutils.c RGXSetupFirmware).
- 0318: host firmware structures (RGXFWIF_INIT at FW 0xC1FF0000, KCCB 128x0x38, FWCCB 32x0x28, OS config, runtime cfg, trace/HWR/util buffers) with offsets compiled from the DDK rgx_fwif_km.h; polls bFirmwareStarted (+0x104) and sends one KCCB HEALTH_CHECK (0x2abc0073) with an MTS kick (0x10). Holds 15 s on success. Kernel CI 41353944545; not yet run on device.
- a01vulkan (Mesa 26.2.3 pvr, GE8100 entry): host mesa_clc stage works; iOS cross build down to Darwin-specific fixes.
- 2026-11-01 user report (no photo): 0318 held the screen 15 s with the success message: firmware started and the KCCB HEALTH_CHECK was answered. First command executed by the GE8100 firmware under XNU.
- DDK 1.11 port started: gpu/ddk-1.11 (Dual MIT/GPLv2 + MIT files only), env/xnu (config, sysinfo, type/lock/apphint branches, MediaTek stubs). tools/ddk-xnu-check.py compiles 92/92 core + rgx + bridge files for arm64 with clang; 217 symbols left for the XNU OS layer (108 OS*, 10 Sys*, PMR RAM backing, firmware load, handles, prints).
- img-pvr Vulkan iOS build: past mesa_clc host stage; fixing Vulkan headers.
- env/xnu OS layer written: osfunc_xnu.c (memory, locks, atomics, time, strings, events, threads, MISR, registers, cache, user copies), handle_xnu.c (handle table), physmem_xnu.c (PMRs on a01gpu_buf, contiguous pages, DMA-BUF unsupported), sysconfig_a01.c (UMA heaps, regs 0x13000000/64K, MFG power hook, polled LISR, rgx.fw from the payload, default init params). ddk-xnu-check: 96/96 compile; only XNU KPIs and 7 XNU-side helpers (a01gpu_buf_*, a01core_gpu_power_on, a01core_gpu_firmware) remain.
- a01vulkan CI run 41361291345: libvulkan_powervr.dylib (img-pvr, Mesa pvr on DDK 1.11, GE8100 entry) builds for iOS arm64, with the iOS libdrm stand-in (ENODEV until the A01CoreGPU bridge is wired in). Not run on the phone.
- Kernel: 0319 stages gpu/ddk-1.11 into bsd/a01_pvr, 0320 wires 97 DDK objects + A01CoreGPU IOKit user client (selector 0 bridge, 1 PMR map), boot-arg a01gpu=2. First CI build: only implicit libc declarations failed (fixed in config_kernel_a01core.h).
- Kernel with the full DDK 1.11 driver (0319/0320) builds and links: CI run 41363147912. Packages: AP_IOS16_BOOT_1GB_RAM_GPU_DDK.tar.md5 (a01gpu=2). 0321 adds a boot self-test (one DDK connection -> PVRSRVDeviceInitialise: firmware load/boot through the DDK). Not run on the device yet.
- 2026-11-02 panic on a01gpu=2: PVRSRVDriverDeInit+0x30 (far 0x5c) after PVRSRVDriverInit failed; cause: env/xnu OSMMapPMR was a NOT_SUPPORTED stub, so InfoPageCreate failed; DeInit then read the missing info page. Fixed (kernel-side PMR mapping as osmmap_stub.c, NULL-safe GetInfoPageDebugFlagsKM, file:line on PVR messages, 20 s hold on failure).
- 0322 boot-payload drop (A01Drop): kernel writes /private/var/a01/{lib/libvulkan_powervr,libdrm.2,libA01Metal}.dylib + a01metal-test and the com.a01core.autorun launchd job (output on the console). CI xnu 41406560843, vulkan 41406560913, metal 41406561087. AP_IOS16_BOOT_1GB_RAM_GPU_DDK.tar.md5 boot.img 9.5 MB. Not run yet.
- 2026-11-02 second a01gpu=2 run: panic in OSLockAcquire from PVRSRVStatsRegisterProcess (connection after PVRSRVDeviceInitialise returned OK): process stats were never initialised. a01pvr_driver_init now calls PVRSRVStatsInitialise first, as module_common.c does.
- 2026-11-02 third a01gpu=2 run: no panic. DDK booted the firmware (its MIPS TLB dump shows regs CF400000, PT CF000000, stack CF600000, code/data, config heap C1FF0000) but PVRSRVDeviceFinalise timed out setting power ON: the CPU read firmware-written memory through cached kernel mappings. 0323: a01gpu_buf_alloc takes the DDK CPU cache mode (uncached/WC kernel mappings).
- **2026-11-02 MILESTONE (photo): the full DDK 1.11 driver runs on the GE8100 under XNU.** "PVR: Read BVNC 22.49.21.16 from HW device registers", "RGX Device registered", "DDK 1.11 driver init: PVRSRV_OK", "A01CoreGPU registered", "RGX Firmware image rgx.fw.22.49.21.16 loaded", "device initialise (firmware boot): PVRSRV_OK", "self-test: open OK, GPU initialised by the DDK". iOS kept booting afterwards. Fixes that got here: OSMMapPMR (kernel PMR mapping), process stats init, uncached firmware-shared memory (0323).
- 2026-11-02 packages from CI xnu 41444249265 (0319-0325), a01vulkan 41444249019 (GE8100 loads without env), a01metal 41445988249 (A01MTLDevice runtime subclass of _MTLDevice, A01Metal.bundle): AP_IOS16_BOOT_1GB_RAM_GPU_DDK (a01gpu=2) and AP_IOS16_BOOT_1GB_RAM_GPU_METAL_UI (a01gpu=2 a01metal=1). Drop: 9 entries incl. /System/Library/Extensions/A01Metal.bundle. Not run yet.
- 2026-11-02 user: boot 2 showed drop.txt (written) + autorun.txt none yet; boot 3 had no result. iOS launchd reads jobs from /System/Library/xpc/launchd.plist, not the LaunchDaemons folder: the dropped plist was never loaded. The A01 root (herolte-tune-ios-root.sh) already registers com.herolte.autorun -> /private/var/herolte/autorun, output /private/var/herolte/autorun.out. 0326: the drop may write that path and the boot report prints autorun.out.

## 2026-11-02 — 0327 packages (3 GPU tests, faster boot)

- Build: xnu run 41449545122 success, a01metal run 41449545030 success, Vulkan 41444249019 (commit 976b887).
- Drop (9 entries): A01Metal.bundle, libvulkan_powervr, libdrm, libA01Metal, `/private/var/herolte/autorun` = a01metal-test (TESTE 1 copy, TESTE 2 texture+render pass, TESTE 3 SPIR-V triangle).
- Packages: GPU_DDK md5 1d8096efd1e27277e6ed2fb4a9f3ab51, GPU_METAL_UI md5 2837d08e8e4fb360ecfc2af8a984f9a6 (Odin trailer verified).
- Not yet run on device: no test result recorded yet.
- Device: with the 0327 GPU packages (no `serial=3`) the screen stayed on but black. On this port `serial=3` is what draws the text console on the framebuffer, so removing it hid all text; not a sign of a crash. Rebuilt with `serial=3` (still without `debug=0xc`): GPU_DDK md5 069e4a1c59e22793d826b45a142712e3, GPU_METAL_UI md5 463fc6d408f873f47c0ff88812896847.
- Device (photo, 2026-11-02): drop package installed (9 entries written, 0 failed); the autorun ran a01metal-test, which reported `ERRO: sem dispositivo Metal: no Vulkan library at /private/var/a01/lib/libvulkan_powervr.dylib` before TESTE 1. Cause found offline: the driver's only non-weak dynamically looked-up symbol, `vk_drm_syncobj_finish` (Linux-only vk_drm_syncobj.c), is undefined, so dyld refuses the dlopen. Fixed in aff50ce (Darwin definition, build check, dlerror in the message). Touch: TD4150 host download still fails (spi timeout) — separate issue.
- Packages for 65e8608 (Vulkan run 41459276710, Metal 41457673307, kernel 41449545122): drop id 0x4b4e61b8abbe62d3, no non-weak flat-namespace symbols left in libvulkan_powervr; GPU_DDK md5 4ffc75689e3c6900fc46ef455da74cc7, GPU_METAL_UI md5 dae3d75fc40558d4a77e2811d061f751 (with `serial=3`). Not yet run on device.
- Device (photo, 2026-11-02, first boot of the 65e8608 package): autorun.out still held two runs of the old test (message without dlerror), so the report came before the new drop was installed. The user saw no iOS UI: the GPU variants had dropped `a5fb_noconsole=1`, which is what mutes the text console once the UI presents its first frame, so the console kept drawing over the screen. Rebuilt with it (console visible until the first UI frame): GPU_DDK md5 f7b91bd0e22ae9ecbda2cd2b9e806d53, GPU_METAL_UI md5 b5f45fee166ea0c15d0700ac6fd5dee9. GPU_METAL_UI also publishes IOAcceleratorES, so iOS's own Metal clients may pick the incomplete A01Metal; GPU_DDK keeps the UI on the old path and still runs the tests (the test creates its device directly).
- Device (photo, 2026-11-02, GPU_DDK f7b91bd0): iOS UI started (user report). libvulkan_powervr now loads; a01metal-test fails at vkCreateInstance with `MESA: error: Build-id too short. It needs to be a SHA.` Mesa's Darwin build-id is the 16-byte LC_UUID, pvr_instance.c demanded 20. Patched to accept 16 on Darwin (zero-padded by copy_build_id_to_sha1).
- Packages for f5774b9 (Vulkan run 41463838395): drop id 0x46e5272ee6931fdf; GPU_DDK md5 01e0ff2d5b6bb92a04999d9397e35cb0, GPU_METAL_UI md5 fd6cb65ae578f73c5bc4f14b6abf7295. Not yet run on device.
- Device (photo, 2026-11-02, f5774b9 package installed, id 0x46e5272ee6931fdf): no more build-id error; the newest run printed only the test header, so a01metal-test died or hung inside device creation without output. Added crash/hang reporting (c12daff, 09faba0). Packages: Vulkan run 41467560432, Metal 41467116152, drop id 0xa085b98d30f7a7a7; GPU_DDK md5 fbaa0c3d68ea034d988b044d74b78537, GPU_METAL_UI md5 c2acfbcaf5dc3e53c64876e186bfbd79. Not yet run on device.
- Device (photo, 2026-11-02, package 0xa085b98d30f7a7a7): autorun.out held only the header and no crash/hang report, so the test was killed (SIGKILL/jetsam) or stuck in a kernel call where signals are not delivered. Live status writer added (0f3367a, edbf585): status first, rewritten every second. Packages: Vulkan 41472398598, Metal 41472616870, drop id 0xf3dc3cc6713c9f99; GPU_DDK md5 302495452c1d923f86b085afda2689ec. Not yet run on device.
