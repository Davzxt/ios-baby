/*
 * DDK 1.11 physical memory on XNU (Galaxy A01 Core):
 *  - PhysmemNewOSRamBackedPMR: PMRs backed by a01gpu_buf (replaces env/linux/physmem_osmem_linux.c),
 *  - OSPhyContigPages*: contiguous pages for MMU tables and firmware structures,
 *  - user mapping of those PMRs, DMA-BUF and secure buffers reported as not supported.
 * MIT license (see gpu/ddk-1.11/NOTICE.md).
 */
#include "xnu_kpi.h"
#include "a01gpu_buf.h"
#include "a01gpu_host.h"
#include "img_defs.h"
#include "img_types.h"
#include "pvrsrv_error.h"
#include "pvrsrv_memallocflags.h"
#include "osfunc.h"
#include "allocmem.h"
#include "device.h"
#include "pmr.h"
#include "pmr_impl.h"
#include "pmr_os.h"
#include "physmem_osmem.h"
#include "physheap.h"
#include "osmmap.h"
#include "connection_server.h"
#include "physmem_dmabuf.h"

typedef struct {
	a01gpu_buf *buf;
	IMG_UINT64 size;
	PVRSRV_MEMALLOCFLAGS_T flags;
} A01_PMR;

static int
a01_cache_mode(PVRSRV_MEMALLOCFLAGS_T f)
{
	switch (f & PVRSRV_MEMALLOCFLAG_CPU_CACHE_MODE_MASK) {
	case PVRSRV_MEMALLOCFLAG_CPU_UNCACHED:
		return A01GPU_UNCACHED;
	case PVRSRV_MEMALLOCFLAG_CPU_WRITE_COMBINE:
		return A01GPU_WRITE_COMBINE;
	default:
		return A01GPU_CACHED;
	}
}

static PVRSRV_ERROR PMRLock(PMR_IMPL_PRIVDATA p) { (void)p; return PVRSRV_OK; }     /* pinned for life */
static PVRSRV_ERROR PMRUnlock(PMR_IMPL_PRIVDATA p) { (void)p; return PVRSRV_OK; }

static PVRSRV_ERROR
PMRDevPhysAddr(PMR_IMPL_PRIVDATA p, IMG_UINT32 ui32Log2PageSize, IMG_UINT32 n,
    IMG_DEVMEM_OFFSET_T *puiOffset, IMG_BOOL *pbValid, IMG_DEV_PHYADDR *psDevAddr)
{
	A01_PMR *m = p;
	(void)ui32Log2PageSize;
	for (IMG_UINT32 i = 0; i < n; i++) {
		if (pbValid[i]) {
			psDevAddr[i].uiAddr = a01gpu_buf_phys(m->buf, puiOffset[i]);
		}
	}
	return PVRSRV_OK;
}

static PVRSRV_ERROR
PMRAcquireKernelMapping(PMR_IMPL_PRIVDATA p, size_t uiOffset, size_t uiSize, void **ppv,
    IMG_HANDLE *phHandle, PMR_FLAGS_T ulFlags)
{
	A01_PMR *m = p;
	(void)ulFlags;
	if ((IMG_UINT64)uiOffset + uiSize > m->size) {
		return PVRSRV_ERROR_PMR_BAD_MAPPINGTABLE_SIZE;
	}
	*ppv = (IMG_UINT8 *)a01gpu_buf_kva(m->buf) + uiOffset;
	*phHandle = NULL;
	return PVRSRV_OK;
}

static void PMRReleaseKernelMapping(PMR_IMPL_PRIVDATA p, IMG_HANDLE h) { (void)p; (void)h; }

static PVRSRV_ERROR
PMRCopy(A01_PMR *m, IMG_DEVMEM_OFFSET_T off, IMG_UINT8 *buf, size_t sz, size_t *pn, IMG_BOOL write)
{
	if (off >= m->size) {
		*pn = 0;
		return PVRSRV_OK;
	}
	size_t n = (size_t)((off + sz > m->size) ? m->size - off : sz);
	IMG_UINT8 *k = (IMG_UINT8 *)a01gpu_buf_kva(m->buf) + off;
	if (write) {
		memcpy(k, buf, n);
		flush_dcache((vm_offset_t)k, (unsigned)n, 0);
	} else {
		flush_dcache((vm_offset_t)k, (unsigned)n, 0);
		memcpy(buf, k, n);
	}
	*pn = n;
	return PVRSRV_OK;
}

