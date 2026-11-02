/*
 * DDK 1.11 platform layer for the Galaxy A01 Core (MT6739, PowerVR GE8100) under XNU.
 * Structure follows the DDK's reference platform services/system/rgx_nohw/sysconfig.c.
 * MIT license (see gpu/ddk-1.11/NOTICE.md).
 */
#include "xnu_kpi.h"
#include "img_defs.h"
#include "img_types.h"
#include "pvrsrv_error.h"
#include "pvrsrv_device.h"
#include "rgxdevice.h"
#include "syscommon.h"
#include "physheap.h"
#include "osfunc.h"
#include "allocmem.h"
#include "vz_support.h"
#include "rgx_fwif_km.h"
#include "os_srvinit_param.h"
#include "rgxfwload.h"

/* XNU side (bsd/dev/a01core_gpu.c): MFG power from 0311, rgx.fw from the payload blob */
extern int a01core_gpu_power_on(void);
extern const void *a01core_gpu_firmware(size_t *len);

#define A01_RGX_REGS_PA     0x13000000u   /* mfg_auckland@13000000 (mt6739.dts) */
#define A01_RGX_REGS_SIZE   0x10000u      /* SYS_BUS_SECURE is at 0xA100 */
#define A01_CORE_CLOCK_HZ   570000000u    /* GE8100 top OPP on MT6739 */
#define A01_APM_LATENCY_MS  100u

static void
UMACpuToDev(IMG_HANDLE h, IMG_UINT32 n, IMG_DEV_PHYADDR *dev, IMG_CPU_PHYADDR *cpu)
{
	(void)h;
	for (IMG_UINT32 i = 0; i < n; i++) {
		dev[i].uiAddr = cpu[i].uiAddr;
	}
}

static void
UMADevToCpu(IMG_HANDLE h, IMG_UINT32 n, IMG_CPU_PHYADDR *cpu, IMG_DEV_PHYADDR *dev)
{
	(void)h;
	for (IMG_UINT32 i = 0; i < n; i++) {
		cpu[i].uiAddr = dev[i].uiAddr;
	}
}

static PHYS_HEAP_FUNCTIONS gsA01PhysHeapFuncs = { UMACpuToDev, UMADevToCpu, NULL };

static IMG_UINT32 gauiA01BIFTilingXStrides[RGXFWIF_NUM_BIF_TILING_CONFIGS] = { 0, 1, 2, 3 };

/* The GPU stays powered once on: the DDK's power-off path is not wired to MFG yet. */
static PVRSRV_ERROR
A01PrePowerState(IMG_HANDLE hSysData, PVRSRV_DEV_POWER_STATE eNew, PVRSRV_DEV_POWER_STATE eCur, IMG_BOOL bForced)
{
	(void)hSysData; (void)eCur; (void)bForced;
	if (eNew == PVRSRV_DEV_POWER_STATE_ON) {
		return a01core_gpu_power_on() ? PVRSRV_ERROR_DEVICE_POWER_CHANGE_FAILURE : PVRSRV_OK;
	}
	return PVRSRV_OK;
}

static void
A01FeatureDepInit(PVRSRV_DEVICE_CONFIG *psDevConfig, IMG_UINT64 ui64Features)
{
	(void)ui64Features;
	psDevConfig->eCacheSnoopingMode = PVRSRV_DEVICE_SNOOP_NONE;
}

