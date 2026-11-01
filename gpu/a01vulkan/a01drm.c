/*
 * libdrm for the PowerVR Vulkan driver on the Galaxy A01 Core (iOS).
 *
 * img-pvr's "srv" winsys talks to the DDK 1.11 kernel driver through a DRM render node: it
 * opens the node, checks drmGetVersion() == "pvr" 1.11, sends services bridge calls with
 * drmIoctl(DRM_IOCTL_SRVKM_CMD) and maps PMRs with mmap(node, offset = handle). On iOS the
 * kernel driver is the IOKit service A01CoreGPU (XNU patch 0320):
 *   selector 0 = bridge call {group, function, in, in size, out, out size} -> dispatch error
 *   selector 1 = map PMR {secure handle} -> {error, user address}
 * The render node is /dev/null (it exists and opens); every descriptor shares one connection.
 * Without the A01CoreGPU service (boot-arg a01gpu=2) every call fails with ENODEV.
 */
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <pthread.h>
#include <IOKit/IOKitLib.h>
#include "xf86drm.h"

#define A01_NODE "/dev/null"
/* pvr_srv_bridge.h: DRM_IOWR(DRM_COMMAND_BASE + DRM_SRVKM_CMD, struct drm_srvkm_cmd) */
struct a01_srvkm_cmd {
	uint32_t bridge_id;
	uint32_t bridge_func_id;
	uint64_t in_data_ptr;
	uint64_t out_data_ptr;
	uint32_t in_data_size;
	uint32_t out_data_size;
};
#define A01_IOCTL_SRVKM_CMD DRM_IOWR(DRM_COMMAND_BASE + 0, struct a01_srvkm_cmd)

static pthread_mutex_t a01_lock = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t a01_conn = IO_OBJECT_NULL;
static int a01_state;   /* 0 unknown, 1 connected, -1 no service */

static io_connect_t
a01_connection(void)
{
	pthread_mutex_lock(&a01_lock);
	if (a01_state == 0) {
		io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("A01CoreGPU"));
		if (svc != IO_OBJECT_NULL && IOServiceOpen(svc, mach_task_self(), 0, &a01_conn) == KERN_SUCCESS) {
			a01_state = 1;
		} else {
			a01_state = -1;
		}
		if (svc != IO_OBJECT_NULL) {
			IOObjectRelease(svc);
		}
	}
	pthread_mutex_unlock(&a01_lock);
	return a01_state == 1 ? a01_conn : IO_OBJECT_NULL;
}

#define A01_NODEV (errno = ENODEV, -ENODEV)

int
drmIoctl(int fd, unsigned long request, void *arg)
{
	(void)fd;
	io_connect_t c = a01_connection();
	if (c == IO_OBJECT_NULL) {
		return A01_NODEV;
	}
	if (request != A01_IOCTL_SRVKM_CMD) {
		errno = ENOTTY;
		return -1;
	}
	const struct a01_srvkm_cmd *cmd = arg;
	uint64_t in[6] = { cmd->bridge_id, cmd->bridge_func_id, cmd->in_data_ptr, cmd->in_data_size,
		           cmd->out_data_ptr, cmd->out_data_size };
	uint64_t out[1] = { 0 };
	uint32_t n = 1;
	kern_return_t kr = IOConnectCallScalarMethod(c, 0, in, 6, out, &n);
	if (kr != KERN_SUCCESS || out[0] != 0) {   /* dispatch failure; per-call errors are in the out buffer */
		errno = EINVAL;
		return -1;
	}
	return 0;
}

/* Replaces mmap(render_fd, offset = pmr << page_shift) in pvr_srv_bo.c (patch-pvr-darwin.py). */
int
a01drm_map_pmr(int fd, uint64_t pmr_handle, void **map)
{
	(void)fd;
	io_connect_t c = a01_connection();
	if (c == IO_OBJECT_NULL) {
		return A01_NODEV;
	}
	uint64_t in[1] = { pmr_handle }, out[2] = { 0, 0 };
	uint32_t n = 2;
	if (IOConnectCallScalarMethod(c, 1, in, 1, out, &n) != KERN_SUCCESS || out[0] != 0) {
		errno = ENOMEM;
		return -1;
	}
	*map = (void *)(uintptr_t)out[1];
	return 0;
}

