/* XNU keeps INT_MAX & co. in <machine/limits.h>; the standalone check uses the compiler's. */
#if __has_include(<machine/limits.h>)
#include <machine/limits.h>
#else
#include_next <limits.h>
#endif
