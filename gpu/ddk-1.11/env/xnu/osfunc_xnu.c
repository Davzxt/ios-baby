/*
 * DDK 1.11 OS layer for XNU (Galaxy A01 Core): memory, locks, atomics, time, strings, events,
 * threads, MISRs, registers, cache maintenance, user copies, process info.
 * Behaviour follows env/linux/osfunc.c, event.c and allocmem.c of the same DDK.
 * MIT license (see gpu/ddk-1.11/NOTICE.md).
 */
#include "xnu_kpi.h"
#include "img_defs.h"
#include "img_types.h"
#include "pvrsrv_error.h"
#include "osfunc.h"
#include "allocmem.h"
#include "lock.h"
#include "pvr_debug.h"
#include "cache_km.h"
#include "device.h"

static lck_grp_t *gA01LockGrp;

static lck_grp_t *
a01_grp(void)
{
	if (!gA01LockGrp) {
		gA01LockGrp = lck_grp_alloc_init("pvrsrvkm", NULL);
	}
	return gA01LockGrp;
}

/* ---- memory: a 16-byte header keeps the size IOFree needs ------------------------------ */
#define A01_HDR 16u

static void *
a01_alloc(IMG_UINT32 ui32Size, IMG_BOOL bZero)
{
	uint8_t *p = IOMalloc((vm_size_t)ui32Size + A01_HDR);
	if (!p) {
		return NULL;
	}
	*(vm_size_t *)p = (vm_size_t)ui32Size + A01_HDR;
	if (bZero) {
		memset(p + A01_HDR, 0, ui32Size);
	}
	return p + A01_HDR;
}

static void
a01_free(void *pv)
{
	if (pv) {
		uint8_t *p = (uint8_t *)pv - A01_HDR;
		IOFree(p, *(vm_size_t *)p);
	}
}

void *OSAllocMem(IMG_UINT32 ui32Size) { return a01_alloc(ui32Size, IMG_FALSE); }
void *OSAllocZMem(IMG_UINT32 ui32Size) { return a01_alloc(ui32Size, IMG_TRUE); }
void *OSAllocMemNoStats(IMG_UINT32 ui32Size) { return a01_alloc(ui32Size, IMG_FALSE); }
void *OSAllocZMemNoStats(IMG_UINT32 ui32Size) { return a01_alloc(ui32Size, IMG_TRUE); }
void (OSFreeMem)(void *pvCpuVAddr) { a01_free(pvCpuVAddr); }
void (OSFreeMemNoStats)(void *pvCpuVAddr) { a01_free(pvCpuVAddr); }

IMG_INT OSMemCmp(void *pvBufA, void *pvBufB, size_t uiLen) { return memcmp(pvBufA, pvBufB, uiLen); }

/* ---- locks ------------------------------------------------------------------------------ */
struct _OS_LOCK_ {
	lck_mtx_t *mtx;
	volatile thread_t owner;
};

