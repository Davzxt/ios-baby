/*
 * DDK 1.11 entry points for XNU (Galaxy A01 Core). The IOKit side (iokit/Kernel/A01CoreGPU.cpp)
 * calls these plain C functions; they follow env/linux/module_common.c (driver and device init,
 * open/release), pvr_bridge_k.c (bridge dispatch, PMR mmap) and osconnection_server.c.
 * MIT license (see gpu/ddk-1.11/NOTICE.md).
 */
#include "xnu_kpi.h"
#include "img_defs.h"
#include "img_types.h"
#include "pvrsrv_error.h"
#include "pvrsrv.h"
#include "srvkm.h"
#include "srvcore.h"
#include "connection_server.h"
#include "osconnection_server.h"
#include "handle.h"
#include "pmr.h"
#include "osfunc.h"
#include "allocmem.h"
#include "pvr_bridge.h"
#include "a01pvr.h"
#include "process_stats.h"

typedef struct {
	PVRSRV_DEVICE_NODE *psDevNode;
	IMG_PID owner;
} A01_ENV_CONNECTION;

static PVRSRV_DEVICE_NODE *gpsA01DevNode;
static POS_LOCK ghA01MMapLock;

/* ---- osconnection_server.h ------------------------------------------------------------------ */
PVRSRV_ERROR
OSConnectionPrivateDataInit(IMG_HANDLE *phOsPrivateData, void *pvOSData)
{
	A01_ENV_CONNECTION *src = pvOSData, *c = OSAllocZMem(sizeof(*c));
	if (!c) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	c->psDevNode = src->psDevNode;
	c->owner = OSGetCurrentClientProcessIDKM();
	*phOsPrivateData = c;
	return PVRSRV_OK;
}

PVRSRV_ERROR
OSConnectionPrivateDataDeInit(IMG_HANDLE hOsPrivateData)
{
	if (hOsPrivateData) {
		OSFreeMem(hOsPrivateData);
	}
	return PVRSRV_OK;
}

PVRSRV_DEVICE_NODE *
OSGetDevData(CONNECTION_DATA *psConnection)
{
	A01_ENV_CONNECTION *c = PVRSRVConnectionPrivateData(psConnection);
	return c ? c->psDevNode : NULL;
}

/* ---- driver / device ------------------------------------------------------------------------------ */
int
a01pvr_driver_init(void)
{
	PVRSRV_ERROR e = OSLockCreate(&ghA01MMapLock);
#if defined(PVRSRV_ENABLE_PROCESS_STATS)
	/* PVRSRVCommonDriverInit (env/linux/module_common.c) does this before PVRSRVDriverInit:
	 * every connection registers its process in these statistics. */
	if (e == PVRSRV_OK) {
		e = PVRSRVStatsInitialise();
	}
#endif
	if (e == PVRSRV_OK) {
		e = PVRSRVDriverInit();
	}
	if (e == PVRSRV_OK) {
		e = PVRSRVDeviceCreate(NULL, 0, &gpsA01DevNode);
	}
	printf("A01CORE PVR: DDK 1.11 driver init: %s\n", PVRSRVGetErrorString(e));
	return e == PVRSRV_OK ? 0 : (int)e;
}

/* first open initialises the device (firmware load and boot), as PVRSRVCommonDeviceOpen does */
int
a01pvr_open(void **ppvConnection)
{
	if (!gpsA01DevNode) {
		return PVRSRV_ERROR_INIT_FAILURE;
	}
	if (gpsA01DevNode->eDevState == PVRSRV_DEVICE_STATE_BAD) {
		return PVRSRV_ERROR_INIT_FAILURE;
	}
	if (gpsA01DevNode->eDevState == PVRSRV_DEVICE_STATE_INIT) {
		PVRSRV_ERROR e = PVRSRVDeviceInitialise(gpsA01DevNode);
		printf("A01CORE PVR: device initialise (firmware boot): %s\n", PVRSRVGetErrorString(e));
		if (e != PVRSRV_OK) {
			return (int)e;
		}
	}
	A01_ENV_CONNECTION priv = { gpsA01DevNode, 0 };
	return (int)PVRSRVConnectionConnect(ppvConnection, &priv);
}

void
a01pvr_close(void *pvConnection)
{
	if (pvConnection) {
		PVRSRVConnectionDisconnect(pvConnection);
	}
}

/* in/out are user addresses of the calling task, as in the Linux ioctl */
int
a01pvr_bridge(void *pvConnection, uint32_t group, uint32_t func, uint64_t in, uint32_t in_size,
    uint64_t out, uint32_t out_size)
{
	PVRSRV_BRIDGE_PACKAGE pkg = { 0 };
	pkg.ui32BridgeID = group;
	pkg.ui32FunctionID = func;
	pkg.ui32Size = sizeof(pkg);
	pkg.pvParamIn = (void *)(uintptr_t)in;
	pkg.ui32InBufferSize = in_size;
	pkg.pvParamOut = (void *)(uintptr_t)out;
	pkg.ui32OutBufferSize = out_size;
	return (int)BridgedDispatchKM(pvConnection, &pkg);
}

/* PVRSRV_MMap: the secure PMR handle, mapped whole into the calling task */
int
a01pvr_mmap(void *pvConnection, uint64_t pmr_handle, uint64_t *uaddr)
{
	CONNECTION_DATA *psConnection = pvConnection;
	IMG_HANDLE h = (IMG_HANDLE)(uintptr_t)pmr_handle;
	PMR *psPMR;
	struct { IMG_UINT64 uaddr; } req = { 0 };   /* physmem_xnu.c A01_PMR_MMAP */
	OSLockAcquire(ghA01MMapLock);
	PVRSRV_ERROR e = PVRSRVLookupHandle(psConnection->psHandleBase, (void **)&psPMR, h,
	    PVRSRV_HANDLE_TYPE_PHYSMEM_PMR, IMG_TRUE);
	if (e == PVRSRV_OK) {
		e = PMRMMapPMR(psPMR, &req);
		PVRSRVReleaseHandle(psConnection->psHandleBase, h, PVRSRV_HANDLE_TYPE_PHYSMEM_PMR);
	}
	OSLockRelease(ghA01MMapLock);
	*uaddr = req.uaddr;
	return (int)e;
}
