/*
 * C interface between the DDK (env/xnu/pvr_xnu_entry.c) and the IOKit driver
 * (iokit/Kernel/A01CoreGPU.cpp). Return values: 0 or a PVRSRV_ERROR code.
 */
#ifndef A01PVR_H
#define A01PVR_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int a01pvr_driver_init(void);
int a01pvr_open(void **ppvConnection);
void a01pvr_close(void *pvConnection);
int a01pvr_bridge(void *pvConnection, uint32_t group, uint32_t func, uint64_t in, uint32_t in_size,
    uint64_t out, uint32_t out_size);
int a01pvr_mmap(void *pvConnection, uint64_t pmr_handle, uint64_t *uaddr);
#ifdef __cplusplus
}
#endif
#endif
