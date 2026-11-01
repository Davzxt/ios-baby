/*
 * libdrm for the PowerVR Vulkan driver on the Galaxy A01 Core (iOS).
 *
 * img-pvr's "srv" winsys reaches the DDK 1.11 kernel driver through a DRM render node and
 * drmIoctl. On iOS that path becomes the XNU GE8100 user client (gpu/ddk-1.11/env/xnu). Until
 * that bridge exists every call fails with ENODEV, so the driver reports no device instead of
 * pretending one is there.
 */
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct _drmVersion drmVersion, *drmVersionPtr;
typedef struct _drmDevice drmDevice, *drmDevicePtr;

#define A01_NODEV (errno = ENODEV, -ENODEV)

int drmIoctl(int fd, unsigned long request, void *arg) { (void)fd; (void)request; (void)arg; return A01_NODEV; }
drmVersionPtr drmGetVersion(int fd) { (void)fd; errno = ENODEV; return NULL; }
void drmFreeVersion(drmVersionPtr v) { (void)v; }
int drmGetCap(int fd, uint64_t capability, uint64_t *value) { (void)fd; (void)capability; (void)value; return A01_NODEV; }
int drmIsKMS(int fd) { (void)fd; return 0; }
int drmDropMaster(int fd) { (void)fd; return A01_NODEV; }
int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device) { (void)fd; (void)flags; *device = NULL; return A01_NODEV; }
int drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max_devices) { (void)flags; (void)devices; (void)max_devices; return 0; }
void drmFreeDevice(drmDevicePtr *device) { if (device) *device = NULL; }
void drmFreeDevices(drmDevicePtr devices[], int count) { (void)devices; (void)count; }
int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle) { (void)fd; (void)prime_fd; (void)handle; return A01_NODEV; }
int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd) { (void)fd; (void)handle; (void)flags; (void)prime_fd; return A01_NODEV; }
int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle) { (void)fd; (void)flags; (void)handle; return A01_NODEV; }
int drmSyncobjDestroy(int fd, uint32_t handle) { (void)fd; (void)handle; return A01_NODEV; }
int drmSyncobjTransfer(int fd, uint32_t dst, uint64_t dst_point, uint32_t src, uint64_t src_point, uint32_t flags)
{
	(void)fd; (void)dst; (void)dst_point; (void)src; (void)src_point; (void)flags;
	return A01_NODEV;
}

/* VK_EXT_acquire_drm_display has no meaning without DRM/KMS on iOS. */
int32_t pvr_AcquireDrmDisplayEXT(void *physicalDevice, int32_t drmFd, void *display)
{
	(void)physicalDevice; (void)drmFd; (void)display;
	return -3;   /* VK_ERROR_INITIALIZATION_FAILED */
}
