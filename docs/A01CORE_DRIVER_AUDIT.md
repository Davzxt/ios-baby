# Galaxy A01 Core: auditoria de drivers (01/11/2026)

## Fontes usadas em toda a auditoria

- **Kernel GPL da Samsung para o SM-A013:**
  - repositório `almondnguyen/android_kernel_samsung_a01core`, versão `A013GXXU4AVF4`;
  - cópia local em `C:\Users\Admin\Desktop\ios_a03_core\a01core-kernel`;
  - configuração `arch/arm/configs/a01core_defconfig`;
  - device trees em `arch/arm/boot/dts/samsung/*a01core*`.
- **Firmware oficial do aparelho:** SM-A013M `A013MUBS3AWC1`, em `C:\A01CORE_RECOVERY\FIRMWARE`.
- **Medições no aparelho:** foto da sonda V2 (RAM, telas e reservas) e o boot do kernel A01CORE
  relatado pelo usuário (drivers sobem e o boot para em "mount root").

## Como ler o estado

| Estado | Significado |
| --- | --- |
| implementado | o código existe no repositório |
| compilado | o build `xnu` do GitHub Actions passou |
| iniciou | apareceu no log do aparelho |
| funciona | a função foi conferida no aparelho |

Nada sobe de nível sem evidência.

## Arquitetura do port: o que limita as escolhas

- **Kernel:** é o XNU 8796 com patches. Driver do Linux **não carrega** nele. O que dá para
  aproveitar do Linux são os registradores, as sequências de inicialização, os protocolos e os
  formatos de firmware, reescritos em C dentro de `bsd/dev` ou como serviços IOKit em
  `iokit/Kernel/arm`.
- **Espaço do usuário:** são os binários originais do iOS 16.7.16 (iPhone X, D22AP).
  - Os daemons da Apple (`wifid`, `bluetoothd`, `CommCenter`, `mediaserverd`, câmera) são
    fechados e conversam com drivers e firmwares da Apple por protocolos privados.
  - Substituir o driver do lado do iOS significa **substituir ou contornar o daemon**, não
    recompilá-lo.
  - O port já roda binários próprios sem assinatura da Apple (`cs_enforcement_disable=1`).
    Então dá para **escrever daemons substitutos**, e é o caminho das frentes difíceis abaixo.
- **Fronteiras já prontas no port:**
  - HID (`SweetHID`): toque e botões;
  - `IOPMPowerSource` (`SweetBattery`): bateria;
  - framebuffer (`SweetFramebuffer`): tela;
  - eMMC como disco BSD.
- **Base para a GPU:** a base herolte prova o caminho "driver de GPU no kernel + Mesa no
  usuário + EAGL" (`gpu/`, patches 0231–0267), com a Mali do Exynos.

## Bloqueio transversal: barramento I2C

O carregador e medidor de bateria (S2MU005), o acelerômetro (LIS2DS), o sensor de proximidade e
luz (STK3013) e o amplificador do alto-falante (AW8896) estão todos em I2C. O port **ainda não
tem driver do controlador I2C do MT6739**.

- Fonte: `drivers/i2c/busses/i2c-mtk.c`, com ~2.000 linhas.
- **É o próximo driver a escrever.** Ele destrava quatro componentes de uma vez.

## Evidência do firmware: partição `vendor` stock (A013MUBS3AWC1)

A partição foi extraída deste PC com um leitor próprio de metadados LP e ext4. As partições
dinâmicas do `super` são `system`, `vendor`, `product` e `odm`. A `vendor` é só de 32 bits (não
tem `lib64`). Foram 374 arquivos relevantes, em `C:\A01CORE_RECOVERY\VENDOR_EXTRACT` (fora do
git).

