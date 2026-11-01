# Galaxy A01 Core: passo a passo do port (por marcos)

Cada marco tem um resultado que você vê no aparelho. Mude **uma coisa por vez**. Anote o que
mudou e o que apareceu (foto da tela). Quando algo falhar, o marco mostra o que provavelmente
está errado. Os valores de hardware estão em [A01CORE_HARDWARE.md](A01CORE_HARDWARE.md).

> **Riscos.** Tudo aqui apaga o Android, inclusive a partição `userdata`. O bootloader precisa
> ser desbloqueado (OEM unlock), o que também apaga tudo. Nunca grave nada nas partições `efs`,
> `nvdata`, `nvram`, `protect1/2`, `persistent`, `lk`, `lk2`, `tee1/2` ou `preloader`. Antes de
> começar, baixe o **firmware completo de fábrica do seu modelo exato** (SM-A013F, A013G ou
> A013M, da mesma região/CSC). É com ele que você volta para o Android pelo Odin.

## 0. Preparação

1. Confirme o modelo em Configurações → Sobre o telefone (SM-A013x, 2 GB de RAM).
2. Baixe o firmware de fábrica (Frija, Bifrost ou SamMobile) e o **Odin3** (3.14 ou mais novo)
   no Windows.
3. Desbloqueie o bootloader: Opções do desenvolvedor → **Desbloqueio OEM**. Desligue o
   aparelho. Segure **Volume + e Volume −** e conecte o cabo USB. Na tela azul, segure
   **Volume +** para desbloquear. **Isso apaga tudo.** Se a opção não aparecer, deixe o
   aparelho ligado à internet por alguns dias (trava KG/RMM) e tente de novo.
4. Do arquivo `AP_....tar.md5` do firmware, extraia `boot.img.lz4` e `vbmeta.img.lz4` e
   descompacte com `lz4 -d`. Guarde o **boot.img original**: ele é a base de todos os pacotes
   abaixo e também o caminho de volta.

## 1. Marco 1: o LK aceita um kernel de 64 bits? (sonda)

Esta é a maior incógnita do port. O kernel original do A01 Core é de **32 bits**. O LK
precisa iniciar a sonda em 64 bits por causa do `bootopt=64S3,32N2,64N2`.

1. No GitHub, rode o workflow **a01core-shim** no seu fork e baixe o artefato `a01core.Image`.
2. Monte a imagem de boot da sonda e o vbmeta desativado:

   ```
   python tools/a01core-pack-boot.py pack boot.img a01core.Image probe-boot.img
   python tools/a01core-odin-pack.py vbmeta vbmeta.img
   ```

3. Numa pasta separada, renomeie `probe-boot.img` para `boot.img` e gere o pacote do Odin:

   ```
   python tools/a01core-odin-pack.py tar AP_a01core_probe.tar.md5 boot.img vbmeta.img
   ```

4. Entre no modo download (Volume + e Volume − com o cabo). No Odin, coloque o pacote em
   **AP** e clique em Start.

**Resultado esperado:** depois do aviso de bootloader desbloqueado, a tela mostra
`A01CORE SHIM 1` e várias linhas de texto. **Tire uma foto nítida.** As linhas trazem:

| Linha | Para que serve |
| --- | --- |
| `EL 1` ou `EL 2` | o LK iniciou a sonda em 64 bits |
| `WDT 0x... -> 0x...` | o watchdog foi desligado (o bit 0 do segundo valor deve ser 0) |
| `MEM` / `RSV` | mapa real da RAM e das reservas: define `--ram-base` / `--ram-mb` |
| `FB FDT`, `OVL0 ...`, `L0..L3` | onde o LK desenha a tela |
| `USE FB 0x... STRIDE N BPP 32` | os valores para `a01core_fb_pa` e `a01core_fb_stride` |
| `XNU RAM ... OK` / `HITS ...` | se a janela padrão de 1 GiB em `0x60000000` está livre |
| `SURFACE ... OK` | se `0xa0000000` está livre para a tela escalada |

**Se não aparecer nada** (só o logo ou o aviso da Samsung, ou o aparelho reinicia), o LK
recusou a imagem ou não iniciou em 64 bits. Tente, uma de cada vez:

