# Galaxy A01 Core: fatos de hardware para o port

Fonte principal: o dump público do firmware **M013FDDU4AUG1** (SM-A013F, Android 10), em
[Android-FW-Dumps/samsung_a01core_dump](https://github.com/Android-FW-Dumps/samsung_a01core_dump).
Os arquivos usados foram `boot.img`, `bootdts/01_dtbdump_mt6739.dts`, `dtbodts/*.dts`,
`bootRE/ikconfig` e `boot/ramdisk/fstab.mt6739`. Outros modelos (A013G/A013M) e outras versões
de firmware podem ter diferenças. **Nada disto foi medido no aparelho ainda.**

Os valores que o LK escolhe na hora do boot **não estão** no DTB estático. São eles:

- a RAM real (o DTB estático diz 512 MiB);
- as áreas reservadas que o próprio LK cria;
- o endereço do framebuffer.

O shim em modo sonda (`shim/a01core`) mostra esses valores na tela.

## SoC e boot

| Item | Valor | Fonte |
| --- | --- | --- |
| SoC | MediaTek MT6739, 4× Cortex-A53 (ARMv8.0, **sem** granule de 16 KiB, sem LSE, sem PAN) | DTB `cpus`, `compatible = "arm,cortex-a53"` |
| CPU | MPIDR Aff0 = 0..3, um cluster, `enable-method = "psci"` | DTB `cpu@0..3` |
| PSCI | 0.2 via `smc` | DTB `psci` |
| Kernel original | **32 bits** (`CONFIG_ARM=y`), zImage em `0x40008000` | `ikconfig`, cabeçalho do `boot.img` |
| bootopt original | `bootopt=64S3,32S1,32S1` | cmdline do `boot.img` |
| bootopt do port | `bootopt=64S3,32N2,64N2` (pede ao LK um kernel de 64 bits) | `tools/a01core-pack-boot.py` |
| boot.img | Android header v2, página 2048, seção DTB = tabela DT do Android (magic `0xd7b7ab1e`, 1 entrada), partição de 32 MiB, termina em `SEANDROIDENFORCE` | `boot.img` |
| Bootloader | Samsung/MediaTek LK. Não existe `fastboot boot`: o loader vai gravado na partição `boot` pelo **Odin** | — |

## Memória

| Item | Valor |
| --- | --- |
| DRAM | começa em `0x40000000`; 2 GiB no modelo de 2 GB → até `0xc0000000` (o LK corrige o nó `memory`) |
| Reservas estáticas | `0x48400000+0x12c000` (ccci md ee dump), `0x4b000000+2M` (sec-log), `0x4b200000+2M` (sec-lastklog), `0x4b400000+4M` (sec-logger) |
| Janela padrão do XNU | `0x60000000` + 1 GiB (`mkadt_a01core.py`). O shim recusa a janela se ela bater em qualquer reserva do FDT real |
| Superfície da tela escalada | `0xa0000000` + 16 MiB (`A01CORE_SCALED_SURFACE_PA`) |
| Página de log do shim | `0x4b100000` (dentro do sec-log da Samsung). Marcador do XNU em `+0x100`, texto ASCII a partir de `+0x200` |

## Interrupções e timer

| Item | Valor |
| --- | --- |
| GIC | GIC-500 (**GICv3**): GICD `0x0c000000` (256K), GICR `0x0c080000` (4×128K). Também há o MTK INTPOL `0x10200620` para a polaridade das SPIs |
| Timer | `arm,armv8-timer`, **13 MHz**; PPIs 13/14/11/10 → timer virtual = **INTID 27** |
| Watchdog | TOPRGU `0x10007000` (`WDT_MODE` chave `0x22000000`, bit 0 EN). O shim desliga |

## Armazenamento

| Item | Valor |
| --- | --- |
| eMMC | MSDC0 `0x11230000` (top `0x11cd0000`), 8 bits, HS200/HS400, IRQ SPI 79 |
| Partições | GPT com nomes em minúsculas: `boot`, `recovery`, `vbmeta`, `userdata` (f2fs no Android), `cache`, `super` (system/vendor/product/odm são dinâmicas), `efs`, `nvdata`, `nvram`, `protect1/2`, `persistent`, `lk`, `lk2`, `tee1`, ... |
| Raiz do iOS | `userdata` (`rd=emmcroot0 emmcroot=userdata emmcwrite=1`) |
| Log persistente | primeiros 4 MiB + 512 bytes de `cache` (`a5log=1`) |

## Tela

| Item | Valor |
| --- | --- |
| Painel | 720×1520, **modo vídeo** (vdo). Há duas variantes: TD4150 (Synaptics TDDI) ou NT36525B (Novatek TDDI) |
| Caminho | DISP_OVL0 `0x1400a000` → RDMA0 `0x1400b000` → DSI0 `0x14012000`; o LK deixa a tela mostrando o buffer dele |
| Framebuffer | `/chosen atag,videolfb-fb_base_h/l`, `atag,videolfb-vramSize` (dtbo: `0x17bb000`). Pitch esperado: 736×4 = 2944 bytes. **Confirmar com a sonda** (ela lê `OVL_Ln_ADDR`/`PITCH`/formato) |
| Canvas do iOS | iPhone XR 828×1792 @2x, escalado por CPU para 720×1520 (proporção 2,5 % diferente) |

## Entrada

| Item | Valor |
| --- | --- |
| Toque | SPI0 `0x1100a000` (MT6739: `enhance_timing`, `must_tx`, FIFO de 32 bytes, clock `INFRA_CG1` bit 1, conferido em `clk-mt6739.c`); pinos GPIO31 CS, GPIO32 CLK, GPIO33 MISO, GPIO34 MOSI (função 1); interrupção GPIO0 (ativa em nível baixo). TD4150 = `synaptics,tcm-spi` no CS0; NT36525B = `novatek,NVT-ts-spi` no CS1. Os dois são "zero flash": o firmware do toque precisa ser enviado pelo host a cada boot (`tsp_synaptics/td4150_a01core.img`) |
| Volume + | keypad MTK `0x10010000`, `KP_MEM1` bit 1 (`kpd-hw-init-map[1] = 0x73`), 0 = pressionado |
| Power / Volume − | PMIC MT6357 PWRKEY / HOMEKEY (`kpd-sw-pwrkey`, `kpd-sw-rstkey`), `TOPSTATUS 0x24` bits 1 e 3 (conferido em `mt6357/registers.h`), pelo pwrap `0x1000d000` (WACS2 `0xc20`, conferido em `pwrap_hal_v1.c`) |

## O que não tem driver (e por quê)

| Bloco | Situação |
| --- | --- |
| GPU PowerVR GE8100 (`mfg_auckland@13000000`) | Não existe driver aberto (Mesa) para essa GPU, e o Metal do iOS precisaria de um driver completo. O iOS desenha tudo na CPU |
| Wi-Fi / Bluetooth / FM / GPS (MediaTek CONNSYS `0x18070000`) | Exige firmware fechado da MediaTek e o protocolo WMT. Não portado |
| Modem 4G (CCCI) | Exige o firmware do modem e o protocolo CCCI. O iOS não tem como usar um modem MediaTek |
| Áudio, câmeras, sensores, NFC, carregamento real | Não portados |
| Face ID / Touch ID / SEP | Não existe hardware equivalente |