PVRSRV_ERROR
OSLockCreate(POS_LOCK *phLock)
{
	struct _OS_LOCK_ *l = OSAllocZMemNoStats(sizeof(*l));
	if (!l) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	l->mtx = lck_mtx_alloc_init(a01_grp(), NULL);
	if (!l->mtx) {
		OSFreeMemNoStats(l);
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	*phLock = l;
	return PVRSRV_OK;
}

PVRSRV_ERROR
OSLockDestroy(POS_LOCK hLock)
{
	if (hLock) {
		lck_mtx_free(hLock->mtx, a01_grp());
		OSFreeMemNoStats(hLock);
	}
	return PVRSRV_OK;
}

void
OSLockAcquire(POS_LOCK hLock)
{
	lck_mtx_lock(hLock->mtx);
	hLock->owner = current_thread();
}

IMG_BOOL
OSTryLockAcquire(POS_LOCK hLock)
{
	if (!lck_mtx_try_lock(hLock->mtx)) {
		return IMG_FALSE;
	}
	hLock->owner = current_thread();
	return IMG_TRUE;
}

void
OSLockRelease(POS_LOCK hLock)
{
	hLock->owner = NULL;
	lck_mtx_unlock(hLock->mtx);
}

IMG_BOOL OSLockIsLocked(POS_LOCK hLock) { return hLock->owner != NULL ? IMG_TRUE : IMG_FALSE; }

struct _OSWR_LOCK_ {
	lck_rw_t *rw;
};

PVRSRV_ERROR
OSWRLockCreate(POSWR_LOCK *ppsLock)
{
	struct _OSWR_LOCK_ *l = OSAllocZMem(sizeof(*l));
	if (!l) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	l->rw = lck_rw_alloc_init(a01_grp(), NULL);
	*ppsLock = l;
	return l->rw ? PVRSRV_OK : PVRSRV_ERROR_OUT_OF_MEMORY;
}

void
OSWRLockDestroy(POSWR_LOCK psLock)
{
	if (psLock) {
		lck_rw_free(psLock->rw, a01_grp());
		OSFreeMem(psLock);
	}
}

void OSWRLockAcquireRead(POSWR_LOCK psLock) { lck_rw_lock_shared(psLock->rw); }
void OSWRLockReleaseRead(POSWR_LOCK psLock) { lck_rw_unlock_shared(psLock->rw); }
void OSWRLockAcquireWrite(POSWR_LOCK psLock) { lck_rw_lock_exclusive(psLock->rw); }
void OSWRLockReleaseWrite(POSWR_LOCK psLock) { lck_rw_unlock_exclusive(psLock->rw); }

/* ---- atomics ---------------------------------------------------------------------------- */
IMG_INT32 OSAtomicRead(const ATOMIC_T *p) { return __atomic_load_n(&p->counter, __ATOMIC_SEQ_CST); }
void OSAtomicWrite(ATOMIC_T *p, IMG_INT32 v) { __atomic_store_n(&p->counter, v, __ATOMIC_SEQ_CST); }
IMG_INT32 OSAtomicIncrement(ATOMIC_T *p) { return __atomic_add_fetch(&p->counter, 1, __ATOMIC_SEQ_CST); }
IMG_INT32 OSAtomicDecrement(ATOMIC_T *p) { return __atomic_sub_fetch(&p->counter, 1, __ATOMIC_SEQ_CST); }
IMG_INT32 OSAtomicAdd(ATOMIC_T *p, IMG_INT32 v) { return __atomic_add_fetch(&p->counter, v, __ATOMIC_SEQ_CST); }
IMG_INT32 OSAtomicSubtract(ATOMIC_T *p, IMG_INT32 v) { return __atomic_sub_fetch(&p->counter, v, __ATOMIC_SEQ_CST); }

void OSMemoryBarrier(void) { __asm__ volatile ("dsb sy" ::: "memory"); }
void OSWriteMemoryBarrier(void) { __asm__ volatile ("dsb st" ::: "memory"); }

/* ---- time ------------------------------------------------------------------------------- */
IMG_UINT64
OSClockns64(void)
{
	uint64_t ns;
	absolutetime_to_nanoseconds(mach_absolute_time(), &ns);
	return ns;
}

IMG_UINT64 OSClockus64(void) { return OSClockns64() / 1000u; }
IMG_UINT32 OSClockus(void) { return (IMG_UINT32)OSClockus64(); }
IMG_UINT32 OSClockms(void) { return (IMG_UINT32)(OSClockns64() / 1000000u); }
IMG_UINT64 OSClockMonotonicRawns64(void) { return OSClockns64(); }

PVRSRV_ERROR
OSClockMonotonicns64(IMG_UINT64 *pui64Time)
{
	*pui64Time = OSClockns64();
	return PVRSRV_OK;
}

void OSWaitus(IMG_UINT32 ui32Timeus) { delay((int)ui32Timeus); }
void OSSleepms(IMG_UINT32 ui32Timems) { IOSleep(ui32Timems); }
void OSReleaseThreadQuanta(void) { thread_block(NULL); }

IMG_UINT32
OSDivide64(IMG_UINT64 ui64Divident, IMG_UINT32 ui32Divisor, IMG_UINT32 *pui32Remainder)
{
	*pui32Remainder = (IMG_UINT32)(ui64Divident % ui32Divisor);
	return (IMG_UINT32)(ui64Divident / ui32Divisor);
}

IMG_UINT64
OSDivide64r64(IMG_UINT64 ui64Divident, IMG_UINT32 ui32Divisor, IMG_UINT32 *pui32Remainder)
{
	*pui32Remainder = (IMG_UINT32)(ui64Divident % ui32Divisor);
	return ui64Divident / ui32Divisor;
}

/* ---- strings ---------------------------------------------------------------------------- */
IMG_INT32
OSSNPrintf(IMG_CHAR *pStr, size_t ui32Size, const IMG_CHAR *pszFormat, ...)
{
	va_list ap;
	va_start(ap, pszFormat);
	int n = vsnprintf(pStr, ui32Size, pszFormat, ap);
	va_end(ap);
	return n;
}

IMG_UINT32
OSVSScanf(IMG_CHAR *pStr, const IMG_CHAR *pszFormat, ...)
{
	va_list ap;
	va_start(ap, pszFormat);
	int n = vsscanf(pStr, pszFormat, ap);
	va_end(ap);
	return (IMG_UINT32)n;
}

size_t OSStringLength(const IMG_CHAR *pStr) { return strlen(pStr); }
size_t OSStringNLength(const IMG_CHAR *pStr, size_t uiCount) { return strnlen(pStr, uiCount); }
IMG_INT32 OSStringCompare(const IMG_CHAR *a, const IMG_CHAR *b) { return strcmp(a, b); }
IMG_INT32 OSStringNCompare(const IMG_CHAR *a, const IMG_CHAR *b, size_t n) { return strncmp(a, b, n); }
IMG_CHAR *OSStringNCopy(IMG_CHAR *d, const IMG_CHAR *s, size_t n) { return strncpy(d, s, n); }
size_t OSStringLCopy(IMG_CHAR *d, const IMG_CHAR *s, size_t n) { return strlcpy(d, s, n); }

/* ---- events: a generation counter per object, one cursor per opener (env/linux/event.c) -- */
typedef struct {
	lck_mtx_t *mtx;
	volatile IMG_UINT32 gen;
	ATOMIC_T refs;
} A01_EVENT_OBJECT;

typedef struct {
	A01_EVENT_OBJECT *obj;
	IMG_UINT32 seen;
} A01_EVENT_HANDLE;

PVRSRV_ERROR
OSEventObjectCreate(const IMG_CHAR *pszName, IMG_HANDLE *phEventObject)
{
	(void)pszName;
	A01_EVENT_OBJECT *o = OSAllocZMem(sizeof(*o));
	if (!o) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	o->mtx = lck_mtx_alloc_init(a01_grp(), NULL);
	OSAtomicWrite(&o->refs, 1);
	*phEventObject = o;
	return PVRSRV_OK;
}

static void
a01_event_put(A01_EVENT_OBJECT *o)
{
	if (OSAtomicDecrement(&o->refs) == 0) {
		lck_mtx_free(o->mtx, a01_grp());
		OSFreeMem(o);
	}
}

PVRSRV_ERROR
OSEventObjectDestroy(IMG_HANDLE hEventObject)
{
	if (hEventObject) {
		a01_event_put(hEventObject);
	}
	return PVRSRV_OK;
}

PVRSRV_ERROR
OSEventObjectOpen(IMG_HANDLE hEventObject, IMG_HANDLE *phOSEvent)
{
	A01_EVENT_OBJECT *o = hEventObject;
	A01_EVENT_HANDLE *h = OSAllocZMem(sizeof(*h));
	if (!h) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	OSAtomicIncrement(&o->refs);
	h->obj = o;
	h->seen = o->gen;
	*phOSEvent = h;
	return PVRSRV_OK;
}

PVRSRV_ERROR
OSEventObjectClose(IMG_HANDLE hOSEventKM)
{
	A01_EVENT_HANDLE *h = hOSEventKM;
	if (h) {
		a01_event_put(h->obj);
		OSFreeMem(h);
	}
	return PVRSRV_OK;
}

PVRSRV_ERROR
OSEventObjectSignal(IMG_HANDLE hEventObject)
{
	A01_EVENT_OBJECT *o = hEventObject;
	lck_mtx_lock(o->mtx);
	o->gen++;
	lck_mtx_unlock(o->mtx);
	wakeup((void *)&o->gen);
	return PVRSRV_OK;
}

PVRSRV_ERROR
OSEventObjectWaitTimeout(IMG_HANDLE hOSEventKM, IMG_UINT64 uiTimeoutus)
{
	A01_EVENT_HANDLE *h = hOSEventKM;
	A01_EVENT_OBJECT *o = h->obj;
	PVRSRV_ERROR e = PVRSRV_OK;
	lck_mtx_lock(o->mtx);
	if (o->gen == h->seen) {
		struct a01_timespec ts = { (long)(uiTimeoutus / 1000000u), (long)(uiTimeoutus % 1000000u) * 1000 };
		int r = msleep((void *)&o->gen, o->mtx, 0, "pvr_event", &ts);
		if (r == A01_EWOULDBLOCK && o->gen == h->seen) {
			e = PVRSRV_ERROR_TIMEOUT;
		}
	}
	h->seen = o->gen;
	lck_mtx_unlock(o->mtx);
	return e;
}

/* env/linux/event.c: an untimed wait is a 100 ms wait that the caller loops on */
PVRSRV_ERROR OSEventObjectWait(IMG_HANDLE hOSEventKM) { return OSEventObjectWaitTimeout(hOSEventKM, 100000u); }
PVRSRV_ERROR OSEventObjectWaitAndHoldBridgeLock(IMG_HANDLE hOSEventKM) { return OSEventObjectWait(hOSEventKM); }

/* ---- threads ------------------------------------------------------------------------------ */
typedef struct {
	PFN_THREAD pfn;
	void *data;
	thread_t th;
	volatile IMG_BOOL done;
	char name[32];
} A01_THREAD;

static void
a01_thread_main(void *arg, int wr)
{
	(void)wr;
	A01_THREAD *t = arg;
	t->pfn(t->data);
	__atomic_store_n(&t->done, IMG_TRUE, __ATOMIC_SEQ_CST);
	wakeup((void *)&t->done);
}

PVRSRV_ERROR
OSThreadCreatePriority(IMG_HANDLE *phThread, IMG_CHAR *pszThreadName, PFN_THREAD pfnThread,
    PFN_THREAD_DEBUG_DUMP pfnDebugDumpCB, IMG_BOOL bIsSupportingThread, void *hData,
    OS_THREAD_LEVEL eThreadPriority)
{
	(void)pfnDebugDumpCB; (void)bIsSupportingThread; (void)eThreadPriority;
	A01_THREAD *t = OSAllocZMem(sizeof(*t));
	if (!t) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	t->pfn = pfnThread;
	t->data = hData;
	strlcpy(t->name, pszThreadName ? pszThreadName : "pvr", sizeof(t->name));
	if (kernel_thread_start(a01_thread_main, t, &t->th) != 0) {
		OSFreeMem(t);
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	*phThread = t;
	return PVRSRV_OK;
}

PVRSRV_ERROR
OSThreadCreate(IMG_HANDLE *phThread, IMG_CHAR *pszThreadName, PFN_THREAD pfnThread,
    PFN_THREAD_DEBUG_DUMP pfnDebugDumpCB, IMG_BOOL bIsSupportingThread, void *hData)
{
	return OSThreadCreatePriority(phThread, pszThreadName, pfnThread, pfnDebugDumpCB,
	    bIsSupportingThread, hData, OS_THREAD_NOSET_PRIORITY);
}

/* The DDK stops its threads by signalling them first; this waits for the function to return. */
PVRSRV_ERROR
OSThreadDestroy(IMG_HANDLE hThread)
{
	A01_THREAD *t = hThread;
	for (unsigned i = 0; i < 1000 && !__atomic_load_n(&t->done, __ATOMIC_SEQ_CST); i++) {
		IOSleep(10);
	}
	if (!t->done) {
		return PVRSRV_ERROR_RETRY;
	}
	thread_deallocate(t->th);
	OSFreeMem(t);
	return PVRSRV_OK;
}

void OSThreadDumpInfo(DUMPDEBUG_PRINTF_FUNC *pfnDumpDebugPrintf, void *pvDumpDebugFile)
{
	(void)pfnDumpDebugPrintf; (void)pvDumpDebugFile;
}

/* ---- MISR: a kernel thread that runs the handler each time it is scheduled ------------------ */
typedef struct {
	PFN_MISR pfn;
	void *data;
	IMG_HANDLE ev, evh, th;
	volatile IMG_BOOL stop;
} A01_MISR;

static void
a01_misr_thread(void *arg)
{
	A01_MISR *m = arg;
	while (!m->stop) {
		if (OSEventObjectWait(m->evh) == PVRSRV_OK && !m->stop) {
			m->pfn(m->data);
		}
	}
}

PVRSRV_ERROR
OSInstallMISR(IMG_HANDLE *hMISRData, PFN_MISR pfnMISR, void *hData, const IMG_CHAR *pszMisrName)
{
	A01_MISR *m = OSAllocZMem(sizeof(*m));
	if (!m) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	m->pfn = pfnMISR;
	m->data = hData;
	OSEventObjectCreate(pszMisrName, &m->ev);
	OSEventObjectOpen(m->ev, &m->evh);
	PVRSRV_ERROR e = OSThreadCreate(&m->th, (IMG_CHAR *)pszMisrName, a01_misr_thread, NULL, IMG_TRUE, m);
	if (e != PVRSRV_OK) {
		return e;
	}
	*hMISRData = m;
	return PVRSRV_OK;
}

PVRSRV_ERROR OSScheduleMISR(IMG_HANDLE hMISRData) { return OSEventObjectSignal(((A01_MISR *)hMISRData)->ev); }

PVRSRV_ERROR
OSUninstallMISR(IMG_HANDLE hMISRData)
{
	A01_MISR *m = hMISRData;
	m->stop = IMG_TRUE;
	OSEventObjectSignal(m->ev);
	OSThreadDestroy(m->th);
	OSEventObjectClose(m->evh);
	OSEventObjectDestroy(m->ev);
	OSFreeMem(m);
	return PVRSRV_OK;
}

/* ---- registers and physical mappings -------------------------------------------------------- */
IMG_UINT32
OSReadHWReg32(volatile void *pvLinRegBaseAddr, IMG_UINT32 ui32Offset)
{
	IMG_UINT32 v = *(volatile IMG_UINT32 *)((volatile IMG_BYTE *)pvLinRegBaseAddr + ui32Offset);
	__asm__ volatile ("dmb oshld" ::: "memory");
	return v;
}

IMG_UINT64
OSReadHWReg64(volatile void *pvLinRegBaseAddr, IMG_UINT32 ui32Offset)
{
	IMG_UINT64 v = *(volatile IMG_UINT64 *)((volatile IMG_BYTE *)pvLinRegBaseAddr + ui32Offset);
	__asm__ volatile ("dmb oshld" ::: "memory");
	return v;
}

void
OSWriteHWReg32(volatile void *pvLinRegBaseAddr, IMG_UINT32 ui32Offset, IMG_UINT32 ui32Value)
{
	__asm__ volatile ("dmb oshst" ::: "memory");
	*(volatile IMG_UINT32 *)((volatile IMG_BYTE *)pvLinRegBaseAddr + ui32Offset) = ui32Value;
}

void
OSWriteHWReg64(volatile void *pvLinRegBaseAddr, IMG_UINT32 ui32Offset, IMG_UINT64 ui64Value)
{
	__asm__ volatile ("dmb oshst" ::: "memory");
	*(volatile IMG_UINT64 *)((volatile IMG_BYTE *)pvLinRegBaseAddr + ui32Offset) = ui64Value;
}

void *
OSMapPhysToLin(IMG_CPU_PHYADDR BasePAddr, size_t ui32Bytes, IMG_UINT32 ui32Flags)
{
	vm_offset_t va;
	if ((ui32Flags & PVRSRV_MEMALLOCFLAG_CPU_CACHE_MODE_MASK) == PVRSRV_MEMALLOCFLAG_CPU_WRITE_COMBINE) {
		va = ml_io_map_wcomb((vm_offset_t)BasePAddr.uiAddr, ui32Bytes);
	} else {
		va = ml_io_map((vm_offset_t)BasePAddr.uiAddr, ui32Bytes);
	}
	return (void *)va;
}

IMG_BOOL
OSUnMapPhysToLin(void *pvLinAddr, size_t ui32Bytes, IMG_UINT32 ui32Flags)
{
	(void)ui32Flags;
	ml_io_unmap((vm_offset_t)pvLinAddr, ui32Bytes);
	return IMG_TRUE;
}

/* ---- CPU cache maintenance (virtual addresses, point of coherency) ----------------------------- */
PVRSRV_CACHE_OP_ADDR_TYPE OSCPUCacheOpAddressType(void) { return PVRSRV_CACHE_OP_ADDR_TYPE_VIRTUAL; }
IMG_UINT32 OSCPUCacheAttributeSize(IMG_DCACHE_ATTRIBUTE e) { (void)e; return 64; }

void
OSCPUCacheFlushRangeKM(PVRSRV_DEVICE_NODE *psDevNode, void *pvVirtStart, void *pvVirtEnd,
    IMG_CPU_PHYADDR sCPUPhysStart, IMG_CPU_PHYADDR sCPUPhysEnd)
{
	(void)psDevNode; (void)sCPUPhysStart; (void)sCPUPhysEnd;
	flush_dcache((vm_offset_t)pvVirtStart, (unsigned)((uintptr_t)pvVirtEnd - (uintptr_t)pvVirtStart), 0);
}

void
OSCPUCacheCleanRangeKM(PVRSRV_DEVICE_NODE *psDevNode, void *pvVirtStart, void *pvVirtEnd,
    IMG_CPU_PHYADDR sCPUPhysStart, IMG_CPU_PHYADDR sCPUPhysEnd)
{
	(void)psDevNode; (void)sCPUPhysStart; (void)sCPUPhysEnd;
	clean_dcache((vm_offset_t)pvVirtStart, (unsigned)((uintptr_t)pvVirtEnd - (uintptr_t)pvVirtStart), 0);
}

/* invalidate = clean + invalidate: never drops dirty CPU lines the GPU has not seen */
void
OSCPUCacheInvalidateRangeKM(PVRSRV_DEVICE_NODE *psDevNode, void *pvVirtStart, void *pvVirtEnd,
    IMG_CPU_PHYADDR sCPUPhysStart, IMG_CPU_PHYADDR sCPUPhysEnd)
{
	OSCPUCacheFlushRangeKM(psDevNode, pvVirtStart, pvVirtEnd, sCPUPhysStart, sCPUPhysEnd);
}

PVRSRV_ERROR
OSCPUOperation(PVRSRV_CACHE_OP eCacheOp)
{
	(void)eCacheOp;
	FlushPoC_Dcache();
	return PVRSRV_OK;
}

IMG_BOOL OSIsWriteCombineUnalignedSafe(void) { return IMG_FALSE; }   /* arm64 device memory */

/* ---- user copies -------------------------------------------------------------------------------- */
PVRSRV_ERROR
OSCopyToUser(void *pvProcess, void *pvDest, const void *pvSrc, size_t ui32Bytes)
{
	(void)pvProcess;
	return copyout(pvSrc, (user_addr_t)(uintptr_t)pvDest, ui32Bytes) ? PVRSRV_ERROR_FAILED_TO_COPY_VIRT_MEMORY : PVRSRV_OK;
}

PVRSRV_ERROR
OSCopyFromUser(void *pvProcess, void *pvDest, const void *pvSrc, size_t ui32Bytes)
{
	(void)pvProcess;
	return copyin((user_addr_t)(uintptr_t)pvSrc, pvDest, ui32Bytes) ? PVRSRV_ERROR_FAILED_TO_COPY_VIRT_MEMORY : PVRSRV_OK;
}

/* The XNU bridge (env/xnu/pvr_bridge_xnu.c) copies the whole request into kernel buffers before
 * dispatch, as env/linux/pvr_bridge_k.c does, so in-bridge copies are kernel memcpy. */
PVRSRV_ERROR
OSBridgeCopyFromUser(void *pvProcess, void *pvDest, const void *pvSrc, size_t ui32Bytes)
{
	return OSCopyFromUser(pvProcess, pvDest, pvSrc, ui32Bytes);
}

PVRSRV_ERROR
OSBridgeCopyToUser(void *pvProcess, void *pvDest, const void *pvSrc, size_t ui32Bytes)
{
	return OSCopyToUser(pvProcess, pvDest, pvSrc, ui32Bytes);
}

/* ---- process and system information --------------------------------------------------------- */
IMG_PID OSGetCurrentProcessID(void) { return (IMG_PID)proc_selfpid(); }
IMG_PID OSGetCurrentClientProcessIDKM(void) { return OSGetCurrentProcessID(); }
uintptr_t OSGetCurrentClientThreadIDKM(void) { return (uintptr_t)current_thread(); }

IMG_CHAR *
OSGetCurrentClientProcessNameKM(void)
{
	static char name[64];   /* statistics and logs only */
	proc_selfname(name, sizeof(name));
	return name;
}

IMG_UINT64 OSGetCurrentProcessVASpaceSize(void) { return 1ull << 39; }
size_t OSGetPageShift(void) { return (size_t)page_shift; }
size_t OSGetPageSize(void) { return (size_t)1 << page_shift; }

size_t
OSGetOrder(size_t uSize)
{
	size_t pages = (uSize + OSGetPageSize() - 1) >> OSGetPageShift(), order = 0;
	while (((size_t)1 << order) < pages) {
		order++;
	}
	return order;
}

IMG_UINT64 OSGetRAMSize(void) { return max_mem; }

/* ---- environment, statistics, debug ------------------------------------------------------------ */
PVRSRV_ERROR OSInitEnvData(void) { (void)a01_grp(); return PVRSRV_OK; }
void OSDeInitEnvData(void) {}
PVRSRV_ERROR OSPlatformBridgeInit(void) { return PVRSRV_OK; }
PVRSRV_ERROR OSPlatformBridgeDeInit(void) { return PVRSRV_OK; }

void *
OSCreateStatisticEntry(IMG_CHAR *pszName, void *pvFolder, OS_STATS_PRINT_FUNC *pfnStatsPrint, void *pvData)
{
	(void)pszName; (void)pvFolder; (void)pfnStatsPrint; (void)pvData;
	return (void *)1;   /* no debugfs: a non-NULL token the DDK only hands back to Remove */
}

void OSRemoveStatisticEntry(void **ppvEntry) { if (ppvEntry) { *ppvEntry = NULL; } }
PVRSRV_ERROR OSDebugSignalPID(IMG_UINT32 ui32PID) { (void)ui32PID; return PVRSRV_ERROR_NOT_SUPPORTED; }
void OSDumpStack(void) {}
void OSPanic(void) { panic("pvrsrvkm: DDK OSPanic"); }

void
OSDumpVersionInfo(DUMPDEBUG_PRINTF_FUNC *pfnDumpDebugPrintf, void *pvDumpDebugFile)
{
	if (pfnDumpDebugPrintf) {
		pfnDumpDebugPrintf(pvDumpDebugFile, "OS: XNU (Galaxy A01 Core)");
	}
}

void
PVRSRVDebugPrintf(IMG_UINT32 ui32DebugLevel, const IMG_CHAR *pszFileName, IMG_UINT32 ui32Line,
    const IMG_CHAR *pszFormat, ...)
{
	char buf[256];
	va_list ap;
	const char *base = pszFileName;
	for (const char *s = pszFileName; s && *s; s++) {
		if (*s == '/') {
			base = s + 1;
		}
	}
	va_start(ap, pszFormat);
	vsnprintf(buf, sizeof(buf), pszFormat, ap);
	va_end(ap);
	printf("PVR%s %s:%u: %s\n", (ui32DebugLevel & DBGPRIV_ERROR) ? " ERROR" : "",
	    base ? base : "?", ui32Line, buf);
}

void
PVRSRVReleasePrintf(const IMG_CHAR *pszFormat, ...)
{
	char buf[256];
	va_list ap;
	va_start(ap, pszFormat);
	vsnprintf(buf, sizeof(buf), pszFormat, ap);
	va_end(ap);
	printf("PVR: %s\n", buf);
}
