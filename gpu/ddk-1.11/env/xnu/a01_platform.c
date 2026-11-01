/* A01 (XNU): definitions the DDK core expects from platform code */
#include "a01_mtk_stubs.h"
int g_use_id;

/* process_stats.c publishes these hooks for MediaTek's memory reporter; nothing reads them here */
unsigned int (*mtk_get_gpu_memory_usage_fp)(void);
_Bool (*mtk_dump_gpu_memory_usage_fp)(void);

/* XNU does not export strcpy/strcat (only the bounded forms); a few DDK debug paths use them. */
char *
strcpy(char *dst, const char *src)
{
	char *d = dst;
	while ((*d++ = *src++) != '\0') {
	}
	return dst;
}

char *
strcat(char *dst, const char *src)
{
	char *d = dst;
	while (*d != '\0') {
		d++;
	}
	strcpy(d, src);
	return dst;
}
