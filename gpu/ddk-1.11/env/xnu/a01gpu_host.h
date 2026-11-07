/* A01 host-page import foundation. Not exposed to user space yet. */
#ifndef A01GPU_HOST_H
#define A01GPU_HOST_H
#include <stdint.h>

typedef struct a01gpu_host a01gpu_host;
/* Pins a page-aligned range owned by the current task; NULL means refusal. */
a01gpu_host *a01gpu_host_pin(uint64_t address, uint64_t length);
void a01gpu_host_unpin(a01gpu_host *host);
uint64_t a01gpu_host_phys(a01gpu_host *host, uint64_t offset);
void *a01gpu_host_kva(a01gpu_host *host);
uint64_t a01gpu_host_size(a01gpu_host *host);
/* Cache maintenance only; caller must separately enforce CPU/GPU ownership. */
int a01gpu_host_flush(a01gpu_host *host, uint64_t offset, uint64_t length);
#endif