| Arquivo | O que é / o que prova |
| --- | --- |
| `firmware/WIFI_RAM_CODE_6755` (447.904 B, cabeçalho `MTKW`) | firmware de RAM do Wi-Fi, a família de chip que o `wlan_drv_gen2` usa no MT6739 |
| `firmware/ROMv2_lm_patch_1_0_hdr.bin` e `_1_1_hdr.bin` | patches de ROM do processador do CONNSYS, versão 2021-03-08 |
| `firmware/WMT_SOC.cfg`, `BT_FW.cfg`, `WIFI` (NVRAM padrão) | configuração do WMT, do BT e de calibração do Wi-Fi |
| `bin/wmt_loader`, `bin/wmt_launcher` | sequência de boot do CONNSYS: `/dev/wmtdetect` (detecção do chip), `/dev/stpwmt` e `ioctl WMT_IOCTL_SET_ROM_PATCH_INFO` (o userland só escolhe o patch, e o kernel `wmt_drv` envia) |
| `lib/libbluetooth_mtk.so` | o Bluetooth fala **pacotes HCI por `/dev/stpbt`**, ou seja, HCI padrão em cima do STP |
| `firmware/rgx.fw` (122.880 B) | firmware da GPU: **ELF MIPS32** com entrada `0xbfc00001` (reset MIPS, microMIPS), visto pelo REA |
| `lib/egl/libGLESv2_mtk.so` | "PowerVR Rogue GE8100", "OpenGL ES 3.2 build **1.11@5425693**" |
| `lib/libIMGegl.so` | EGL 1.4, mesmo build 1.11@5425693 |
| `firmware/aw8896_*.bin` | configuração e firmware do amplificador AW8896 |
| `lib/hw/audio.primary.mt6739.so` (2 MB) | HAL de áudio da MediaTek: rotas e parâmetros do codec |

**O DDK de kernel da GPU que acompanha esse userland está no kernel GPL**:
`drivers/misc/mediatek/gpu/gpu_rgx/m1.11ED5425693`, a mesma versão 1.11@5425693.

## Uso do REA nesta máquina (Windows)

- Chamadas feitas: `open_binary` em `rgx.fw` (reconheceu ELF MIPS executável) e
  `inspect_with_objdump` em `file_headers` (entrada `0xbfc00001`).
- **Provedores de análise profunda:**
  - **Ghidra 12.1.4** está instalado, mas o REA recusa por dois motivos: a checagem do Java
    falha (versão não detectada, apesar do JDK 21 da Adoptium) e, no Windows, o perfil do Ghidra
    do REA aceita só PE e 6502 raw. **ELF ARM e MIPS não são analisados neste host.**
  - Hopper: não suportado no Windows.
  - IDA: não configurado (`REA_IDA_MCP_CONFIG`).
- **O objdump** que o REA encontrou (MinGW x86) não decodifica MIPS.
- **Para a decompilação dos binários Android:** rodar o REA num Linux (WSL), onde o Ghidra
  aceita ELF. Até lá, a análise usa `llvm-objdump` e a extração de strings e símbolos.

## Segurança, ativação e App Store

| Mecanismo | No port hoje | No A01 Core |
| --- | --- | --- |
| Secure Boot da Apple (iBoot/img4) | não existe: o LK e o shim iniciam o kernel | não se aplica; o boot é o da MediaTek |
| SEP (Secure Enclave) | ausente | não existe hardware equivalente. O MT6739 tem TrustZone (o TEE do `tee1`), mas não com a interface nem as chaves de fábrica do SEP |
| AMFI / assinatura de código | contornado na base (`cs_enforcement_disable`, `amfi`) | apps próprios rodam |
| Keybag / proteção de dados | sem SEP, sem chaves de hardware | o iOS opera sem classes de proteção com hardware |
| Ativação (albert.apple.com) | pulada pela base do port | exige a identidade de um iPhone real (certificados de fábrica e, no iPhone X, atestação do SEP). **Não é possível de forma legítima** |
| Apple ID | — | o login exige atestação do aparelho. Sem identidade Apple legítima, não |
| App Store (download) | — | os downloads vêm criptografados com FairPlay, cuja chave fica no hardware Apple. **Não é possível** |
| Instalação de apps próprios | possível | IPA assinado por você ou sem assinatura (AMFI desligado): **sim** |

- **Conclusão:** o caminho legítimo é instalar apps que você compila ou de que tem o
  código.
- Ativação, Apple ID, App Store e FairPlay dependem de identidade e chaves de hardware da
  Apple que o A01 Core não tem. **Não vou forjar identidades, certificados nem atestações.**

## Componentes

### Tela e toque

- **Hardware:**
  - painel TDDI 720×1480, em modo vídeo, com o controlador de toque integrado: TD4150 da
    Synaptics (variante principal) ou NT36525B da Novatek;
  - display MT6739: OVL0 → RDMA0 → DSI0.
- **O iOS espera:** um framebuffer (`IOMobileFramebuffer`/`SweetFramebuffer`) e eventos de
  multitoque pelo HID.
- **Reaproveitado:** o framebuffer que o LK deixa ligado, e o protocolo TCM e o firmware
  "zero flash" do kernel GPL (`synaptics/td4150`, `firmware/tsp_synaptics/td4150_a01core.img`).