- `--raw` no `pack`, para não comprimir o kernel com gzip;
- `--kernel-addr 0x40008000`, o endereço original.

Se nada funcionar, o LK deste aparelho só inicia kernels de 32 bits. Nesse caso, o próximo
passo seria um estágio de 32 bits que peça ao ATF a troca para AArch64. Isso não está
implementado.

**Para voltar ao Android:** grave no Odin, em AP, um tar com o `boot.img` e o `vbmeta.img`
originais, ou o firmware completo. Para sair da sonda, segure **Power + Volume −** por uns
10 s.

## 2. Marco 2: compilar o kernel A01CORE

1. Rode o workflow **xnu** com `machine_config = A01CORE`. Em `a01core_fb_pa` e
   `a01core_fb_stride`, pode deixar vazio: o shim **move a imagem da tela** para o endereço
   que o kernel usa (padrão `0xbe840000`, stride 2944) e reprograma o `DISP_OVL0`. Só use
   os valores da foto se o shim mostrar `FB TARGET NOT USABLE`; nesse caso, passe os mesmos
   valores também no workflow **a01core-shim**.
2. Desde 01/11/2026 o kernel `A01CORE` compila sem erros no GitHub Actions (macos-14 e
   macos-15-intel), com os patches `0300`–`0304`. Se uma mudança sua quebrar o build, os
   erros aparecem como anotações do job.
3. Baixe o artefato `xnu-kernel-*` (`kernel.development.a01core`). O passo
   "Check Cortex-A53 compatibility" precisa passar sem instruções LSE.

## 3. Marco 3: o XNU inicia e acha o eMMC

```
python tools/mkadt_a01core.py a01core.adt --ram-base 0x60000000 --ram-mb 1024 --fb-pa 0x<USE FB> --fb-stride <STRIDE>
curl -L -o td4150_a01core.img https://raw.githubusercontent.com/almondnguyen/android_kernel_samsung_a01core/master/firmware/tsp_synaptics/td4150_a01core.img
python tools/mkpayload.py kernel.development.a01core a01core.adt payload.bin --blob TouchFirmware=td4150_a01core.img --cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=emmcroot0 emmcroot=userdata emmcprobe=1 wdt=-1 -wdt_no_pmu wdt_test=no_user_checkin"
python tools/a01core-pack-boot.py pack boot.img a01core.Image xnu-boot.img --append payload.bin
```

Empacote no Odin como no marco 1, com `xnu-boot.img` renomeado para `boot.img`.

**Resultado esperado**, nesta ordem na tela:

1. As linhas do shim, terminando em `JUMP TO XNU`.
2. `XNU ENTRY` e `XNU MMU ON` (texto do assembly do XNU).
3. O console do kernel, com:
   - `SWEET GIC: virtual timer INTID 27`;
   - as linhas `A01CORE MSDC: ... EXT_CSD ...`;
   - `A01CORE eMMC: GPT userdata first=... sectors=...`.

Ainda não há sistema iOS, então o boot para esperando o volume HFS. Anote o número de setores
de `userdata`: é o tamanho máximo da imagem do iOS.

| Sintoma | Causa provável |
| --- | --- |
| Para em `JUMP TO XNU` | `A01CORE_FB_PA`/stride do kernel diferentes da foto; ou falha cedo no MMU (fale com a comunidade do r/hackios) |
| Texto do XNU e depois para | timer (INTID 27) ou GIC (GICv3 em `0x0c000000`/`0x0c080000`) |
| `Undefined kernel instruction` | instrução ARMv8.1 que sobrou; o passo de checagem LSE do CI deveria pegar |
| `A01CORE MSDC: host not left running by LK` ou `CMD13 ... no response` | o LK desligou o MSDC; o driver precisa inicializar o eMMC do zero (não implementado) |

Para testar o kernel antes de gravar o `userdata`, use o mesmo caminho de ramdisk do port A5:
`mkpayload.py --ramdisk hfs-pequeno.img` e `rd=md0`, como descrito em
[a5xelte-bringup.md](a5xelte-bringup.md).