PVRSRV_ERROR
SysDevInit(void *pvOSDevice, PVRSRV_DEVICE_CONFIG **ppsDevConfig)
{
	PVRSRV_DEVICE_CONFIG *c = OSAllocZMem(sizeof(*c) + sizeof(RGX_DATA) + sizeof(RGX_TIMING_INFORMATION));
	if (!c) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	RGX_DATA *d = (RGX_DATA *)(c + 1);
	RGX_TIMING_INFORMATION *t = (RGX_TIMING_INFORMATION *)(d + 1);
	PHYS_HEAP_CONFIG *h = OSAllocZMem(sizeof(*h) * 2);
	if (!h) {
		OSFreeMem(c);
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	h[0].ui32PhysHeapID = 0;
	h[0].pszPDumpMemspaceName = "SYSMEM";
	h[0].eType = PHYS_HEAP_TYPE_UMA;
	h[0].psMemFuncs = &gsA01PhysHeapFuncs;
	h[1].ui32PhysHeapID = 1;
	h[1].pszPDumpMemspaceName = "SYSMEM_FW";
	h[1].eType = PHYS_HEAP_TYPE_UMA;
	h[1].psMemFuncs = &gsA01PhysHeapFuncs;

	t->ui32CoreClockSpeed = A01_CORE_CLOCK_HZ;
	t->bEnableActivePM = IMG_FALSE;
	t->bEnableRDPowIsland = IMG_FALSE;
	t->ui32ActivePMLatencyms = A01_APM_LATENCY_MS;
	d->psRGXTimingInfo = t;

	c->pvOSDevice = pvOSDevice;
	c->pszName = "a01core_ge8100";
	c->pfnSysDevFeatureDepInit = A01FeatureDepInit;
	c->sRegsCpuPBase.uiAddr = A01_RGX_REGS_PA;
	c->ui32RegsSize = A01_RGX_REGS_SIZE;
	c->ui32IRQ = 0;   /* polled, see SysInstallDeviceLISR */
	c->pasPhysHeaps = h;
	c->ui32PhysHeapCount = 2;
	c->aui32PhysHeapID[PVRSRV_DEVICE_PHYS_HEAP_GPU_LOCAL] = 0;
	c->aui32PhysHeapID[PVRSRV_DEVICE_PHYS_HEAP_CPU_LOCAL] = 0;
	c->aui32PhysHeapID[PVRSRV_DEVICE_PHYS_HEAP_EXTERNAL] = 0;
	c->aui32PhysHeapID[PVRSRV_DEVICE_PHYS_HEAP_FW_LOCAL] = 1;
	c->eBIFTilingMode = RGXFWIF_BIFTILINGMODE_256x16;
	c->pui32BIFTilingHeapConfigs = gauiA01BIFTilingXStrides;
	c->ui32BIFTilingHeapCount = RGXFWIF_NUM_BIF_TILING_CONFIGS;
	c->pfnPrePowerState = A01PrePowerState;
	c->pfnPostPowerState = NULL;
	c->bHasFBCDCVersion31 = IMG_FALSE;
	c->pfnClockFreqGet = NULL;
	c->hDevData = d;
	*ppsDevConfig = c;
	return PVRSRV_OK;
}

void
SysDevDeInit(PVRSRV_DEVICE_CONFIG *psDevConfig)
{
	OSFreeMem(psDevConfig->pasPhysHeaps);
	OSFreeMem(psDevConfig);
}

/* ---- interrupts: polled until the MT6739 interrupt controller is wired in XNU ----------------- */
typedef struct {
	PFN_LISR pfn;
	void *data;
	IMG_HANDLE th;
	volatile IMG_BOOL stop;
} A01_LISR;

static void
a01_lisr_poll(void *arg)
{
	A01_LISR *l = arg;
	while (!l->stop) {
		(void)l->pfn(l->data);   /* RGX_LISRHandler reads the IRQ status itself */
		/* Sleep, not OSWaitus: XNU's delay() spins for short intervals, and with cpus=1 this
		 * kernel-priority thread then held the only CPU and starved userland (the GPU test sat
		 * in vkCreateDevice for minutes, sampled at a different place each time). */
		OSSleepms(1);
	}
}

PVRSRV_ERROR
SysInstallDeviceLISR(IMG_HANDLE hSysData, IMG_UINT32 ui32IRQ, const IMG_CHAR *pszName, PFN_LISR pfnLISR,
    void *pvData, IMG_HANDLE *phLISRData)
{
	(void)hSysData; (void)ui32IRQ;
	A01_LISR *l = OSAllocZMem(sizeof(*l));
	if (!l) {
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}
	l->pfn = pfnLISR;
	l->data = pvData;
	PVRSRV_ERROR e = OSThreadCreate(&l->th, (IMG_CHAR *)pszName, a01_lisr_poll, NULL, IMG_TRUE, l);
	if (e != PVRSRV_OK) {
		OSFreeMem(l);
		return e;
	}
	*phLISRData = l;
	return PVRSRV_OK;
}

PVRSRV_ERROR
SysUninstallDeviceLISR(IMG_HANDLE hLISRData)
{
	A01_LISR *l = hLISRData;
	l->stop = IMG_TRUE;
	OSThreadDestroy(l->th);
	OSFreeMem(l);
	return PVRSRV_OK;
}

PVRSRV_ERROR
SysDebugInfo(PVRSRV_DEVICE_CONFIG *psDevConfig, DUMPDEBUG_PRINTF_FUNC *pfnDumpDebugPrintf, void *pvDumpDebugFile)
{
	(void)psDevConfig;
	if (pfnDumpDebugPrintf) {
		pfnDumpDebugPrintf(pvDumpDebugFile, "A01 Core GE8100: regs %#x, polled LISR", A01_RGX_REGS_PA);
	}
	return PVRSRV_OK;
}

/* ---- virtualisation hooks: native driver, every heap is the host's --------------------------- */
PVRSRV_ERROR SysVzDevInit(PVRSRV_DEVICE_CONFIG *psDevConfig) { (void)psDevConfig; return PVRSRV_OK; }
PVRSRV_ERROR SysVzDevDeInit(PVRSRV_DEVICE_CONFIG *psDevConfig) { (void)psDevConfig; return PVRSRV_OK; }
PVRSRV_ERROR SysVzRegisterFwPhysHeap(PVRSRV_DEVICE_CONFIG *psDevConfig) { (void)psDevConfig; return PVRSRV_OK; }
PVRSRV_ERROR SysVzUnregisterFwPhysHeap(PVRSRV_DEVICE_CONFIG *psDevConfig) { (void)psDevConfig; return PVRSRV_OK; }

PVRSRV_ERROR
SysVzGetPhysHeapOrigin(PVRSRV_DEVICE_CONFIG *psDevConfig, PVRSRV_DEVICE_PHYS_HEAP eHeap,
    PVRSRV_DEVICE_PHYS_HEAP_ORIGIN *peOrigin)
{
	(void)psDevConfig; (void)eHeap;
	*peOrigin = PVRSRV_DEVICE_PHYS_HEAP_ORIGIN_HOST;
	return PVRSRV_OK;
}

/* ---- firmware image: vendor/firmware/rgx.fw (1.11@5425693) from the boot payload -------------- */
struct RGXFW {
	const void *data;
	size_t len;
};

struct RGXFW *
RGXLoadFirmware(PVRSRV_DEVICE_NODE *psDeviceNode, const IMG_CHAR *pszBVNCString)
{
	(void)psDeviceNode; (void)pszBVNCString;
	struct RGXFW *f = OSAllocZMem(sizeof(*f));
	if (f) {
		f->data = a01core_gpu_firmware(&f->len);
		if (!f->data) {
			OSFreeMem(f);
		}
	}
	return f;
}

void RGXUnloadFirmware(struct RGXFW *psRGXFW) { OSFreeMem(psRGXFW); }   /* the blob stays in the payload */
const void *RGXFirmwareData(struct RGXFW *psRGXFW) { return psRGXFW->data; }
size_t RGXFirmwareSize(struct RGXFW *psRGXFW) { return psRGXFW->len; }

/* ---- server init parameters (app hints): every parameter takes its built-in default --------- */
void *SrvInitParamOpen(void) { return NULL; }
void SrvInitParamClose(void *pvState) { (void)pvState; }

void
_SrvInitParamGetBOOL(void *pvState, const IMG_CHAR *pszName, const IMG_BOOL *pbDefault, IMG_BOOL *pbValue)
{
	(void)pvState; (void)pszName;
	*pbValue = *pbDefault;
}

void
_SrvInitParamGetUINT32(void *pvState, const IMG_CHAR *pszName, const IMG_UINT32 *pui32Default, IMG_UINT32 *pui32Value)
{
	(void)pvState; (void)pszName;
	*pui32Value = *pui32Default;
}

void
_SrvInitParamGetUINT32BitField(void *pvState, const IMG_CHAR *pszBaseName, IMG_UINT32 uiDefault,
    const SRV_INIT_PARAM_UINT32_LOOKUP *psLookup, IMG_UINT32 uiSize, IMG_UINT32 *puiValue)
{
	(void)pvState; (void)psLookup; (void)uiSize;
	*puiValue = uiDefault;
	/* Firmware trace on, so the DDK's debug dump shows what the firmware did with each command
	 * (the phone's dumps showed an all-zero trace and 3D work left "Ready"): MAIN, MTS, CSW, BIF,
	 * POW and HWR groups. */
	if (OSStringNCompare(pszBaseName, "EnableLogGroup", 15) == 0) {
		*puiValue = 0x2U | 0x4U | 0x10U | 0x20U | 0x200U | 0x400U;
	}
}

void
_SrvInitParamGetUINT32List(void *pvState, const IMG_CHAR *pszName, IMG_UINT32 uiDefault,
    const SRV_INIT_PARAM_UINT32_LOOKUP *psLookup, IMG_UINT32 uiSize, IMG_UINT32 *puiValue)
{
	(void)pvState; (void)psLookup; (void)uiSize;
	*puiValue = uiDefault;
	if (OSStringNCompare(pszName, "FirmwareLogType", 16) == 0) {
		*puiValue = 2;   /* TRACE */
	}
}

void
_SrvInitParamGetSTRING(void *pvState, const IMG_CHAR *pszName, const IMG_CHAR **psDefault, IMG_CHAR *pBuffer, size_t size)
{
	(void)pvState; (void)pszName;
	OSStringLCopy(pBuffer, *psDefault ? *psDefault : "", size);
}
