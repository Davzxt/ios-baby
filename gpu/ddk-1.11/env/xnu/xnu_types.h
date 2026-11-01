/* Format macros and small types the DDK expects from <inttypes.h> / kernel_types.h (XNU). */
#ifndef XNU_TYPES_H
#define XNU_TYPES_H
#ifndef PRIu64
#define PRIu64 "llu"
#define PRIx64 "llx"
#define PRIX64 "llX"
#define PRId64 "lld"
#define PRIu32 "u"
#define PRIx32 "x"
#define PRIX32 "X"
#define PRId32 "d"
#endif
/* Inside XNU, PAGE_SIZE comes from <mach/vm_param.h>; this fallback is for the standalone check. */
#ifndef PAGE_SIZE
#define PAGE_SHIFT 14
#define PAGE_SIZE (1UL << PAGE_SHIFT)
#endif
#endif