## 4. Marco 4: a imagem do iOS no `userdata`

1. Crie um repositório **privado** (os arquivos da Apple não podem ficar públicos). Envie esta
   branch para lá como `ios-root-build` e rode o workflow **ios-root** com `size_mb` **menor**
   que o `userdata` do marco 3 (`setores × 512 / 1048576`). Para um A01 Core de 32 GB, algo
   como `12288` deve caber.
2. Baixe as partes de `root.img.gz`, junte, descompacte e converta para sparse (Linux/WSL):
   `img2simg root.img userdata.img`.
3. Grave pelo Odin com `python tools/a01core-odin-pack.py tar AP_a01core_root.tar.md5 userdata.img`.
   O arquivo é grande. Se o Odin recusar, a alternativa é gravar a partir de um Linux iniciado
   pelo mesmo shim (não implementado).

## 5. Marco 5: logo da Apple, tela de bloqueio

Use a linha de comando completa:

```
debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=emmcroot0 emmcroot=userdata emmcwrite=1 rootrw=1 cs_enforcement_disable=1 unentitled_ios_sim_launch=1 ignition_level=1 launchd_unsecure_cache=1 wdt=-1 -wdt_no_pmu wdt_test=no_user_checkin a5fb_keep_on=1 a5fb_noconsole=1 a5log=1 a01keys_home=1
```

E gere o ADT com o `/product` real do iPhone X (`research/ipsw-x/d22ap.adt`, como no
[README do herolte](herolte-README.md)).

- `a5log=1` grava o log do kernel nos primeiros 4 MiB da partição `cache` (lê-se com `dd` a
  partir de qualquer Linux/recovery com root).
- `a01keys_home=1` faz o **Volume −** funcionar como botão Home, porque ainda não há toque.
- `cpus=4` liga os quatro núcleos (SMP via PSCI). Teste só depois que `cpus=1` estiver estável.

## 6. Marco 6: toque

O driver do toque (patch `0304`, `bsd/dev/a01core_touch.c`) já vem ligado. Ele precisa do
firmware do controlador, que vai dentro do payload (`--blob TouchFirmware=…`, marco 3). O
arquivo `td4150_a01core.img` é da Samsung e está no código-fonte GPL do SM-A013; ele **não**
fica neste repositório.

O que o driver faz, sem interrupção (só leitura do GPIO0 em loop):

1. pinos GPIO31–34 em função 1 (SPI0), clock do SPI0 ligado (`INFRA_CG1` bit 1);
2. lê o relatório de identificação; em modo ROM bootloader envia os 100 KB de firmware
   (`CMD_ROMBOOT_DOWNLOAD`) e manda o chip rodá-lo;
3. envia a configuração de toque e a de tela quando o chip pede (`CMD_DOWNLOAD_CONFIG`);
4. lê `max x/y`, define o formato dos relatórios e repassa os toques ao iOS em pixels do
   painel (720×1520), com até 10 dedos.

No log do kernel, o caminho bom é: `firmware: app 102400 ...` → `identify: ... mode 0x4` →
`host download done` → `config type 1` → `config type 2` → `application: ... max x ...` →
`ready`.

| Mensagem | O que fazer |
| --- | --- |
| `no touch firmware in the payload` | faltou `--blob TouchFirmware=td4150_a01core.img` |
| `no TouchComm device on SPI0 CS0` | o seu painel é a variante Novatek NT36525B (não suportada) ou o SPI não respondeu |
| `spi timeout` | clock do SPI desligado; mande o log |
| toque espelhado/girado | `a01touch_flipx=1`, `a01touch_flipy=1` ou `a01touch_swap=1` |

`a01touch=2` liga o log detalhado, `a01touch=0` desliga o driver, `a01touch_hz=` muda o
clock do SPI (padrão 5 MHz).

## Marcos que não estão no alcance deste port

GPU (PowerVR GE8100), Wi-Fi/Bluetooth/GPS (CONNSYS), modem, áudio, câmeras, sensores,
carregamento real: veja o fim de [A01CORE_HARDWARE.md](A01CORE_HARDWARE.md).
