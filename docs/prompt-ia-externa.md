# Pedido de ajuda: interface do iOS acelerada pela GPU PowerVR GE8100 (Galaxy A01 Core)

Você é um especialista em drivers de GPU (PowerVR Rogue, Mesa, Vulkan), em kernel XNU e em
internals do iOS. Preciso de **caminhos concretos e rápidos** (1 a 2 horas de trabalho) para fazer
a interface do iOS 16 desenhar com a GPU num celular Android, usando o nosso próprio
Metal/Vulkan. Leia tudo antes de responder. **Não invente fatos:** quando não tiver certeza, diga
isso e diga como verificar.

---

## 1. O aparelho

- Samsung Galaxy A01 Core (SM-A013M), SoC MediaTek MT6739, 4x Cortex-A53, RAM limitada a 1 GB
  no nosso boot. Tela de 720x1480.
- GPU **PowerVR GE8100**, Rogue série 8XE, BVNC **22.49.21.16**, firmware MIPS `rgx.fw.22.49.21.16`
  (tirado do vendor da Samsung).
- Erratas (BRN) da GE8100 no DDK: 60084, 61450, 63027, 65168, **65273** (e outras comuns à
  família). A GE8320 (22.102.54.38), na qual o Mesa que usamos foi testado, NÃO tem a 61450 e tem
  as mesmas features. Diferenças de features GE8100 x GE8300/GE8320: só o número de pipes ISP IPP
  (2 x 4), o tamanho do SLC e a largura do barramento.
- O touch é um Novatek NT36525B por SPI. Acabei de portar o driver; ainda não foi testado.

## 2. O que já roda

- **iOS 16.7 (16.7.16) completo** dá boot nesse celular, com o **nosso kernel XNU** (fork
  compilado em CI no macOS, com placa "A01CORE") e o rootfs do iOS na partição userdata (eMMC).
- **A interface do iOS já aparece** (SpringBoard, tela inicial, cores corretas), por um caminho
  inspirado no HakiOS/Bergamota: uma **shim EAGL** (`libheroeagl.dylib`) é injetada no
  `backboardd` pelo kernel e implementa o EAGL/OpenGL ES do CoreAnimation em cima do **OSMesa**
  (Mesa 25.0.7). Hoje roda com **softpipe** (CPU), por isso fica lenta e com bugs visuais (wallpaper
  preto, Dock sem blur).
- O mesmo pacote também traz o **Zink** (GL sobre Vulkan) apontando para o nosso driver Vulkan.
  É só trocar `GALLIUM_DRIVER=zink` por boot-arg (`a01gl=zink`). Isso só vai acelerar quando o
  Vulkan executar trabalho na GPU de verdade.

## 3. A pilha de GPU que construímos (todo o código é nosso ou open source)

1. **Kernel:** o **DDK PowerVR 1.11@5425693** (o mesmo kernel-mode do Android da Samsung)
   portado para XNU, como driver IOKit `A01CoreGPU`. Os user clients são: seletor 0 = bridge
   PVRSRV (os mesmos ioctls do Linux) e seletor 1 = mapear um PMR na task. Temos uma camada OS
   própria (`env/xnu`): PMRs com `IOBufferMemoryDescriptor`, tabelas de MMU em memória contígua
   com limpeza de cache, LISR por polling (thread que dorme 1 ms) e mapeamento "uncached" como
   write-combine. **O firmware MIPS da GPU dá boot**, responde, e o trace do firmware sai decodificado.
2. **Vulkan:** **img-pvr** (github.com/JimVulkan/img-pvr, commit
   9e1c0279d6c0a3e6419c5818a82ae6903e0d921c). É o Mesa `pvr` portado para o kernel DDK 1.11 via
   bridge PVRSRV, com engenharia reversa feita numa GE8320. Compilamos para iOS arm64 como
   `libvulkan_powervr.dylib`. No lugar de `/dev/pvrsrvkm`, uma camada "libdrm" nossa (`a01drm`)
   fala com o IOKit. A GE8100 entrou na tabela do Mesa copiando a ficha da GE8300 (22.V.54.30),
   que tem features idênticas às da GE8320.
