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

/*
 * The firmware's own sizes and offsets of the client command structures, as it writes them after
 * the KM list in the alignment-check buffer (rgx_fwif_alignchecks.h, RGXFW_ALIGN_CHECKS_INIT order):
 * TRACEBUF (7), CMDTA size/sTARegs, CMD3D size/s3DRegs, CMDTRANSFER size/sTransRegs,
 * CMD_COMPUTE size/sCDMRegs, FREELIST (5), RENDER_TARGET (2), HWRTDATA (7), ... Mesa's DDK 1.11
 * commands (img-pvr fw-api) were reverse-engineered on a GE8320; on the phone the firmware
 * discarded our 3D command with HWRTData 0, so these numbers show whether the layouts agree.
 * boot-arg a01pvralign=1 holds the screen 8 s on them.
 */
#include "rgxdevice.h"
#include "devicemem.h"
#include "rgx_fwif_alignchecks.h"

static void
a01pvr_print_fw_align(PVRSRV_DEVICE_NODE *psDevNode)
{
	static const IMG_UINT32 aui32KM[] = { RGXFW_ALIGN_CHECKS_INIT_KM };
	PVRSRV_RGXDEV_INFO *psDevInfo = psDevNode->pvDevice;
	IMG_UINT32 *p = NULL;
	int hold = 0;

	if (psDevInfo == NULL || psDevInfo->psRGXFWAlignChecksMemDesc == NULL ||
	    DevmemAcquireCpuVirtAddr(psDevInfo->psRGXFWAlignChecksMemDesc, (void **)&p) != PVRSRV_OK) {
		printf("A01CORE PVR: FW align checks: not available\n");
		return;
	}
	IMG_UINT32 *um = p + ARRAY_SIZE(aui32KM) + 1;
	IMG_UINT32 n = *um++;
	printf("A01CORE PVR: FW align (UM n=%u): TRACEBUF %u | CMDTA %u regs@%u | CMD3D %u regs@%u | "
	       "CMDTRANSFER %u regs@%u | CMD_COMPUTE %u regs@%u\n", n,
	       n > 0 ? um[0] : 0, n > 8 ? um[7] : 0, n > 8 ? um[8] : 0, n > 10 ? um[9] : 0, n > 10 ? um[10] : 0,
	       n > 12 ? um[11] : 0, n > 12 ? um[12] : 0, n > 14 ? um[13] : 0, n > 14 ? um[14] : 0);
	if (n > 22) {
		printf("A01CORE PVR: FW align: FREELIST %u | RENDER_TARGET %u | HWRTDATA %u (MList@%u FL@%u VCE@%u "
		       "RT@%u state@%u nPR@%u)\n", um[15], um[20], um[22], n > 23 ? um[23] : 0, n > 24 ? um[24] : 0,
		       n > 25 ? um[25] : 0, n > 26 ? um[26] : 0, n > 27 ? um[27] : 0, n > 28 ? um[28] : 0);
	}
	DevmemReleaseCpuVirtAddr(psDevInfo->psRGXFWAlignChecksMemDesc);
	if (PE_parse_boot_argn("a01pvralign", &hold, sizeof(hold)) && hold) {
		printf("A01CORE PVR: holding 8 s (a01pvralign)\n");
		IOSleep(8000);
	}
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
		a01pvr_print_fw_align(gpsA01DevNode);
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