static PVRSRV_ERROR PMRRead(PMR_IMPL_PRIVDATA p, IMG_DEVMEM_OFFSET_T o, IMG_UINT8 *b, size_t s, size_t *pn) { return PMRCopy(p, o, b, s, pn, IMG_FALSE); }
static PVRSRV_ERROR PMRWrite(PMR_IMPL_PRIVDATA p, IMG_DEVMEM_OFFSET_T o, IMG_UINT8 *b, size_t s, size_t *pn) { return PMRCopy(p, o, b, s, pn, IMG_TRUE); }

/* pMMapData: the bridge's A01_PMR_MMAP request (env/xnu/pvr_bridge_xnu.c) */
typedef struct {
	IMG_UINT64 uaddr;
} A01_PMR_MMAP;

static PVRSRV_ERROR
PMRMMap(PMR_IMPL_PRIVDATA p, PMR *psPMR, PMR_MMAP_DATA pMMapData)
{
	A01_PMR *m = p;
	A01_PMR_MMAP *req = pMMapData;
	(void)psPMR;
	return a01gpu_buf_map_user(m->buf, a01_cache_mode(m->flags), &req->uaddr) ? PVRSRV_ERROR_BAD_MAPPING : PVRSRV_OK;
}

static PVRSRV_ERROR
PMRFinalize(PMR_IMPL_PRIVDATA p)
{
	A01_PMR *m = p;
	a01gpu_buf_free(m->buf);
	OSFreeMem(m);
	return PVRSRV_OK;
}

static const PMR_IMPL_FUNCTAB g_sA01PMRFuncTab = {
	.pfnLockPhysAddresses = PMRLock,
	.pfnUnlockPhysAddresses = PMRUnlock,
	.pfnDevPhysAddr = PMRDevPhysAddr,
	.pfnAcquireKernelMappingData = PMRAcquireKernelMapping,
	.pfnReleaseKernelMappingData = PMRReleaseKernelMapping,
	.pfnReadBytes = PMRRead,
	.pfnWriteBytes = PMRWrite,
	.pfnMMap = PMRMMap,
	.pfnFinalize = PMRFinalize,
};

/* Host-backed PMR foundation. No bridge exposes this yet. The caller must
 * transfer one pinned-host reference on success, and retain ownership on
 * failure. Cache visibility and GPU/CPU ownership synchronization are not yet
 * implemented, so this PMR must not be submitted to the device. */
static PVRSRV_ERROR
A01HostDevPhysAddr(PMR_IMPL_PRIVDATA p, IMG_UINT32 log2_page, IMG_UINT32 n,
    IMG_DEVMEM_OFFSET_T *offsets, IMG_BOOL *valid, IMG_DEV_PHYADDR *addresses)
{
	a01gpu_host *host = p;
	/* The import only guarantees contiguous physical runs of 4 KiB. */
	if (log2_page > 12) return PVRSRV_ERROR_INVALID_PARAMS;
	IMG_UINT64 length = a01gpu_host_size(host);
	IMG_UINT64 page_size = 1ULL << log2_page;
	for (IMG_UINT32 i = 0; i < n; i++) {
		if (!valid[i]) continue;
		if ((offsets[i] & (page_size - 1)) || offsets[i] >= length ||
		    page_size > length - offsets[i])
			return PVRSRV_ERROR_INVALID_PARAMS;
		IMG_UINT64 phys = a01gpu_host_phys(host, offsets[i]);
		if (!phys || phys >= 0x100000000ULL) return PVRSRV_ERROR_INVALID_PARAMS;
		addresses[i].uiAddr = phys;
	}
	return PVRSRV_OK;
}

static PVRSRV_ERROR
A01HostAcquireKernelMapping(PMR_IMPL_PRIVDATA p, size_t offset, size_t size,
    void **out, IMG_HANDLE *handle, PMR_FLAGS_T flags)
{
	a01gpu_host *host = p;
	IMG_UINT64 length = a01gpu_host_size(host);
	(void)flags;
	if (offset > length || size > length - offset || !a01gpu_host_kva(host))
		return PVRSRV_ERROR_PMR_BAD_MAPPINGTABLE_SIZE;
	*out = (IMG_UINT8 *)a01gpu_host_kva(host) + offset;
	*handle = NULL;
	return PVRSRV_OK;
}