3. **Metal:** **A01Metal**, uma implementação nossa de Metal sobre Vulkan (blit, render pass,
   pipeline SPIR-V via glslang), mais um teste automático (`a01metal-test`) que roda no boot.
4. **GL para a UI:** OSMesa + Zink, como descrito na seção 2.

## 4. Todos os bugs já encontrados e corrigidos (para você não sugerir de novo)

- `vk_drm_syncobj_*` (só existe no Linux) impedia o dlopen do driver: viraram stubs. O build-id
  de 16 bytes foi aceito.
- Não existe `/dev/pvr_sync` no iOS: as timelines viraram -1 (sem fences de sync; o "concluído"
  sai no submit + 300 ms).
- `munmap` de PMRs corrompia o malloc: agora o kernel é o dono dos mapeamentos.
- Panic de acesso desalinhado (`ldp q` em memória Device): o modo uncached passou a ser
  mapeado como write-combine (Normal-NC).
- **Layout dos comandos do firmware:** o próprio firmware informa (RGXFW_ALIGNCHECKS)
  CMDTA = 136, CMD3D = 336, CMDTRANSFER = 208 e CMD_COMPUTE = 64 bytes. Os structs do img-pvr
  tinham TA = 128 e 3D = 328. Inserimos 8 bytes: no TA, depois do `partial_render_ta_3d_fence`
  (registro dummy de region header da BRN 63027); no 3D, antes de `flags`. Antes disso, o firmware
  descartava o 3D com "HWRTData=0".
- **BRN 65273:** o DDK cria os heaps "MMU INIA BRN65273" (0xF800000000) e "MMU INIB BRN65273"
  (0xF900000000), e a GPU faltava gravando em 0xF800000000. Agora mapeamos memória zerada na base
  dos dois heaps. Conferido no `libsrv_um.so` original da Samsung: ele aloca um "BRN65273_RgnHeader"
  em cada um. Com a BRN 65273, o heap geral fica em **0x65C0000000**, o PDS em 0xA800000000, o USC
  em 0xBA00000000 e o TQ3DParameters em **0x0** (1 GB).
- **Unidade de página:** no iOS a página da CPU é de 16 KB, e o img-pvr calculava o número de
  páginas do `DevmemIntMapPages` em páginas da CPU, enquanto o kernel conta em páginas do heap
  (4 KB). Só ¼ de cada buffer era mapeado na GPU. Isso foi corrigido.

## 5. O problema ATUAL (é aqui que preciso de ajuda)

O teste 1 faz `vkCmdFillBuffer` + `vkCmdCopyBuffer` (4 KB). O Mesa faz os dois pela **transfer
queue (TQ) no DM 3D**, um "fast 2D" com shader de transferência que lê a origem como textura.

O que se vê no aparelho (FW = firmware):
- O submit chega ao kernel (`RGXSubmitTransfer`, prepare flags 0x70, 208 bytes) e o kick vai para
  o DM3. O FW consome o kCCB e a fila do contexto TQ (a leitura alcança a escrita).
- A primeira falha da GPU registrada no HWR é **DM3, leitura (R), requisitante TCU (texture
  cache), endereço 0x8DFBB2A940**. Esse endereço não está em nenhum heap e não é alinhado a
  página. Antes da correção da página, a falha era o PBE gravando em 0x65C00C6000; ela sumiu.
- Ou seja: a GPU executa o comando de transferência, mas o **estado da imagem de origem**
  (texture state lido pelo TCU) parece lixo, ou o endereço é calculado errado.
- Os testes 2 (render pass com clear para vermelho, sem textura) e 3 (triângulo verde com
  pipeline SPIR-V) ainda não têm resultado confirmado depois das últimas correções.