- **Estado:**
  - **Tela: funciona.** A sonda desenhou e o kernel escreve no framebuffer. Os valores
    `0x76740000`, stride 2944 e 720×1480 foram medidos (patch 0306).
  - **Toque TD4150: iniciou.** O driver (0304) subiu sem erro, segundo o usuário. Ainda não
    houve teste de toque com o iOS rodando.
  - **NT36525B:** não implementado. Fonte em `drivers/input/touchscreen/novatek/nt36525`, com
    host download como no TD4150. Implementar só se o seu aparelho tiver esse painel.
- **Teste:** com o iOS rodando, tocar na tela e conferir o log `A01CORE TOUCH: ready` e a
  resposta na interface.
- **Limites:** brilho, e ligar e desligar a tela, ainda dependem do LK, sem driver de backlight.

### Bateria e energia

- **Hardware:**
  - PMIC MT6357, acessado pelo `pwrap`: mede a tensão da bateria (BATSNS) e detecta o carregador;
  - Samsung S2MU005 por I2C: carregador e medidor de carga (fuel gauge) de verdade.
- **O iOS espera:** um `IOPMPowerSource` com capacidade, tensão e estado de carga. O `powerd` e o
  SpringBoard leem esses dados.
- **Reaproveitado:**
  - `drivers/iio/adc/mt635x-auxadc.c` e `mt6357.dtsi` (canal BATADC, razão 3/1, 15 bits, 1800 mV);
  - `registers.h` do MT6357 (`TOPSTATUS` bit 2, `CHRDET_DEB`);
  - `drivers/battery_v2/s2mu005_fuelgauge.c`, para o próximo passo.
- **Implementado (patch 0307):**
  - `bsd/dev/a01core_power.c`: leitura e escrita no PMIC com trava, tensão da bateria e
    detecção do carregador;
  - `SweetBattery` ligado no A01 Core: o nível é estimado pela tensão, atualizado a cada 30 s.
- **Estado:** implementado; compilação no CI pendente; ainda não testado no aparelho.
- **Teste:** procurar no log `A01CORE POWER: battery NNNN mV, charger present/absent` e
  `SWEET BATTERY: MT6357 BATSNS / estimated SOC`. Conectar e desconectar o carregador e ver a
  mudança. Comparar a tensão com o Android, se possível.
- **Limites:**
  - a porcentagem vem da tensão, então oscila com a carga do processador e marca alto quando
    está carregando;
  - não há medição de corrente;
  - o nível certo depende do fuel gauge S2MU005, que depende do driver I2C.

### Vibração

- **Hardware:** motor ERM alimentado pelo LDO `VIBR` do MT6357.
- **O iOS espera:** o iPhone X usa o Taptic Engine pelos serviços de háptica da Apple (fechados).
- **Reaproveitado:** `drivers/misc/mediatek/vibrator/mt6739/vibrator.c`. O driver da Samsung só
  liga e desliga `RG_LDO_VIBR_EN`, o bit 0 de `0x1b08`.
- **Implementado (patch 0307):** `a01core_vibrate()` e `a01core_vibrate_ms()`. O boot-arg
  `a01vib=N` vibra N ms no boot, para teste.
- **Estado:** implementado; compilação no CI pendente; ainda não testado no aparelho.
- **Teste:** boot com `a01vib=500`. O motor deve vibrar meio segundo e o log mostra
  `A01CORE POWER: vibration test 500 ms`.
- **Próximo passo (ligar ao iOS):** descobrir qual serviço IOKit o `UIFeedbackGenerator`/
  `AudioToolbox` (`AudioServicesPlaySystemSound` 4095) usa no D22AP e expor um serviço com o
  mesmo nome e a mesma interface que chame `a01core_vibrate_ms()`. Se o caminho da Apple não
  puder ser imitado, fazer um tweak de usuário (`libhakios.tweaks` já existe na base) que
  intercepte essas chamadas.

### Sensores

- **Hardware:** acelerômetro LIS2DS da ST (I2C) e sensor de proximidade e luz STK3013 (I2C).
  Não há giroscópio nem magnetômetro (`CONFIG_SENSORS_LIS2DS`, `CONFIG_SENSORS_STK3013`).
- **O iOS espera:** o `locationd`/CoreMotion lê o hub de sensores da Apple (SPU/AOP, fechado).
- **Reaproveitado:** `drivers/sensors/lis2ds_core.c` e `lis2ds_i2c.c`, e `stk3013.c` (registros
  e inicialização).
- **A desenvolver:**
  1. o driver I2C;
  2. os drivers dos dois sensores no XNU;
  3. a entrega dos dados ao iOS. Opções: um serviço HID de acelerômetro (o iOS antigo aceitava
     o `AppleEmbeddedAccelerometer` via HID) ou um tweak no CoreMotion.