static PVRSRV_ERROR
A01HostFinalize(PMR_IMPL_PRIVDATA p)
{
	a01gpu_host_unpin(p);
	return PVRSRV_OK;
}

static const PMR_IMPL_FUNCTAB g_sA01HostPMRFuncTab = {
	.pfnLockPhysAddresses = PMRLock,
	.pfnUnlockPhysAddresses = PMRUnlock,
	.pfnDevPhysAddr = A01HostDevPhysAddr,
	.pfnAcquireKernelMappingData = A01HostAcquireKernelMapping,
	.pfnReleaseKernelMappingData = PMRReleaseKernelMapping,
	.pfnFinalize = A01HostFinalize,
};

PVRSRV_ERROR
a01pvr_create_host_pmr(PVRSRV_DEVICE_NODE *device, a01gpu_host *host,
    PVRSRV_MEMALLOCFLAGS_T flags, PMR **out)
{
	if (!device || !host || !out) return PVRSRV_ERROR_INVALID_PARAMS;
	IMG_UINT64 size = a01gpu_host_size(host);
	if (!size || (size & 0x3fffULL)) return PVRSRV_ERROR_INVALID_PARAMS;
	IMG_UINT32 map = 0;
	PMR_FLAGS_T pmr_flags = (PMR_FLAGS_T)(flags & PVRSRV_MEMALLOCFLAGS_PMRFLAGSMASK);
	return PMRCreatePMR(device, device->apsPhysHeap[PVRSRV_DEVICE_PHYS_HEAP_CPU_LOCAL],
	    size, size, 1, 1, &map, 12, pmr_flags, "A01 host import (disabled)",
	    &g_sA01HostPMRFuncTab, host, PMR_TYPE_OSMEM, out, 0);
}

