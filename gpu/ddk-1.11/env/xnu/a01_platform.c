/* A01 (XNU): definitions the DDK core expects from platform code */
#include "a01_mtk_stubs.h"
int g_use_id;

/* process_stats.c publishes these hooks for MediaTek's memory reporter; nothing reads them here */
unsigned int (*mtk_get_gpu_memory_usage_fp)(void);
_Bool (*mtk_dump_gpu_memory_usage_fp)(void);
