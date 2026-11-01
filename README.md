# iOS 16 no Galaxy A01 Core (SM-A013, MediaTek MT6739): branch `a01core`

Este é um port **experimental e ainda não testado no aparelho**. Ele leva o kernel XNU da Apple
e o sistema do iPhone X (iOS 16.7.16) para o Samsung Galaxy A01 Core. Ele é construído sobre os
projetos da comunidade [hackiosx](https://github.com/dipa-studio/ios-sweet):

- **[ios-sweet](https://github.com/dipa-studio/ios-sweet)** (Redmi Note 10 Pro): o XNU portado,
  o shim de boot e o caminho GICv3;
- **[ios-a5xelte, branch herolte](https://github.com/wardevsa/ios-a5xelte/tree/herolte)**
  (Galaxy A5 2016 e Galaxy S7): o kernel de páginas de 4 KB para Cortex-A53 sem instruções
  ARMv8.1, o boot pela partição BOOT da Samsung, o eMMC e a tela escalada.

O que este branch acrescenta é a camada MediaTek/A01 Core: shim, device tree, eMMC, botões,
tela, sonda do toque e ferramentas de Odin.

> **Leia antes.** Nada aqui foi executado no telefone ainda. O código foi escrito a partir do
> device tree, da configuração do kernel e do código-fonte GPL oficiais do A01 Core, e do
> código dos ports que já funcionam. O kernel compila no GitHub Actions (macOS). O
> caminho até a tela inicial do iOS é uma sequência de marcos, cada um com algo para verificar
> na tela: veja **[docs/A01CORE_PORTING.md](docs/A01CORE_PORTING.md)**.
> Instalar apaga o Android e exige o bootloader desbloqueado.

## Situação

| Parte | Estado |
| --- | --- |
| Boot pelo LK da Samsung/MediaTek em 64 bits | Escrito (`shim/a01core`, `tools/a01core-pack-boot.py`). **Maior incógnita:** o kernel original é de 32 bits |
| Sonda de hardware (tela, RAM, reservas, watchdog) | Escrita. É o marco 1 |
| XNU para MT6739 (máquina `A01CORE`) | Patch `0300`: GICv3, timer de 13 MHz/INTID 27, 4 núcleos via PSCI, páginas de 4 KB, Cortex-A53. **Compila no GitHub Actions** (01/11/2026), 0 instruções LSE |
| eMMC (MSDC0) leitura/escrita, raiz HFS+ no `userdata` | Patch `0301` (PIO, usa o estado em que o LK deixa o controlador) |
| Tela | Framebuffer do LK, canvas de iPhone XR escalado por CPU para 720×1520 (patch `0300`). O shim move a imagem para o endereço compilado no kernel, sem precisar recompilar |
| Botões Power, Volume +/− | Patch `0302` (keypad + PMIC MT6357; Volume − pode virar Home) |
| Toque TD4150 (Synaptics, SPI) | Driver completo (patch `0304`): envio do firmware "zero flash", configurações, até 10 dedos. Precisa do `td4150_a01core.img` no payload |
| Toque NT36525B (variante Novatek) | Não suportado |
| Bateria | Fixa em 100 % (herdado dos ports base) |
| GPU, Wi-Fi, Bluetooth, modem, áudio, câmera, sensores, GPS, NFC, Face ID | **Não existem** neste port. Veja o porquê em [docs/A01CORE_HARDWARE.md](docs/A01CORE_HARDWARE.md) |

## O que tem aqui

| Caminho | O que é |
| --- | --- |
| `shim/a01core/` | Loader que o LK inicia: desliga o watchdog, desce de EL2 para EL1, lê o FDT do LK, acha o framebuffer pelo DISP_OVL0, confere a RAM e inicia o XNU. Sem kernel anexado, funciona como sonda |
| `xnu/patches/0300-0304-*` | Patches do kernel para a máquina `A01CORE` (aplicados depois dos 204 da base) |
| `tools/mkadt_a01core.py` | Device tree da Apple (ADT) para o A01 Core |
| `tools/a01core-pack-boot.py` | Monta o `boot.img` a partir do **seu** `boot.img` original (header v2, gzip, `bootopt` de 64 bits) |
| `tools/a01core-odin-pack.py` | `vbmeta` com verificação desligada e pacotes `.tar.md5` para o Odin |
| `.github/workflows/a01core-shim.yml` | Compila o shim e testa o leitor de FDT |
| `.github/workflows/xnu.yml` | Compila o kernel (`machine_config = A01CORE`, com os valores medidos pela sonda) |
| `.github/workflows/ios-root.yml` | Monta a imagem do iOS a partir do IPSW da Apple (só em repositório **privado**) |
| `docs/A01CORE_HARDWARE.md` | Endereços e fatos do hardware, com as fontes |
| `docs/A01CORE_PORTING.md` | O passo a passo por marcos |
| `A01CORE_PROGRESS.md` | Diário do port |

Os documentos dos projetos base continuam aqui: `docs/herolte-README.md`, `HEROLTE_PROGRESS.md`,
`A5XELTE_PROGRESS.md` e `NOTES.md`.

## Créditos e licenças

O XNU, o IOHIDFamily, o libpthread e o HFS são código aberto da Apple (APSL). O BearSSL é do
seu autor. ios-sweet (MIT) e ios-a5xelte/herolte são dos seus autores. O código do shim é
GPL-2.0-only, como o shim do herolte. Os endereços do hardware vêm do dump público do
firmware M013FDDU4AUG1 ([samsung_a01core_dump](https://github.com/Android-FW-Dumps/samsung_a01core_dump)).
O iOS é da Apple e **não** é distribuído aqui: a imagem do sistema é montada por você, a partir
do IPSW oficial, num repositório privado.
