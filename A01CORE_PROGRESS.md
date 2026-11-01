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
