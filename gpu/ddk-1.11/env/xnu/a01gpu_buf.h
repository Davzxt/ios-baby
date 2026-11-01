/*
 * GPU-visible memory for the DDK on XNU. Implemented in the kernel by bsd/dev/a01core_gpu_iokit.cpp
 * with IOBufferMemoryDescriptor (physical mask 0xFFFFFFFF: the GE8100's bus is 32-bit).
 */
#ifndef A01GPU_BUF_H
#define A01GPU_BUF_H
#include <stdint.h>

typedef struct a01gpu_buf a01gpu_buf;

enum { A01GPU_CACHED = 0, A01GPU_UNCACHED = 1, A01GPU_WRITE_COMBINE = 2 };

/* size rounded up to pages; contiguous != 0 asks for one physical run */
a01gpu_buf *a01gpu_buf_alloc(uint64_t size, int contiguous);
void a01gpu_buf_free(a01gpu_buf *b);
void *a01gpu_buf_kva(a01gpu_buf *b);                    /* cached kernel mapping */
uint64_t a01gpu_buf_size(a01gpu_buf *b);
uint64_t a01gpu_buf_phys(a01gpu_buf *b, uint64_t offset);
/* maps the whole buffer into the calling task; returns 0 on success */
int a01gpu_buf_map_user(a01gpu_buf *b, int cache_mode, uint64_t *uaddr);
void a01gpu_buf_unmap_user(a01gpu_buf *b, uint64_t uaddr);
#endif