PVRSRV_ERROR
PhysmemNewOSRamBackedPMR(PVRSRV_DEVICE_NODE *psDevNode, IMG_DEVMEM_SIZE_T uiSize,
    IMG_DEVMEM_SIZE_T uiChunkSize, IMG_UINT32 ui32NumPhysChunks, IMG_UINT32 ui32NumVirtChunks,
    IMG_UINT32 *pui32MappingTable, IMG_UINT32 uiLog2PageSize, PVRSRV_MEMALLOCFLAGS_T uiFlags,
    const IMG_CHAR *pszAnnotation, IMG_PID uiPid, PMR **ppsPMROut)
{
	(void)uiPid;
	/* Sparse allocations (physical chunks fewer than virtual ones) are not supported yet. */
	if (ui32NumPhysChunks != ui32NumVirtChunks) {
		return PVRSRV_ERROR_NOT_SUPPORTED;
	}
	A01_PMR *m = OSAllocZMem(sizeof(*m));
	if (!m) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	m->size = uiSize;
	m->flags = uiFlags;
	m->buf = a01gpu_buf_alloc(uiSize, IMG_FALSE, a01_cache_mode(uiFlags));
	if (!m->buf) {
		OSFreeMem(m);
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	/* ZERO_ON_ALLOC / POISON: always zero, then push it out of the CPU caches for the GPU */
	memset(a01gpu_buf_kva(m->buf), 0, (size_t)uiSize);
	flush_dcache((vm_offset_t)a01gpu_buf_kva(m->buf), (unsigned)uiSize, 0);

	PMR_FLAGS_T uiPMRFlags = (PMR_FLAGS_T)(uiFlags & PVRSRV_MEMALLOCFLAGS_PMRFLAGSMASK);
	PVRSRV_ERROR e = PMRCreatePMR(psDevNode, psDevNode->apsPhysHeap[PVRSRV_DEVICE_PHYS_HEAP_CPU_LOCAL],
	    uiSize, uiChunkSize, ui32NumPhysChunks, ui32NumVirtChunks, pui32MappingTable, uiLog2PageSize,
	    uiPMRFlags, pszAnnotation, &g_sA01PMRFuncTab, m, PMR_TYPE_OSMEM, ppsPMROut, 0);
	if (e != PVRSRV_OK) {
		a01gpu_buf_free(m->buf);
		OSFreeMem(m);
	}
	return e;
}

PVRSRV_ERROR
OSChangeSparseMemCPUAddrMap(void **psPageArray, IMG_UINT64 sCpuVAddrBase, IMG_CPU_PHYADDR sCpuPAHeapBase,
    IMG_UINT32 ui32AllocPageCount, IMG_UINT32 *pai32AllocIndices, IMG_UINT32 ui32FreePageCount,
    IMG_UINT32 *pai32FreeIndices, IMG_BOOL bIsLMA)
{
	(void)psPageArray; (void)sCpuVAddrBase; (void)sCpuPAHeapBase; (void)ui32AllocPageCount;
	(void)pai32AllocIndices; (void)ui32FreePageCount; (void)pai32FreeIndices; (void)bIsLMA;
	return PVRSRV_ERROR_NOT_SUPPORTED;
}

/* PMRs from other factories (LMA, firmware heaps) are not mapped into user space on XNU yet */
PVRSRV_ERROR OSMMapPMRGeneric(PMR *psPMR, PMR_MMAP_DATA pOSMMapData) { (void)psPMR; (void)pOSMMapData; return PVRSRV_ERROR_NOT_SUPPORTED; }

/*
 * osmmap.h, kernel side (env/linux/osmmap_stub.c): the shared devicemem code "maps" a PMR for the
 * kernel itself (DevmemAcquireCpuVirtAddr, e.g. InfoPageCreate) through this function. The PMR's
 * kernel mapping is the answer, exactly as on Linux.
 */
PVRSRV_ERROR
OSMMapPMR(IMG_HANDLE hBridge, IMG_HANDLE hPMR, IMG_DEVMEM_SIZE_T uiPMRSize, IMG_UINT32 uiFlags,
    IMG_HANDLE *phOSMMapPrivDataOut, void **ppvMappingAddressOut, size_t *puiMappingLengthOut)
{
	PMR *psPMR = hPMR;
	void *pvKernelAddress;
	size_t uiLength;
	IMG_HANDLE hPriv;
	PVRSRV_ERROR e;
	(void)hBridge; (void)uiPMRSize; (void)uiFlags;
	if (PMR_IsSparse(psPMR)) {
		e = PMRAcquireSparseKernelMappingData(psPMR, 0, 0, &pvKernelAddress, &uiLength, &hPriv);
	} else {
		e = PMRAcquireKernelMappingData(psPMR, 0, 0, &pvKernelAddress, &uiLength, &hPriv);
	}
	if (e != PVRSRV_OK) {
		return e;
	}
	*phOSMMapPrivDataOut = hPriv;
	*ppvMappingAddressOut = pvKernelAddress;
	*puiMappingLengthOut = uiLength;
	return PVRSRV_OK;
}

void
OSMUnmapPMR(IMG_HANDLE hBridge, IMG_HANDLE hPMR, IMG_HANDLE hOSMMapPrivData, void *pvMappingAddress,
    size_t uiMappingLength)
{
	(void)hBridge; (void)pvMappingAddress; (void)uiMappingLength;
	PMRReleaseKernelMappingData((PMR *)hPMR, hOSMMapPrivData);
}

/* ---- contiguous pages (MMU page tables) ------------------------------------------------------- */
PVRSRV_ERROR
OSPhyContigPagesAlloc(PVRSRV_DEVICE_NODE *psDevNode, size_t uiSize, PG_HANDLE *psMemHandle,
    IMG_DEV_PHYADDR *psDevPAddr)
{
	(void)psDevNode;
	a01gpu_buf *b = a01gpu_buf_alloc(uiSize, IMG_TRUE, A01GPU_CACHED);   /* MMU tables: cached + OSPhyContigPagesClean */
	if (!b) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	memset(a01gpu_buf_kva(b), 0, uiSize);
	flush_dcache((vm_offset_t)a01gpu_buf_kva(b), (unsigned)uiSize, 0);
	psMemHandle->u.pvHandle = b;
	psMemHandle->ui32Order = (IMG_UINT32)OSGetOrder(uiSize);
	psDevPAddr->uiAddr = a01gpu_buf_phys(b, 0);
	return PVRSRV_OK;
}

void
OSPhyContigPagesFree(PVRSRV_DEVICE_NODE *psDevNode, PG_HANDLE *psMemHandle)
{
	(void)psDevNode;
	a01gpu_buf_free(psMemHandle->u.pvHandle);
	psMemHandle->u.pvHandle = NULL;
}

PVRSRV_ERROR
OSPhyContigPagesMap(PVRSRV_DEVICE_NODE *psDevNode, PG_HANDLE *psMemHandle, size_t uiSize,
    IMG_DEV_PHYADDR *psDevPAddr, void **pvPtr)
{
	(void)psDevNode; (void)uiSize; (void)psDevPAddr;
	*pvPtr = a01gpu_buf_kva(psMemHandle->u.pvHandle);
	return PVRSRV_OK;
}

void OSPhyContigPagesUnmap(PVRSRV_DEVICE_NODE *psDevNode, PG_HANDLE *psMemHandle, void *pvPtr) { (void)psDevNode; (void)psMemHandle; (void)pvPtr; }

PVRSRV_ERROR
OSPhyContigPagesClean(PVRSRV_DEVICE_NODE *psDevNode, PG_HANDLE *psMemHandle, IMG_UINT32 uiOffset, IMG_UINT32 uiLength)
{
	(void)psDevNode;
	clean_dcache((vm_offset_t)a01gpu_buf_kva(psMemHandle->u.pvHandle) + uiOffset, uiLength, 0);
	return PVRSRV_OK;
}

/* ---- imports that need Linux objects ------------------------------------------------------------ */
PVRSRV_ERROR
PhysmemImportSecBuf(CONNECTION_DATA *psConnection, PVRSRV_DEVICE_NODE *psDevNode, IMG_DEVMEM_SIZE_T uiSize,
    IMG_UINT32 ui32Log2Align, PVRSRV_MEMALLOCFLAGS_T uiFlags, PMR **ppsPMRPtr, IMG_UINT64 *pui64SecBufHandle)
{
	(void)psConnection; (void)psDevNode; (void)uiSize; (void)ui32Log2Align; (void)uiFlags;
	(void)ppsPMRPtr; (void)pui64SecBufHandle;
	return PVRSRV_ERROR_NOT_SUPPORTED;
}

/* DMA-BUF is a Linux object; buffers shared with the display go through IOSurface on iOS. */
PVRSRV_ERROR
PhysmemImportDmaBuf(CONNECTION_DATA *psConnection, PVRSRV_DEVICE_NODE *psDevNode, IMG_INT fd,
    PVRSRV_MEMALLOCFLAGS_T uiFlags, IMG_UINT32 ui32NameSize, const IMG_CHAR pszName[DEVMEM_ANNOTATION_MAX_LEN],
    PMR **ppsPMRPtr, IMG_DEVMEM_SIZE_T *puiSize, IMG_DEVMEM_ALIGN_T *puiAlign)
{
	(void)psConnection; (void)psDevNode; (void)fd; (void)uiFlags; (void)ui32NameSize; (void)pszName;
	(void)ppsPMRPtr; (void)puiSize; (void)puiAlign;
	return PVRSRV_ERROR_NOT_SUPPORTED;
}

PVRSRV_ERROR
PhysmemExportDmaBuf(CONNECTION_DATA *psConnection, PVRSRV_DEVICE_NODE *psDevNode, PMR *psPMR, IMG_INT *piFd)
{
	(void)psConnection; (void)psDevNode; (void)psPMR; (void)piFd;
	return PVRSRV_ERROR_NOT_SUPPORTED;
}

PVRSRV_ERROR
PhysmemImportSparseDmaBuf(CONNECTION_DATA *psConnection, PVRSRV_DEVICE_NODE *psDevNode, IMG_INT fd,
    PVRSRV_MEMALLOCFLAGS_T uiFlags, IMG_DEVMEM_SIZE_T uiChunkSize, IMG_UINT32 ui32NumPhysChunks,
    IMG_UINT32 ui32NumVirtChunks, IMG_UINT32 *pui32MappingTable, IMG_UINT32 ui32NameSize,
    const IMG_CHAR pszName[DEVMEM_ANNOTATION_MAX_LEN], PMR **ppsPMRPtr, IMG_DEVMEM_SIZE_T *puiSize,
    IMG_DEVMEM_ALIGN_T *puiAlign)
{
	(void)psConnection; (void)psDevNode; (void)fd; (void)uiFlags; (void)uiChunkSize; (void)ui32NumPhysChunks;
	(void)ui32NumVirtChunks; (void)pui32MappingTable; (void)ui32NameSize; (void)pszName; (void)ppsPMRPtr;
	(void)puiSize; (void)puiAlign;
	return PVRSRV_ERROR_NOT_SUPPORTED;
}
