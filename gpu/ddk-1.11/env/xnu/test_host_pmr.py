#!/usr/bin/env python3
"""Exercise the unexposed host PMR implementation with a mock DDK backend.

This checks bounds and ownership only, not real IOKit or cache coherence.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).parent / 'physmem_xnu.c').read_text()
start = source.index('/* Host-backed PMR foundation.')
end = source.index('\nPVRSRV_ERROR\nPhysmemNewOSRamBackedPMR', start)
actual = source[start:end]
prefix = r'''
#include <stdint.h>
#include <stddef.h>
#include <assert.h>
#define IMG_TRUE 1
#define PVRSRV_OK 0
#define PVRSRV_ERROR_INVALID_PARAMS 1
#define PVRSRV_ERROR_PMR_BAD_MAPPINGTABLE_SIZE 2
#define PVRSRV_DEVICE_PHYS_HEAP_CPU_LOCAL 0
#define PVRSRV_MEMALLOCFLAGS_PMRFLAGSMASK 0xffffu
#define PMR_TYPE_OSMEM 1
typedef int PVRSRV_ERROR; typedef void *PMR_IMPL_PRIVDATA; typedef void *IMG_HANDLE;
typedef uint32_t IMG_UINT32; typedef uint64_t IMG_UINT64; typedef uint8_t IMG_UINT8;
typedef uint64_t IMG_DEVMEM_OFFSET_T; typedef int IMG_BOOL; typedef uint32_t PMR_FLAGS_T;
typedef uint32_t PVRSRV_MEMALLOCFLAGS_T; typedef struct { uint64_t uiAddr; } IMG_DEV_PHYADDR;
typedef struct { void *apsPhysHeap[1]; } PVRSRV_DEVICE_NODE; typedef struct { int dummy; } PMR;
typedef struct { uint64_t size, phys; int mapped; } a01gpu_host;
static int released, create_error; static const void *table;
static uint64_t a01gpu_host_size(a01gpu_host *h) { return h->size; }
static uint64_t a01gpu_host_phys(a01gpu_host *h, uint64_t o) { return h->phys+o; }
static void *a01gpu_host_kva(a01gpu_host *h) { return h->mapped ? (void *)0x10000 : 0; }
static void a01gpu_host_unpin(a01gpu_host *h) { (void)h; released++; }
static int PMRLock(void *p) { (void)p; return 0; }
static int PMRUnlock(void *p) { (void)p; return 0; }
static void PMRReleaseKernelMapping(void *p, void *h) { (void)p; (void)h; }
typedef struct {
 int (*pfnLockPhysAddresses)(void *); int (*pfnUnlockPhysAddresses)(void *);
 int (*pfnDevPhysAddr)(void *,uint32_t,uint32_t,uint64_t *,int *,IMG_DEV_PHYADDR *);
 int (*pfnAcquireKernelMappingData)(void *,size_t,size_t,void **,void **,uint32_t);
 void (*pfnReleaseKernelMappingData)(void *,void *); int (*pfnFinalize)(void *);
} PMR_IMPL_FUNCTAB;
static int PMRCreatePMR(PVRSRV_DEVICE_NODE *d,void *h,uint64_t size,uint64_t chunk,
 uint32_t physical,uint32_t virt,uint32_t *map,uint32_t log2,uint32_t flags,const char *name,
 const PMR_IMPL_FUNCTAB *ops,void *priv,int type,PMR **out,int tail) {
 (void)d;(void)h;(void)flags;(void)name;(void)priv;(void)type;(void)tail;
 assert(size==chunk && physical==1 && virt==1 && *map==0 && log2==12);
 table=ops; if(create_error) return 3; static PMR p; *out=&p; return 0;
}
'''
suffix = r'''
int main(void) {
 PVRSRV_DEVICE_NODE device={0}; PMR *pmr=0; a01gpu_host host={0x4000,0x20000000,1};
 assert(a01pvr_create_host_pmr(&device,&host,0,&pmr)==0 && pmr);
 const PMR_IMPL_FUNCTAB *ops=table; uint64_t offsets[]={0,0x3000,0x3fff};
 int valid[]={1,1,1}; IMG_DEV_PHYADDR addresses[3]={{0}};
 assert(ops->pfnDevPhysAddr(&host,12,2,offsets,valid,addresses)==0);
 assert(addresses[0].uiAddr==0x20000000 && addresses[1].uiAddr==0x20003000);
 assert(ops->pfnDevPhysAddr(&host,12,3,offsets,valid,addresses)==1);
 assert(ops->pfnDevPhysAddr(&host,13,1,offsets,valid,addresses)==1);
 void *ptr=0,*token=(void *)1;
 assert(ops->pfnAcquireKernelMappingData(&host,0x3fff,1,&ptr,&token,0)==0);
 assert(ptr==(void *)0x13fff && !token);
 assert(ops->pfnAcquireKernelMappingData(&host,0x3fff,2,&ptr,&token,0)==2);
 assert(ops->pfnFinalize(&host)==0 && released==1);
 create_error=1; released=0; pmr=0;
 assert(a01pvr_create_host_pmr(&device,&host,0,&pmr)==3 && released==0);
 host.size=0x4001; assert(a01pvr_create_host_pmr(&device,&host,0,&pmr)==1);
}
'''
with tempfile.TemporaryDirectory() as d:
    c = Path(d) / 'pmr.c'
    exe = Path(d) / 'pmr'
    c.write_text(prefix + actual + suffix, encoding='utf-8')
    subprocess.run(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: PMR bounds, address translation and ownership on success/failure')