- **Estado:** não iniciado.
- **Limites:** rotação de tela e proximidade dependem de um serviço que o iOS aceite. Precisa de
  pesquisa no `locationd` do D22AP.

### Áudio e microfone

- **Hardware:**
  - AFE de áudio do MT6739;
  - codec do MT6357 (DAC, ADC e microfones);
  - amplificador AW8896 do alto-falante (I2C);
  - detecção de fone (`MTK_ACCDET`).
- **O iOS espera:** o `mediaserverd`/`audiomxd` carrega plugins HAL da Apple que falam com
  drivers IOAudio2/`AppleAudio` fechados.
- **Reaproveitado:**
  - `sound/soc/mediatek` (~66 mil linhas, com o AFE do MT6739 e o codec MT6357);
  - `sound/soc/codecs/aw8896.c`;
  - a pesquisa de áudio da base herolte (patches 0278–0283, que chegaram a um tom de teste).
- **Caminho proposto:**
  1. **Kernel:** um driver de saída PCM, com buffer no AFE (DL1 → I2S → codec) e o AW8896
     ligado pelo I2C. Teste com um tom gerado no próprio kernel.
  2. **Ponte para o iOS:** um plugin HAL próprio do CoreAudio. Os plugins HAL são
     `.driver` com uma API pública e documentada (`AudioServerPlugIn`), carregados de
     `/Library/Audio/Plug-Ins/HAL` no macOS. É preciso confirmar se o `audiomxd` do iOS 16
     carrega plugins de terceiros nesse formato. O port já move o `BTAudioHALPlugin`, o que
     indica que essa pasta existe e é lida.
- **Estado:** não iniciado.
- **Falta saber:** quais plugins HAL o `audiomxd` do iOS 16 carrega e com que assinatura.

### Wi-Fi e Bluetooth

- **Hardware:** o CONNSYS interno do MT6739 (`CONSYS_6739`, Wi-Fi 2,4 GHz, BT e GPS), com um
  processador próprio controlado pelo protocolo WMT pela interface BTIF/STP.
- **Firmware:** é fechado, mas está **no aparelho**, na partição `vendor`: `ROMv2/3/4_*`,
  `WIFI_RAM_CODE*` e os patches do processador. Os nomes estão no código do driver.
- **O iOS espera:** o `wifid` e o framework Apple80211 falam com o `AppleBCMWLAN`, e o
  `bluetoothd` fala com o chip da Broadcom por HCI. Os dois são fechados.
- **Fonte disponível:**
  - `drivers/misc/mediatek/connectivity`: ~203 mil linhas, com `wmt_drv`, `wlan_drv_gen2`
    (o driver Wi-Fi completo, com MLME) e `bt`;
  - `drivers/misc/mediatek/btif`: ~7,5 mil linhas.
  - Todo esse código é GPL e é o mesmo que o Android do aparelho usa.
- **Caminho proposto, em etapas, cada uma testável:**
  1. **Ligar o CONNSYS** (WMT: energia, clock, envio dos ROM patches). O teste é a resposta da
     versão do firmware no log.
  2. **Bluetooth:** depois do WMT, o BT fala **HCI padrão** pelo STP. Um driver de transporte
     HCI no XNU e um `bluetoothd` substituto, ou a ponte para o stack da Apple, que também usa
     HCI. O HCI é o protocolo mais padronizado de todos, então esta é a frente mais promissora.
  3. **Wi-Fi:** portar o `wlan_drv_gen2` para o XNU como uma interface de rede (`ifnet`, tipo
     Ethernet). Para conectar com WPA2 é preciso um supplicant: portar o `wpa_supplicant`
     (código aberto) como daemon de usuário. Assim o iOS ganha rede de verdade, mas configurada
     pelo nosso daemon e não pelos Ajustes do iOS.
- **Estado:** não iniciado.
- **Falta saber:** extrair os arquivos de firmware da `vendor` do firmware stock (é possível
  aqui no PC: `super.img` → `vendor` → `/vendor/firmware`) e estimar o tamanho do port do
  `wlan_drv_gen2` (a camada `os/linux` é a parte que precisa ser reescrita).

### Modem e rede móvel

- **Hardware:** o modem LTE interno do MT6739 (MD1), com firmware `md1img` na partição
  `md1img`, e a interface CCCI/CLDMA.
- **O iOS espera:** o `CommCenter` fala com modems Qualcomm ou Intel por protocolos Apple
  (QMI/ARI). Não há como enganá-lo com um modem MediaTek.