drmVersionPtr
drmGetVersion(int fd)
{
	(void)fd;
	if (a01_connection() == IO_OBJECT_NULL) {
		errno = ENODEV;
		return NULL;
	}
	drmVersionPtr v = calloc(1, sizeof(*v));
	if (v) {
		v->version_major = 1;    /* PVR_SRV_VERSION_MAJ.MIN: services DDK 1.11 */
		v->version_minor = 11;
		v->name = strdup("pvr"); /* PVR_SRV_DRIVER_NAME */
		v->name_len = 3;
		v->desc = strdup("PowerVR GE8100 (A01CoreGPU)");
		v->desc_len = (int)strlen(v->desc);
		v->date = strdup("20261101");
		v->date_len = 8;
	}
	return v;
}

void
drmFreeVersion(drmVersionPtr v)
{
	if (v) {
		free(v->name);
		free(v->desc);
		free(v->date);
		free(v);
	}
}

static char a01_node[] = A01_NODE;
static char *a01_nodes[DRM_NODE_MAX] = { 0 };
static drmDevice a01_dev;
static drmPlatformBusInfo a01_bus = { "a01core-ge8100" };

int
drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max_devices)
{
	(void)flags;
	if (a01_connection() == IO_OBJECT_NULL) {
		return 0;
	}
	if (devices && max_devices >= 1) {
		a01_nodes[DRM_NODE_PRIMARY] = a01_node;
		a01_nodes[DRM_NODE_RENDER] = a01_node;
		memset(&a01_dev, 0, sizeof(a01_dev));
		a01_dev.nodes = a01_nodes;
		a01_dev.available_nodes = 1 << DRM_NODE_RENDER;
		a01_dev.bustype = DRM_BUS_PLATFORM;
		a01_dev.businfo.platform = &a01_bus;
		devices[0] = &a01_dev;
	}
	return 1;
}

int
drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device)
{
	(void)fd;
	drmDevicePtr d[1];
	if (drmGetDevices2(flags, d, 1) != 1) {
		*device = NULL;
		return A01_NODEV;
	}
	*device = d[0];
	return 0;
}

void drmFreeDevice(drmDevicePtr *device) { if (device) *device = NULL; }   /* static storage */
void drmFreeDevices(drmDevicePtr devices[], int count) { (void)devices; (void)count; }

int drmGetCap(int fd, uint64_t capability, uint64_t *value) { (void)fd; (void)capability; *value = 0; return 0; }
int drmIsKMS(int fd) { (void)fd; return 0; }
int drmDropMaster(int fd) { (void)fd; return 0; }

/* DMA-BUF and syncobj are Linux objects; the DDK side reports them unsupported too. */
int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle) { (void)fd; (void)prime_fd; (void)handle; errno = ENOSYS; return -1; }
int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd) { (void)fd; (void)handle; (void)flags; (void)prime_fd; errno = ENOSYS; return -1; }
int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle) { (void)fd; (void)flags; (void)handle; errno = ENOSYS; return -1; }
int drmSyncobjDestroy(int fd, uint32_t handle) { (void)fd; (void)handle; errno = ENOSYS; return -1; }
int drmSyncobjTransfer(int fd, uint32_t dst, uint64_t dst_point, uint32_t src, uint64_t src_point, uint32_t flags)
{
	(void)fd; (void)dst; (void)dst_point; (void)src; (void)src_point; (void)flags;
	errno = ENOSYS;
	return -1;
}

/* VK_EXT_acquire_drm_display has no meaning without DRM/KMS on iOS. */
int32_t pvr_AcquireDrmDisplayEXT(void *physicalDevice, int32_t drmFd, void *display)
{
	(void)physicalDevice; (void)drmFd; (void)display;
	return -3;   /* VK_ERROR_INITIALIZATION_FAILED */
}
