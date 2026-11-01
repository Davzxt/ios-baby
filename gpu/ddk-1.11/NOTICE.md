# PowerVR Rogue DDK 1.11 (kernel services), for the Galaxy A01 Core

Source: Samsung's GPL kernel for the SM-A013 (A013GXXU4AVF4),
`drivers/misc/mediatek/gpu/gpu_rgx/m1.11ED5425693`. The DDK build matches the phone's
firmware `vendor/firmware/rgx.fw` (1.11@5425693).

Only files whose header says `@License Dual MIT/GPLv2` are here, and they are used under the MIT
license. MediaTek's platform glue (`services/system/rgx_mtk`) and the files without the MIT option
are left out. The A01 replacements (XNU OS layer, GE8100 power, IOKit bridge) live in `env/xnu`.

Copyright (c) Imagination Technologies Ltd. All Rights Reserved. See each file's header for the
full MIT license text.
