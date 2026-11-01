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
