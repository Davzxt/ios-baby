/*
 * Galaxy A01 Core: a minimal Vulkan "loader" for Zink. Zink opens libvulkan and asks it for
 * vkGetInstanceProcAddr; iOS has no Khronos loader, so this library answers with the GE8100 ICD
 * (Mesa's PowerVR driver, /private/var/a01/lib/libvulkan_powervr.dylib), which exports
 * vk_icdGetInstanceProcAddr. A01Metal uses the same ICD directly.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define A01_VK_ICD "/private/var/a01/lib/libvulkan_powervr.dylib"

typedef void (*a01_vk_void_fn)(void);
typedef a01_vk_void_fn (*a01_gipa_fn)(void *instance, const char *name);

static a01_gipa_fn icd_gipa;

__attribute__((visibility("default"))) a01_vk_void_fn vkGetInstanceProcAddr(void *instance, const char *name);

static a01_gipa_fn
icd(void)
{
	if (icd_gipa == NULL) {
		void *h = dlopen(A01_VK_ICD, RTLD_NOW | RTLD_LOCAL);
		if (h == NULL) {
			fprintf(stderr, "a01vkloader: %s: %s\n", A01_VK_ICD, dlerror());
			return NULL;
		}
		icd_gipa = (a01_gipa_fn)dlsym(h, "vk_icdGetInstanceProcAddr");
		if (icd_gipa == NULL) {
			icd_gipa = (a01_gipa_fn)dlsym(h, "vkGetInstanceProcAddr");
		}
	}
	return icd_gipa;
}

/*
 * Zink also resolves vkGetDeviceProcAddr from the loader library itself ("ZINK: failed to get proc
 * address" on the phone when it was missing). The ICD hands it out per instance, so remember the
 * last instance Zink asked about and fetch the ICD's function from it on first use.
 */
__attribute__((visibility("default"))) a01_vk_void_fn vkGetDeviceProcAddr(void *device, const char *name);

typedef a01_vk_void_fn (*a01_gdpa_fn)(void *device, const char *name);
static void *last_instance;
static a01_gdpa_fn icd_gdpa;

a01_vk_void_fn
vkGetInstanceProcAddr(void *instance, const char *name)
{
	if (name != NULL && strcmp(name, "vkGetInstanceProcAddr") == 0) {
		return (a01_vk_void_fn)vkGetInstanceProcAddr;
	}
	if (name != NULL && strcmp(name, "vkGetDeviceProcAddr") == 0) {
		if (instance != NULL) {
			last_instance = instance;
		}
		return (a01_vk_void_fn)vkGetDeviceProcAddr;
	}
	if (instance != NULL) {
		last_instance = instance;
	}
	a01_gipa_fn g = icd();
	return g ? g(instance, name) : NULL;
}

a01_vk_void_fn
vkGetDeviceProcAddr(void *device, const char *name)
{
	if (name != NULL && strcmp(name, "vkGetDeviceProcAddr") == 0) {
		return (a01_vk_void_fn)vkGetDeviceProcAddr;
	}
	if (icd_gdpa == NULL) {
		a01_gipa_fn g = icd();
		if (g != NULL) {
			icd_gdpa = (a01_gdpa_fn)g(last_instance, "vkGetDeviceProcAddr");
			if (icd_gdpa == NULL && last_instance != NULL) {
				icd_gdpa = (a01_gdpa_fn)g(NULL, "vkGetDeviceProcAddr");
			}
		}
		if (icd_gdpa == NULL) {
			fprintf(stderr, "a01vkloader: no vkGetDeviceProcAddr from the ICD\n");
			return NULL;
		}
	}
	return icd_gdpa(device, name);
}
