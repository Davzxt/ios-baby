/*
 * DDK handle backend for XNU: replaces env/linux/handle_idr.c (Linux IDR) with a growable
 * array. Handles are index + 1, so NULL is never a valid handle. handle.c serialises calls.
 * MIT license (see gpu/ddk-1.11/NOTICE.md).
 */
#include "img_defs.h"
#include "img_types.h"
#include "pvrsrv_error.h"
#include "handle_impl.h"
#include "allocmem.h"
#include "osfunc.h"

struct _HANDLE_IMPL_BASE_ {
	void **slots;
	IMG_UINT32 count;     /* slots allocated */
	IMG_UINT32 used;
	IMG_BOOL purging;
};

#define A01_EMPTY ((void *)0)
#define A01_RESERVED ((void *)1)   /* acquired with NULL data */

static PVRSRV_ERROR
AcquireHandle(HANDLE_IMPL_BASE *b, IMG_HANDLE *ph, void *pvData)
{
	IMG_UINT32 i;
	for (i = 0; i < b->count && b->slots[i] != A01_EMPTY; i++) {
	}
	if (i == b->count) {
		IMG_UINT32 n = b->count ? b->count * 2 : 64;
		void **s = OSAllocZMem(n * sizeof(void *));
		if (!s) {
			return PVRSRV_ERROR_OUT_OF_MEMORY;
		}
		if (b->slots) {
			OSCachedMemCopy(s, b->slots, b->count * sizeof(void *));
			OSFreeMem(b->slots);
		}
		b->slots = s;
		b->count = n;
	}
	b->slots[i] = pvData ? pvData : A01_RESERVED;
	b->used++;
	*ph = (IMG_HANDLE)(uintptr_t)(i + 1);
	return PVRSRV_OK;
}

static IMG_BOOL
Valid(HANDLE_IMPL_BASE *b, IMG_HANDLE h, IMG_UINT32 *pi)
{
	uintptr_t v = (uintptr_t)h;
	if (v == 0 || v > b->count || b->slots[v - 1] == A01_EMPTY) {
		return IMG_FALSE;
	}
	*pi = (IMG_UINT32)(v - 1);
	return IMG_TRUE;
}

static PVRSRV_ERROR
ReleaseHandle(HANDLE_IMPL_BASE *b, IMG_HANDLE h, void **ppvData)
{
	IMG_UINT32 i;
	if (!Valid(b, h, &i)) {
		return PVRSRV_ERROR_HANDLE_INDEX_OUT_OF_RANGE;
	}
	if (ppvData) {
		*ppvData = b->slots[i] == A01_RESERVED ? NULL : b->slots[i];
	}
	b->slots[i] = A01_EMPTY;
	b->used--;
	return PVRSRV_OK;
}

static PVRSRV_ERROR
GetHandleData(HANDLE_IMPL_BASE *b, IMG_HANDLE h, void **ppvData)
{
	IMG_UINT32 i;
	if (!Valid(b, h, &i)) {
		return PVRSRV_ERROR_HANDLE_INDEX_OUT_OF_RANGE;
	}
	*ppvData = b->slots[i] == A01_RESERVED ? NULL : b->slots[i];
	return PVRSRV_OK;
}

static PVRSRV_ERROR
SetHandleData(HANDLE_IMPL_BASE *b, IMG_HANDLE h, void *pvData)
{
	IMG_UINT32 i;
	if (!Valid(b, h, &i)) {
		return PVRSRV_ERROR_HANDLE_INDEX_OUT_OF_RANGE;
	}
	b->slots[i] = pvData ? pvData : A01_RESERVED;
	return PVRSRV_OK;
}

static PVRSRV_ERROR
IterateOverHandles(HANDLE_IMPL_BASE *b, PFN_HANDLE_ITER pfn, void *pvIterData)
{
	for (IMG_UINT32 i = 0; i < b->count; i++) {
		if (b->slots[i] != A01_EMPTY) {
			PVRSRV_ERROR e = pfn((IMG_HANDLE)(uintptr_t)(i + 1), pvIterData);
			if (e != PVRSRV_OK) {
				return e;
			}
		}
	}
	return PVRSRV_OK;
}

static PVRSRV_ERROR EnableHandlePurging(HANDLE_IMPL_BASE *b) { b->purging = IMG_TRUE; return PVRSRV_OK; }
static PVRSRV_ERROR PurgeHandles(HANDLE_IMPL_BASE *b) { (void)b; return PVRSRV_OK; }

static PVRSRV_ERROR
CreateHandleBase(HANDLE_IMPL_BASE **ppb)
{
	HANDLE_IMPL_BASE *b = OSAllocZMem(sizeof(*b));
	if (!b) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	*ppb = b;
	return PVRSRV_OK;
}

static PVRSRV_ERROR
DestroyHandleBase(HANDLE_IMPL_BASE *b)
{
	if (b->slots) {
		OSFreeMem(b->slots);
	}
	OSFreeMem(b);
	return PVRSRV_OK;
}

static const HANDLE_IMPL_FUNCTAB g_sHandleFuncTab = {
	.pfnAcquireHandle = AcquireHandle,
	.pfnReleaseHandle = ReleaseHandle,
	.pfnGetHandleData = GetHandleData,
	.pfnSetHandleData = SetHandleData,
	.pfnIterateOverHandles = IterateOverHandles,
	.pfnEnableHandlePurging = EnableHandlePurging,
	.pfnPurgeHandles = PurgeHandles,
	.pfnCreateHandleBase = CreateHandleBase,
	.pfnDestroyHandleBase = DestroyHandleBase,
};

PVRSRV_ERROR
PVRSRVHandleGetFuncTable(HANDLE_IMPL_FUNCTAB const **ppsFuncs)
{
	*ppsFuncs = &g_sHandleFuncTab;
	return PVRSRV_OK;
}