Hipóteses que ainda não confirmei:
- Layout do texture state (TEXSTATE_IMAGE_WORD0/1) ou do sampler state diferente na GE8100.
- Os shared registers que o PDS carrega (DOUTD) com o texture state estão vindo de um endereço
  errado: o código PDS e os dados ficam no heap PDS, com a base de execução PDS do FW em
  0xA800000000 por causa da BRN 65273.
- Os 8 bytes extras do TA/3D (seção 4) estão no lugar errado, o que afetaria também o TQ.
- Os registros do transfer (CMDTRANSFER de 208 bytes) têm o tamanho certo, mas a ordem pode ser
  outra, por erratas da GE8100.
- Problema de coerência entre o que a CPU escreve (WC) e o que a GPU lê. Isto é pouco provável:
  há só 1 CPU, e o kick passa por `dsb st`.

## 6. Restrições reais (leve todas em conta)

- **Cada build no CI do kernel ou do Vulkan leva cerca de 40 minutos.** Num prazo de 1 a 2 horas
  cabem **no máximo 2 rodadas** de build + teste. Prefira mudanças que se testem num boot só.
- **O usuário não consegue mais fotografar a tela e digita devagar.** Toda informação do
  aparelho chega por **uma linha curta** que o kernel imprime, por exemplo
  `CODIGO: SnHF-0-PcRt` e `FALHA1: DM3 R 8dfbb2a940 TCU`. Qualquer diagnóstico que você propuser
  precisa caber em poucos caracteres numa linha dessas.
- Não dá para ler logs pelo PC: o BROM/MTKClient exige tirar a bateria, e o usuário não sabe fazer.
- **Não sirvo de nada:** usar a GPU da Apple, rodar o blob Android da Samsung no iOS (é ARM32/ELF
  e bionic, e o iOS é arm64/Mach-O), PowerVR do Linux mainline (não suporta Rogue 8XE) ou
  "use software rendering" (já temos softpipe).
- Posso gravar só a partição BOOT. Nada de mexer no bootloader, no EFS ou no recovery.
- Temos o código GPL do kernel do SM-A013, o DDK 1.11 inteiro (lado kernel), os blobs
  `libsrv_um.so`, `libGLESv2_mtk.so`, `libusc.so` e `libIMGegl.so` do vendor (ARM32, sem
  símbolos), e o img-pvr/Mesa completo.

## 7. O que eu quero de você

1. **Os 3 caminhos mais rápidos e mais prováveis**, em ordem, para a GPU executar a cópia, o
   clear e o triângulo corretamente na GE8100 com o img-pvr. Para cada um, diga: o que mudar
   (arquivo e função do Mesa img-pvr ou do DDK), por que você acha que é isso, e como confirmar
   com UMA linha curta de diagnóstico.
2. Especificamente sobre a falha **TCU lendo 0x8DFBB2A940** num transfer 3D da GE8100 com a BRN
   65273: o que costuma causar isso? Por exemplo: o layout do TEXSTATE, o `tex_state_data_offset`
   relativo ao heap PDS, a necessidade de o TQ usar o heap TQ3DParameters em 0x0 com uma entrada
   PCE única de 1 GB, ou o ISP_RGN/IPF.
3. Se existir um atalho para a **UI acelerada hoje** que pule o TQ, diga qual. Por exemplo:
   fazer o Zink/CoreAnimation usar só render passes 3D e compute, sem o caminho de transfer
   (blit/copy feitos por shader ou por compute). Explique o que mudar no Mesa (Zink ou pvr) para
   isso.
4. Riscos e o que NÃO fazer.

Responda em português, direto, com nomes reais de arquivos e funções do Mesa (`src/imagination/...`)
e do DDK 1.11 (`services/server/devices/rgx/...`). Se você não conhece um detalhe específico da
GE8100, diga isso em vez de chutar.
