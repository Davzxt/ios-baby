/* A01 (XNU): MediaTek's GPU log ring (mtk_pp) is not ported; its calls compile to nothing. */
#ifndef A01_MTK_STUBS_H
#define A01_MTK_STUBS_H
#define MTKPP_ID_FW          0
#define MTKPP_ID_SHOT_FW     1
#define MTKPP_LOG(...)       do { } while (0)
#define MTKPP_LOGTIME(...)   do { } while (0)
#define MTK_DEBUG_VERSION_STR "a01core"
extern int g_use_id;
#define MTKPP_TriggerAEE(x) do { } while (0)
#define pr_warn(...) printf(__VA_ARGS__)
int printf(const char *, ...);
#endif