- **Fonte disponível:** `drivers/misc/mediatek/eccci` (~32 mil linhas), que liga o modem e
  abre os canais.
- **Caminho proposto:**
  1. ligar o MD1 e abrir o canal de comandos AT;
  2. um daemon próprio que use comandos AT (padrão 3GPP) para SMS, chamadas de voz pelo modem e
     dados (PDP), com uma interface de rede para os dados;
  3. a interface com o usuário do iOS (app Telefone, barra de sinal) não usaria isso sem
     substituir o `CommCenter`. Os dados móveis como interface de rede são o objetivo realista.
- **Estado:** não iniciado. Depende da camada de rede do Wi-Fi, que reaproveita a mesma
  `ifnet`.

### Câmeras

- **Hardware:**
  - sensores MIPI: `s5k4hayx` e `gc8034` (traseira) e `gc5035`/`s5k5e9yx` (frontal);
  - ISP do MT6739 (`cameraisp`): o processamento 3A e a conversão de imagem RAW rodam em
    bibliotecas de usuário fechadas da MediaTek.
- **O iOS espera:** o `mediaserverd`/`AVFoundation` com o pipeline da câmera da Apple (H10 ISP),
  que é fechado.
- **Fonte disponível:**
  - `drivers/misc/mediatek/imgsensor` (~263 mil linhas, com as tabelas I2C de inicialização de
    cada sensor);
  - `cameraisp` (~74 mil linhas, só a parte do kernel).
- **Caminho proposto:**
  1. ligar o sensor pelo I2C e capturar quadros RAW pelo `seninf`/`camsv`, sem ISP;
  2. fazer o demosaico na CPU, numa resolução baixa;
  3. entregar os quadros a um app próprio. A integração com o app Câmera do iOS não é realista.
- **Estado:** não iniciado. Depende do driver I2C.

### GPU (PowerVR Rogue GE8100)

- **Hardware:** PowerVR Rogue GE8100 (`MTK_GPU_VERSION = "rgx auckland 1.8ED"`).
- **O iOS espera:** o driver Metal/AGX da Apple, que é fechado e específico da GPU da Apple.
- **Fonte disponível:**
  - `drivers/misc/mediatek/gpu/gpu_rgx` (~1,1 milhão de linhas): a parte de kernel do DDK da
    Imagination, com licença dual;
  - o firmware `rgx.fw` é fechado, mas está no aparelho (`/vendor/firmware`).
  - O compilador de shaders e o driver de usuário são fechados.
  - O Mesa tem um driver aberto da Imagination (`pvr`, Vulkan), mas hoje só para outras
    gerações (AXE e BXS).
- **Caminho proposto:** o mesmo modelo da base herolte (kernel + Mesa + EAGL), mas o lado do
  usuário não existe para essa GPU. Precisaria estender o `pvr` do Mesa para o GE8100 (BVNC da
  Rogue 8XE) e portar o driver de kernel para o XNU.
- **Estado:** não iniciado. É a frente mais cara.
- **Enquanto isso:** a renderização na CPU continua. O ganho prático vem de diminuir a escala do
  canvas (`sweetfb_lw`/`sweetfb_lh`) e do SMP com 4 núcleos (`cpus=4`).

### USB (rede pelo cabo)

- **Hardware:** o controlador USB 2.0 MUSB do MT6739 (`USB_MTK_HDRC`), com QMU.
- **Fonte disponível:** `drivers/misc/mediatek/usb20` (~21 mil linhas) e os gadgets NCM e RNDIS
  do Linux.
- **Caminho proposto:**
  1. um driver de dispositivo USB (gadget) no XNU;
  2. a função CDC-NCM;
  3. uma interface de rede (`ifnet`).
  - O PC compartilha a internet e o iOS ganha rede pelo cabo.
  - A mesma `ifnet` serve depois para o Wi-Fi e o modem.
- **Estado:** não iniciado.

## Ordem de trabalho

1. **Bateria e vibração** (0307): implementado. Falta testar no aparelho.
2. **Controlador I2C do MT6739.** Destrava o fuel gauge S2MU005, o LIS2DS, o STK3013 e o AW8896.
3. **Fuel gauge S2MU005**, para a porcentagem real, e **acelerômetro**, para a rotação.
4. **Rede pelo USB (NCM)**, com a primeira `ifnet` do port.
5. **CONNSYS/WMT**, e depois o **Bluetooth (HCI)**.
6. **Áudio:** saída PCM no kernel, depois a ponte HAL.
7. **Wi-Fi** (`wlan_drv_gen2` + `wpa_supplicant`), **modem por AT**, **câmera RAW** e **GPU**.
