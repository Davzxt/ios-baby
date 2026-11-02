// A01Metal: Metal objects on Vulkan. See A01Metal.h for the layering and status.
//
// Implemented on Vulkan: device, buffers (host-visible, coherent), command queue, command
// buffers with fences, blit encoder (copy buffer, fill buffer), libraries holding Metal AIR.
// Not yet: compute/render pipelines (need AIR -> SPIR-V via metal2vulkan), textures,
// render passes, drawables/IOSurface. Those return nil with an NSError saying so.
#define VK_NO_PROTOTYPES 1
#import "A01Metal.h"
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

static NSString *gLastError = @"not tried";
NSString *A01MTLLastError(void) { return gLastError; }
/* the step A01Metal is in, for crash/hang reports (a01metal-test) */
const char *volatile A01MTLStep = "inicio";
#define STEP(s) (A01MTLStep = (s))

static NSError *A01Err(NSString *msg)
{
	return [NSError errorWithDomain:@"A01Metal" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

/* ---- Vulkan dispatch ------------------------------------------------------------------- */
#define VKFN(x) static PFN_##x p##x;
VKFN(vkGetInstanceProcAddr) VKFN(vkCreateInstance) VKFN(vkEnumeratePhysicalDevices)
VKFN(vkGetPhysicalDeviceProperties) VKFN(vkGetPhysicalDeviceQueueFamilyProperties)
VKFN(vkGetPhysicalDeviceMemoryProperties) VKFN(vkCreateDevice) VKFN(vkGetDeviceQueue)
VKFN(vkCreateBuffer) VKFN(vkDestroyBuffer) VKFN(vkGetBufferMemoryRequirements)
VKFN(vkAllocateMemory) VKFN(vkFreeMemory) VKFN(vkBindBufferMemory) VKFN(vkMapMemory)
VKFN(vkCreateCommandPool) VKFN(vkAllocateCommandBuffers) VKFN(vkFreeCommandBuffers)
VKFN(vkBeginCommandBuffer) VKFN(vkEndCommandBuffer) VKFN(vkCmdCopyBuffer) VKFN(vkCmdFillBuffer)
VKFN(vkCmdPipelineBarrier) VKFN(vkQueueSubmit) VKFN(vkCreateFence) VKFN(vkDestroyFence)
VKFN(vkWaitForFences)
/* textures, render passes, pipelines */
VKFN(vkCreateImage) VKFN(vkDestroyImage) VKFN(vkGetImageMemoryRequirements) VKFN(vkBindImageMemory) VKFN(vkCreateImageView) VKFN(vkDestroyImageView) VKFN(vkCreateRenderPass) VKFN(vkDestroyRenderPass) VKFN(vkCreateFramebuffer) VKFN(vkDestroyFramebuffer) VKFN(vkCreateShaderModule) VKFN(vkDestroyShaderModule) VKFN(vkCreatePipelineLayout) VKFN(vkDestroyPipelineLayout) VKFN(vkCreateGraphicsPipelines) VKFN(vkDestroyPipeline) VKFN(vkCmdBeginRenderPass) VKFN(vkCmdEndRenderPass) VKFN(vkCmdBindPipeline) VKFN(vkCmdDraw) VKFN(vkCmdSetViewport) VKFN(vkCmdSetScissor) VKFN(vkCmdCopyImageToBuffer)

typedef struct {
	VkInstance inst;
	VkPhysicalDevice phys;
	VkDevice dev;
	VkQueue queue;
	uint32_t qfam;
	VkPhysicalDeviceProperties props;
	VkPhysicalDeviceMemoryProperties mem;
} A01VK;

static BOOL A01VKLoad(A01VK *vk)
{
	const char *path = getenv("A01METAL_VULKAN") ?: A01METAL_DEFAULT_VULKAN;
	STEP("dlopen libvulkan_powervr");
	void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		const char *why = dlerror();
		gLastError = [NSString stringWithFormat:@"no Vulkan library at %s (%s)", path, why ? why : "?"];
		return NO;
	}
	/* Mesa ICDs export vk_icdGetInstanceProcAddr; a loader exports vkGetInstanceProcAddr */
	pvkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
	if (!pvkGetInstanceProcAddr) {
		pvkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
	}
	if (!pvkGetInstanceProcAddr) {
		gLastError = @"Vulkan library has no GetInstanceProcAddr";
		return NO;
	}
	pvkCreateInstance = (PFN_vkCreateInstance)pvkGetInstanceProcAddr(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pEngineName = "A01Metal",
	                          .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	STEP("vkCreateInstance");
	if (!pvkCreateInstance || pvkCreateInstance(&ici, NULL, &vk->inst) != VK_SUCCESS) {
		gLastError = @"vkCreateInstance failed";
		return NO;
	}
#define IFN(x) p##x = (PFN_##x)pvkGetInstanceProcAddr(vk->inst, #x)
	IFN(vkEnumeratePhysicalDevices); IFN(vkGetPhysicalDeviceProperties);
	IFN(vkGetPhysicalDeviceQueueFamilyProperties); IFN(vkGetPhysicalDeviceMemoryProperties);
	IFN(vkCreateDevice); IFN(vkGetDeviceQueue); IFN(vkCreateBuffer); IFN(vkDestroyBuffer);
	IFN(vkGetBufferMemoryRequirements); IFN(vkAllocateMemory); IFN(vkFreeMemory);
	IFN(vkBindBufferMemory); IFN(vkMapMemory); IFN(vkCreateCommandPool);
	IFN(vkAllocateCommandBuffers); IFN(vkFreeCommandBuffers); IFN(vkBeginCommandBuffer);
	IFN(vkEndCommandBuffer); IFN(vkCmdCopyBuffer); IFN(vkCmdFillBuffer); IFN(vkCmdPipelineBarrier);
	IFN(vkQueueSubmit); IFN(vkCreateFence); IFN(vkDestroyFence); IFN(vkWaitForFences);
	IFN(vkCreateImage); IFN(vkDestroyImage); IFN(vkGetImageMemoryRequirements); IFN(vkBindImageMemory); IFN(vkCreateImageView); IFN(vkDestroyImageView); IFN(vkCreateRenderPass); IFN(vkDestroyRenderPass); IFN(vkCreateFramebuffer); IFN(vkDestroyFramebuffer); IFN(vkCreateShaderModule); IFN(vkDestroyShaderModule); IFN(vkCreatePipelineLayout); IFN(vkDestroyPipelineLayout); IFN(vkCreateGraphicsPipelines); IFN(vkDestroyPipeline); IFN(vkCmdBeginRenderPass); IFN(vkCmdEndRenderPass); IFN(vkCmdBindPipeline); IFN(vkCmdDraw); IFN(vkCmdSetViewport); IFN(vkCmdSetScissor); IFN(vkCmdCopyImageToBuffer);
#undef IFN
	uint32_t n = 1;
	STEP("vkEnumeratePhysicalDevices (abre a GPU)");
	if (pvkEnumeratePhysicalDevices(vk->inst, &n, &vk->phys) < 0 || n == 0) {
		gLastError = @"no Vulkan physical device (GE8100 kernel driver not ready)";
		return NO;
	}
	STEP("propriedades da GPU");
	pvkGetPhysicalDeviceProperties(vk->phys, &vk->props);
	pvkGetPhysicalDeviceMemoryProperties(vk->phys, &vk->mem);
	uint32_t nq = 8;
	VkQueueFamilyProperties qf[8];
	pvkGetPhysicalDeviceQueueFamilyProperties(vk->phys, &nq, qf);
	vk->qfam = UINT32_MAX;
	for (uint32_t i = 0; i < nq; i++) {
		if (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { vk->qfam = i; break; }
	}
	if (vk->qfam == UINT32_MAX) {
		gLastError = @"no graphics queue";
		return NO;
	}
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
	                                .queueFamilyIndex = vk->qfam, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
	                           .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	STEP("vkCreateDevice");
	VkResult dr = pvkCreateDevice(vk->phys, &dci, NULL, &vk->dev);
	if (dr != VK_SUCCESS) {
		gLastError = [NSString stringWithFormat:@"vkCreateDevice VkResult %d", (int)dr];
		return NO;
	}
	pvkGetDeviceQueue(vk->dev, vk->qfam, 0, &vk->queue);
	STEP("dispositivo pronto");
	return YES;
}

static int32_t A01VKMemType(A01VK *vk, uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < vk->mem.memoryTypeCount; i++) {
		if ((bits & (1u << i)) && (vk->mem.memoryTypes[i].propertyFlags & want) == want) return (int32_t)i;
	}
	return -1;
}

@class A01MTLDeviceImpl;

/* ---- MTLBuffer -------------------------------------------------------------------------- */
@interface A01MTLBuffer : NSObject <MTLBuffer>
@property (nonatomic, readonly) VkBuffer vkBuffer;
@end

@implementation A01MTLBuffer {
	A01MTLDeviceImpl *_dev;
	A01VK *_vk;
	VkDeviceMemory _mem;
	void *_map;
	NSUInteger _len;
	MTLResourceOptions _opts;
}
@synthesize label;

- (nullable instancetype)initWithDevice:(A01MTLDeviceImpl *)d vk:(A01VK *)vk length:(NSUInteger)len
                                options:(MTLResourceOptions)o
{
	if (!(self = [super init])) return nil;
	_dev = d; _vk = vk; _len = len ? len : 1; _opts = o;
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = _len,
	    .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
	             VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT |
	             VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
	    .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
	if (pvkCreateBuffer(vk->dev, &bci, NULL, &_vkBuffer) != VK_SUCCESS) return nil;
	VkMemoryRequirements req;
	pvkGetBufferMemoryRequirements(vk->dev, _vkBuffer, &req);
	/* Shared and managed storage are CPU-visible in Metal; this unified-memory GPU has no VRAM */
	int32_t t = A01VKMemType(vk, req.memoryTypeBits,
	                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	if (t < 0) return nil;
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
	                             .allocationSize = req.size, .memoryTypeIndex = (uint32_t)t };
	if (pvkAllocateMemory(vk->dev, &mai, NULL, &_mem) != VK_SUCCESS) return nil;
	pvkBindBufferMemory(vk->dev, _vkBuffer, _mem, 0);
	if (pvkMapMemory(vk->dev, _mem, 0, VK_WHOLE_SIZE, 0, &_map) != VK_SUCCESS) return nil;
	return self;
}

- (void)dealloc
{
	if (_vkBuffer) pvkDestroyBuffer(_vk->dev, _vkBuffer, NULL);
	if (_mem) pvkFreeMemory(_vk->dev, _mem, NULL);
}

- (void *)contents { return (_opts & MTLResourceStorageModePrivate) ? NULL : _map; }
- (NSUInteger)length { return _len; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_dev; }
- (MTLResourceOptions)resourceOptions { return _opts; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_opts >> MTLResourceStorageModeShift) & 0xf); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_opts & 0xf); }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (NSUInteger)allocatedSize { return _len; }
- (uint64_t)gpuAddress { return 0; }
- (void)didModifyRange:(NSRange)range { (void)range; /* coherent memory */ }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)s { (void)s; return MTLPurgeableStateNonVolatile; }
@end

/* ---- MTLLibrary / MTLFunction ----------------------------------------------------------- */
// A library is either SPIR-V (magic 0x07230203: used as is, entry points by name) or a Metal
// metallib with AIR (LLVM bitcode). AIR -> SPIR-V is metal2vulkan's job and is not linked yet:
// AIR functions exist, but pipelines are built only from SPIR-V ones.
#define A01_SPIRV_MAGIC 0x07230203u

@interface A01MTLFunction : NSObject <MTLFunction>
@property (nonatomic, readonly, nullable) NSData *spirv;
@end
@implementation A01MTLFunction {
	NSString *_name;
	id<MTLDevice> _dev;
	NSData *_spirv;
}
@synthesize label;
- (instancetype)initWithName:(NSString *)n device:(id<MTLDevice>)d spirv:(nullable NSData *)spirv
{
	if ((self = [super init])) { _name = [n copy]; _dev = d; _spirv = spirv; }
	return self;
}
- (NSString *)name { return _name; }
- (id<MTLDevice>)device { return _dev; }
- (nullable NSData *)spirv { return _spirv; }
- (MTLFunctionType)functionType { return MTLFunctionTypeKernel; }
@end

@interface A01MTLLibrary : NSObject <MTLLibrary>
@end
@implementation A01MTLLibrary {
	NSData *_code;
	id<MTLDevice> _dev;
	BOOL _isSPIRV;
}
@synthesize label;
- (instancetype)initWithData:(NSData *)d device:(id<MTLDevice>)dev
{
	if ((self = [super init])) {
		_code = d;
		_dev = dev;
		_isSPIRV = d.length >= 20 && ((const uint32_t *)d.bytes)[0] == A01_SPIRV_MAGIC;
	}
	return self;
}
- (id<MTLDevice>)device { return _dev; }
- (NSArray<NSString *> *)functionNames { return @[]; /* filled by the metallib parser (todo) */ }
- (nullable id<MTLFunction>)newFunctionWithName:(NSString *)name
{
	return [[A01MTLFunction alloc] initWithName:name device:_dev spirv:_isSPIRV ? _code : nil];
}
@end

/* ---- formats ---------------------------------------------------------------------------------- */
static VkFormat
a01_vk_format(MTLPixelFormat f)
{
	switch (f) {
	case MTLPixelFormatRGBA8Unorm: return VK_FORMAT_R8G8B8A8_UNORM;
	case MTLPixelFormatBGRA8Unorm: return VK_FORMAT_B8G8R8A8_UNORM;
	case MTLPixelFormatRGBA8Unorm_sRGB: return VK_FORMAT_R8G8B8A8_SRGB;
	case MTLPixelFormatBGRA8Unorm_sRGB: return VK_FORMAT_B8G8R8A8_SRGB;
	default: return VK_FORMAT_UNDEFINED;
	}
}

/* ---- MTLTexture: a 2D VkImage in device memory, with its view ------------------------------ */
@interface A01MTLTexture : NSObject <MTLTexture>
@property (nonatomic, readonly) VkImage vkImage;
@property (nonatomic, readonly) VkImageView vkView;
@property (nonatomic, readonly) VkFormat vkFormat;
@property (nonatomic) VkImageLayout vkLayout;   /* layout after the last recorded use */
@end

@implementation A01MTLTexture {
	id<MTLDevice> _dev;
	A01VK *_vk;
	VkDeviceMemory _mem;
	NSUInteger _w, _h;
	MTLPixelFormat _fmt;
}
@synthesize label;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)d vk:(A01VK *)vk descriptor:(MTLTextureDescriptor *)desc
{
	if (!(self = [super init])) return nil;
	_dev = d; _vk = vk; _w = desc.width; _h = desc.height; _fmt = desc.pixelFormat;
	_vkFormat = a01_vk_format(desc.pixelFormat);
	if (_vkFormat == VK_FORMAT_UNDEFINED || desc.textureType != MTLTextureType2D) return nil;
	VkImageCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
	    .format = _vkFormat, .extent = { (uint32_t)_w, (uint32_t)_h, 1 }, .mipLevels = 1, .arrayLayers = 1,
	    .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
	    .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
	             VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
	    .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	if (pvkCreateImage(vk->dev, &ici, NULL, &_vkImage) != VK_SUCCESS) return nil;
	VkMemoryRequirements req;
	pvkGetImageMemoryRequirements(vk->dev, _vkImage, &req);
	int32_t t = A01VKMemType(vk, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	if (t < 0) t = A01VKMemType(vk, req.memoryTypeBits, 0);
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
	                             .allocationSize = req.size, .memoryTypeIndex = (uint32_t)t };
	if (t < 0 || pvkAllocateMemory(vk->dev, &mai, NULL, &_mem) != VK_SUCCESS) return nil;
	pvkBindImageMemory(vk->dev, _vkImage, _mem, 0);
	VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = _vkImage,
	    .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = _vkFormat,
	    .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	if (pvkCreateImageView(vk->dev, &vci, NULL, &_vkView) != VK_SUCCESS) return nil;
	_vkLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	return self;
}

- (void)dealloc
{
	if (_vkView) pvkDestroyImageView(_vk->dev, _vkView, NULL);
	if (_vkImage) pvkDestroyImage(_vk->dev, _vkImage, NULL);
	if (_mem) pvkFreeMemory(_vk->dev, _mem, NULL);
}

- (id<MTLDevice>)device { return _dev; }
- (NSUInteger)width { return _w; }
- (NSUInteger)height { return _h; }
- (NSUInteger)depth { return 1; }
- (NSUInteger)mipmapLevelCount { return 1; }
- (NSUInteger)arrayLength { return 1; }
- (NSUInteger)sampleCount { return 1; }
- (MTLPixelFormat)pixelFormat { return _fmt; }
- (MTLTextureType)textureType { return MTLTextureType2D; }
- (MTLStorageMode)storageMode { return MTLStorageModePrivate; }
@end

/* ---- MTLRenderPipelineState: a VkPipeline for one color attachment format ----------------- */
@interface A01MTLRenderPipelineState : NSObject <MTLRenderPipelineState>
@property (nonatomic, readonly) VkPipeline vkPipeline;
@end

@implementation A01MTLRenderPipelineState {
	id<MTLDevice> _dev;
	A01VK *_vk;
	VkPipelineLayout _layout;
	VkRenderPass _pass;
	VkShaderModule _vs, _fs;
}
@synthesize label;

static VkShaderModule
a01_shader(A01VK *vk, NSData *spirv)
{
	VkShaderModule m = VK_NULL_HANDLE;
	VkShaderModuleCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
	    .codeSize = spirv.length, .pCode = spirv.bytes };
	return pvkCreateShaderModule(vk->dev, &ci, NULL, &m) == VK_SUCCESS ? m : VK_NULL_HANDLE;
}

/* render pass compatible with every encoder that renders to this format (load/store ops do not
 * matter for compatibility) */
static VkRenderPass
a01_render_pass(A01VK *vk, VkFormat fmt, VkAttachmentLoadOp load)
{
	VkAttachmentDescription att = { .format = fmt, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = load,
	    .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
	    .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
	    .initialLayout = load == VK_ATTACHMENT_LOAD_OP_LOAD ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
	    .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
	VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
	    .colorAttachmentCount = 1, .pColorAttachments = &ref };
	VkRenderPassCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
	    .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
	VkRenderPass rp = VK_NULL_HANDLE;
	return pvkCreateRenderPass(vk->dev, &ci, NULL, &rp) == VK_SUCCESS ? rp : VK_NULL_HANDLE;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)d vk:(A01VK *)vk descriptor:(MTLRenderPipelineDescriptor *)desc
                                  error:(NSError **)error
{
	if (!(self = [super init])) return nil;
	_dev = d; _vk = vk;
	A01MTLFunction *vf = (A01MTLFunction *)desc.vertexFunction, *ff = (A01MTLFunction *)desc.fragmentFunction;
	VkFormat fmt = a01_vk_format(desc.colorAttachments[0].pixelFormat);
	if (!vf.spirv || !ff.spirv) {
		if (error) *error = A01Err(@"render pipeline: shaders must be SPIR-V (AIR translation not linked yet)");
		return nil;
	}
	if (fmt == VK_FORMAT_UNDEFINED) {
		if (error) *error = A01Err(@"render pipeline: color attachment format not supported");
		return nil;
	}
	_vs = a01_shader(vk, vf.spirv);
	_fs = a01_shader(vk, ff.spirv);
	_pass = a01_render_pass(vk, fmt, VK_ATTACHMENT_LOAD_OP_CLEAR);
	VkPipelineLayoutCreateInfo lci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	if (!_vs || !_fs || !_pass || pvkCreatePipelineLayout(vk->dev, &lci, NULL, &_layout) != VK_SUCCESS) {
		if (error) *error = A01Err(@"render pipeline: shader module, render pass or layout creation failed");
		return nil;
	}
	const char *vname = vf.name.UTF8String, *fname = ff.name.UTF8String;
	VkPipelineShaderStageCreateInfo st[2] = {
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = _vs, .pName = vname },
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = _fs, .pName = fname },
	};
	VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	    .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
	    .viewportCount = 1, .scissorCount = 1 };
	VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	    .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
	    .lineWidth = 1.0f };
	VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	    .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
	    .attachmentCount = 1, .pAttachments = &cba };
	VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
	VkPipelineDynamicStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
	    .dynamicStateCount = 2, .pDynamicStates = dyn };
	VkGraphicsPipelineCreateInfo gci = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
	    .stageCount = 2, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
	    .pViewportState = &vp, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb,
	    .pDynamicState = &ds, .layout = _layout, .renderPass = _pass, .subpass = 0 };
	VkResult r = pvkCreateGraphicsPipelines(vk->dev, VK_NULL_HANDLE, 1, &gci, NULL, &_vkPipeline);
	if (r != VK_SUCCESS) {
		if (error) *error = A01Err([NSString stringWithFormat:@"render pipeline: vkCreateGraphicsPipelines %d", r]);
		return nil;
	}
	return self;
}

- (void)dealloc
{
	if (_vkPipeline) pvkDestroyPipeline(_vk->dev, _vkPipeline, NULL);
	if (_layout) pvkDestroyPipelineLayout(_vk->dev, _layout, NULL);
	if (_pass) pvkDestroyRenderPass(_vk->dev, _pass, NULL);
	if (_vs) pvkDestroyShaderModule(_vk->dev, _vs, NULL);
	if (_fs) pvkDestroyShaderModule(_vk->dev, _fs, NULL);
}

- (id<MTLDevice>)device { return _dev; }
@end

/* ---- command buffers and encoders -------------------------------------------------------- */
@interface A01MTLCommandBuffer : NSObject <MTLCommandBuffer>
- (instancetype)initWithQueue:(id<MTLCommandQueue>)q vk:(A01VK *)vk pool:(VkCommandPool)pool;
- (void)a01_retainUntilCompleted:(id)obj;
@property (nonatomic, readonly) VkCommandBuffer vkCmd;
@end

@interface A01MTLBlitCommandEncoder : NSObject <MTLBlitCommandEncoder>
- (instancetype)initWithCommandBuffer:(A01MTLCommandBuffer *)cb;
@end

@implementation A01MTLBlitCommandEncoder {
	A01MTLCommandBuffer *_cb;
}
@synthesize label;
- (instancetype)initWithCommandBuffer:(A01MTLCommandBuffer *)cb
{
	if ((self = [super init])) _cb = cb;
	return self;
}
- (id<MTLDevice>)device { return _cb.device; }
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst
     destinationOffset:(NSUInteger)doff size:(NSUInteger)size
{
	VkBufferCopy r = { .srcOffset = so, .dstOffset = doff, .size = size };
	pvkCmdCopyBuffer(_cb.vkCmd, ((A01MTLBuffer *)src).vkBuffer, ((A01MTLBuffer *)dst).vkBuffer, 1, &r);
}
- (void)fillBuffer:(id<MTLBuffer>)buf range:(NSRange)range value:(uint8_t)v
{
	/* vkCmdFillBuffer needs 4-byte alignment; Metal allows any range */
	uint32_t word = v * 0x01010101u;
	NSUInteger a = (range.location + 3) & ~3ul, e = (range.location + range.length) & ~3ul;
	uint8_t *p = buf.contents;
	if (e > a) pvkCmdFillBuffer(_cb.vkCmd, ((A01MTLBuffer *)buf).vkBuffer, a, e - a, word);
	if (p) {   /* unaligned edges, CPU side (shared storage) */
		memset(p + range.location, v, MIN(a, range.location + range.length) - range.location);
		if (e > a) memset(p + e, v, range.location + range.length - e);
	}
}
/* texture -> buffer (readback): the image goes to TRANSFER_SRC first if it is not there yet */
- (void)copyFromTexture:(id<MTLTexture>)srcT sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level
           sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr
    destinationBytesPerImage:(NSUInteger)bpi
{
	(void)bpi;
	A01MTLTexture *t = (A01MTLTexture *)srcT;
	if (t.vkLayout != VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) {
		VkImageMemoryBarrier ib = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		    .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
		    .oldLayout = t.vkLayout, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		    .image = t.vkImage, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		pvkCmdPipelineBarrier(_cb.vkCmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
		                      0, 0, NULL, 0, NULL, 1, &ib);
		t.vkLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	}
	VkBufferImageCopy r = { .bufferOffset = doff, .bufferRowLength = (uint32_t)(bpr / 4), .bufferImageHeight = 0,
	    .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, (uint32_t)level, (uint32_t)slice, 1 },
	    .imageOffset = { (int32_t)origin.x, (int32_t)origin.y, 0 },
	    .imageExtent = { (uint32_t)size.width, (uint32_t)size.height, 1 } };
	pvkCmdCopyImageToBuffer(_cb.vkCmd, t.vkImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	                        ((A01MTLBuffer *)dst).vkBuffer, 1, &r);
}
- (void)endEncoding
{
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
	                       .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
	                       .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_HOST_READ_BIT };
	pvkCmdPipelineBarrier(_cb.vkCmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
	                      VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT,
	                      0, 1, &mb, 0, NULL, 0, NULL);
}
- (void)insertDebugSignpost:(NSString *)s { (void)s; }
- (void)pushDebugGroup:(NSString *)s { (void)s; }
- (void)popDebugGroup {}
@end

/* ---- render command encoder: one Vulkan render pass on color attachment 0 ------------------ */
@interface A01MTLRenderCommandEncoder : NSObject <MTLRenderCommandEncoder>
- (nullable instancetype)initWithCommandBuffer:(A01MTLCommandBuffer *)cb vk:(A01VK *)vk
                                    descriptor:(MTLRenderPassDescriptor *)d error:(NSError **)error;
@end

@implementation A01MTLRenderCommandEncoder {
	A01MTLCommandBuffer *_cb;
	A01VK *_vk;
	A01MTLTexture *_target;
	VkRenderPass _pass;
	VkFramebuffer _fb;
}
@synthesize label;

- (nullable instancetype)initWithCommandBuffer:(A01MTLCommandBuffer *)cb vk:(A01VK *)vk
                                    descriptor:(MTLRenderPassDescriptor *)d error:(NSError **)error
{
	if (!(self = [super init])) return nil;
	_cb = cb; _vk = vk;
	MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[0];
	_target = (A01MTLTexture *)ca.texture;
	if (_target == nil || ![_target isKindOfClass:[A01MTLTexture class]]) {
		if (error) *error = A01Err(@"render pass: color attachment 0 must be an A01Metal texture");
		return nil;
	}
	VkAttachmentLoadOp load = ca.loadAction == MTLLoadActionClear ? VK_ATTACHMENT_LOAD_OP_CLEAR :
	    ca.loadAction == MTLLoadActionLoad && _target.vkLayout != VK_IMAGE_LAYOUT_UNDEFINED ?
	    VK_ATTACHMENT_LOAD_OP_LOAD : VK_ATTACHMENT_LOAD_OP_DONT_CARE;
	if (load == VK_ATTACHMENT_LOAD_OP_LOAD && _target.vkLayout != VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) {
		VkImageMemoryBarrier ib = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		    .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		    .oldLayout = _target.vkLayout, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		    .image = _target.vkImage, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		pvkCmdPipelineBarrier(cb.vkCmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
		                      VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
	}
	_pass = a01_render_pass(vk, _target.vkFormat, load);
	VkImageView view = _target.vkView;
	VkFramebufferCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = _pass,
	    .attachmentCount = 1, .pAttachments = &view, .width = (uint32_t)_target.width,
	    .height = (uint32_t)_target.height, .layers = 1 };
	if (!_pass || pvkCreateFramebuffer(vk->dev, &fci, NULL, &_fb) != VK_SUCCESS) {
		if (error) *error = A01Err(@"render pass: vkCreateRenderPass/vkCreateFramebuffer failed");
		return nil;
	}
	[cb a01_retainUntilCompleted:self];
	MTLClearColor cc = ca.clearColor;
	VkClearValue clear = { .color = { .float32 = { (float)cc.red, (float)cc.green, (float)cc.blue, (float)cc.alpha } } };
	VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = _pass,
	    .framebuffer = _fb, .renderArea = { { 0, 0 }, { (uint32_t)_target.width, (uint32_t)_target.height } },
	    .clearValueCount = 1, .pClearValues = &clear };
	pvkCmdBeginRenderPass(cb.vkCmd, &bi, VK_SUBPASS_CONTENTS_INLINE);
	VkViewport vp = { 0, 0, (float)_target.width, (float)_target.height, 0.0f, 1.0f };
	VkRect2D sc = { { 0, 0 }, { (uint32_t)_target.width, (uint32_t)_target.height } };
	pvkCmdSetViewport(cb.vkCmd, 0, 1, &vp);
	pvkCmdSetScissor(cb.vkCmd, 0, 1, &sc);
	return self;
}

- (void)dealloc
{
	if (_fb) pvkDestroyFramebuffer(_vk->dev, _fb, NULL);
	if (_pass) pvkDestroyRenderPass(_vk->dev, _pass, NULL);
}

- (id<MTLDevice>)device { return _cb.device; }

- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)ps
{
	[_cb a01_retainUntilCompleted:ps];
	pvkCmdBindPipeline(_cb.vkCmd, VK_PIPELINE_BIND_POINT_GRAPHICS, ((A01MTLRenderPipelineState *)ps).vkPipeline);
}

- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
{
	(void)type;   /* the pipeline's topology (triangle list) applies */
	pvkCmdDraw(_cb.vkCmd, (uint32_t)count, 1, (uint32_t)start, 0);
}

- (void)endEncoding
{
	pvkCmdEndRenderPass(_cb.vkCmd);
	_target.vkLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;   /* the render pass's final layout */
}
- (void)insertDebugSignpost:(NSString *)s { (void)s; }
- (void)pushDebugGroup:(NSString *)s { (void)s; }
- (void)popDebugGroup {}
@end

@implementation A01MTLCommandBuffer {
	id<MTLCommandQueue> _queue;
	A01VK *_vk;
	VkCommandPool _pool;
	VkFence _fence;
	MTLCommandBufferStatus _status;
	NSMutableArray<MTLCommandBufferHandler> *_completed;
	NSMutableArray *_keep;
	NSError *_error;
}
@synthesize label;

- (instancetype)initWithQueue:(id<MTLCommandQueue>)q vk:(A01VK *)vk pool:(VkCommandPool)pool
{
	if (!(self = [super init])) return nil;
	_queue = q; _vk = vk; _pool = pool; _completed = [NSMutableArray new]; _keep = [NSMutableArray new];
	VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
	    .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
	    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	if (pvkAllocateCommandBuffers(vk->dev, &ai, &_vkCmd) != VK_SUCCESS ||
	    pvkBeginCommandBuffer(_vkCmd, &bi) != VK_SUCCESS) return nil;
	return self;
}

- (void)dealloc
{
	if (_fence) pvkDestroyFence(_vk->dev, _fence, NULL);
	if (_vkCmd) pvkFreeCommandBuffers(_vk->dev, _pool, 1, &_vkCmd);
}

- (id<MTLDevice>)device { return _queue.device; }
- (id<MTLCommandQueue>)commandQueue { return _queue; }
- (MTLCommandBufferStatus)status { return _status; }
- (nullable NSError *)error { return _error; }
- (BOOL)retainedReferences { return YES; }

- (nullable id<MTLBlitCommandEncoder>)blitCommandEncoder
{
	return [[A01MTLBlitCommandEncoder alloc] initWithCommandBuffer:self];
}

- (nullable id<MTLComputeCommandEncoder>)computeCommandEncoder
{
	_error = A01Err(@"compute encoders need AIR -> SPIR-V (metal2vulkan), not linked yet");
	return nil;
}

- (nullable id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{
	NSError *e = nil;
	A01MTLRenderCommandEncoder *enc = [[A01MTLRenderCommandEncoder alloc] initWithCommandBuffer:self vk:_vk
	                                                                                  descriptor:d error:&e];
	if (enc == nil) {
		_error = e;
	}
	return enc;
}

/* render passes, framebuffers and pipelines must outlive the GPU work that uses them */
- (void)a01_retainUntilCompleted:(id)obj
{
	if (obj) [_keep addObject:obj];
}

- (void)addCompletedHandler:(MTLCommandBufferHandler)block { [_completed addObject:[block copy]]; }
- (void)enqueue { _status = MTLCommandBufferStatusEnqueued; }

- (void)commit
{
	pvkEndCommandBuffer(_vkCmd);
	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	pvkCreateFence(_vk->dev, &fci, NULL, &_fence);
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
	                    .pCommandBuffers = &_vkCmd };
	if (pvkQueueSubmit(_vk->queue, 1, &si, _fence) != VK_SUCCESS) {
		_status = MTLCommandBufferStatusError;
		_error = A01Err(@"vkQueueSubmit failed");
		return;
	}
	_status = MTLCommandBufferStatusCommitted;
}

- (void)waitUntilScheduled {}

- (void)waitUntilCompleted
{
	if (_status != MTLCommandBufferStatusCommitted) return;
	VkResult r = pvkWaitForFences(_vk->dev, 1, &_fence, VK_TRUE, UINT64_MAX);
	/* XNU has no DDK timelines yet (no /dev/pvr_sync), so the driver reports every job as done at
	 * submit. Until the kernel signals completion, give the GPU time to finish before the CPU reads
	 * the results (A01METAL_SETTLE_MS, default 300). */
	const char *settle = getenv("A01METAL_SETTLE_MS");
	usleep((useconds_t)(settle ? atoi(settle) : 300) * 1000);
	_status = (r == VK_SUCCESS) ? MTLCommandBufferStatusCompleted : MTLCommandBufferStatusError;
	if (r != VK_SUCCESS) _error = A01Err([NSString stringWithFormat:@"fence wait failed (%d)", r]);
	for (MTLCommandBufferHandler h in _completed) h(self);
	[_completed removeAllObjects];
	[_keep removeAllObjects];   /* the GPU is done with them; also breaks encoder <-> buffer cycles */
}
@end

/* ---- MTLCommandQueue -------------------------------------------------------------------- */
@interface A01MTLCommandQueue : NSObject <MTLCommandQueue>
@end
@implementation A01MTLCommandQueue {
	id<MTLDevice> _dev;
	A01VK *_vk;
	VkCommandPool _pool;
}
@synthesize label;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)d vk:(A01VK *)vk
{
	if (!(self = [super init])) return nil;
	_dev = d; _vk = vk;
	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
	    .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = vk->qfam };
	if (pvkCreateCommandPool(vk->dev, &pci, NULL, &_pool) != VK_SUCCESS) return nil;
	return self;
}
- (id<MTLDevice>)device { return _dev; }
- (nullable id<MTLCommandBuffer>)commandBuffer
{
	return [[A01MTLCommandBuffer alloc] initWithQueue:self vk:_vk pool:_pool];
}
- (nullable id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
@end

/* ---- MTLDevice -------------------------------------------------------------------------- */
@interface A01MTLDeviceImpl : NSObject <MTLDevice>
@end
@implementation A01MTLDeviceImpl {
	A01VK _vk;
}

- (nullable instancetype)init
{
	if (!(self = [super init])) return nil;
	if (!A01VKLoad(&_vk)) return nil;
	return self;
}

/* Entry point Metal.framework uses for a driver bundle (MetalPluginClassName on the
 * IOAcceleratorES service, docs/a01core-metal-research.md). The accelerator port is the
 * A01CoreGPU service; the device itself goes through Vulkan and A01CoreGPU's user client. */
- (nullable instancetype)initWithAcceleratorPort:(unsigned int)port
{
	(void)port;
	NSLog(@"A01Metal: Metal.framework asked for a device (accelerator port %u)", port);
	return [self init];
}

- (NSString *)name { return [NSString stringWithFormat:@"PowerVR %s (A01Metal)", _vk.props.deviceName]; }
- (uint64_t)registryID { return 0xA01; }
- (BOOL)isLowPower { return YES; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return YES; }
- (NSUInteger)maxBufferLength { return 256u << 20; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(512, 512, 64); }
- (BOOL)supportsFamily:(MTLGPUFamily)f { (void)f; return NO; /* claim nothing until it works */ }

- (nullable id<MTLCommandQueue>)newCommandQueue
{
	return [[A01MTLCommandQueue alloc] initWithDevice:self vk:&_vk];
}
- (nullable id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n
{
	(void)n;
	return [self newCommandQueue];
}

- (nullable id<MTLBuffer>)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)o
{
	return [[A01MTLBuffer alloc] initWithDevice:self vk:&_vk length:len options:o];
}
- (nullable id<MTLBuffer>)newBufferWithBytes:(const void *)p length:(NSUInteger)len options:(MTLResourceOptions)o
{
	A01MTLBuffer *b = [[A01MTLBuffer alloc] initWithDevice:self vk:&_vk length:len
	                                                options:o & ~MTLResourceStorageModePrivate];
	if (b && p) memcpy(b.contents, p, len);
	return b;
}

- (nullable id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error
{
	(void)error;
	return [[A01MTLLibrary alloc] initWithData:(NSData *)data device:self];
}

- (nullable id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f
                                                                      error:(NSError **)error
{
	(void)f;
	if (error) *error = A01Err(@"AIR -> SPIR-V (metal2vulkan) not linked yet");
	return nil;
}

- (nullable id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
                                                                      error:(NSError **)error
{
	return [[A01MTLRenderPipelineState alloc] initWithDevice:self vk:&_vk descriptor:d error:error];
}

- (nullable id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
	return [[A01MTLTexture alloc] initWithDevice:self vk:&_vk descriptor:d];
}
@end

id<MTLDevice> A01MTLCreateSystemDefaultDevice(void)
{
	static A01MTLDeviceImpl *dev;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ dev = [A01MTLDeviceImpl new]; });
	return dev;
}

/* ---- Metal.framework plugin class ---------------------------------------------------------------
 * Metal's getMetalPluginClassForService (iOS 16.7.16, docs/a01core-metal-research.md) loads
 * /System/Library/Extensions/<MetalPluginName>.bundle, takes the class MetalPluginClassName names
 * and accepts it only if it is a subclass of Metal's private _MTLDevice. That class has no public
 * header, so "A01MTLDevice" is built at load time as a runtime subclass of _MTLDevice:
 *  - -initWithAcceleratorPort: runs _MTLDevice's own initializer, then creates the Vulkan-backed
 *    A01MTLDeviceImpl;
 *  - every method A01MTLDeviceImpl implements is added to the subclass as a forwarding entry
 *    (_objc_msgForward), and -forwardingTargetForSelector: hands the call to the implementation.
 */
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kA01ImplKey = &kA01ImplKey;

static id
a01_forwarding_target(id self, SEL _cmd, SEL sel)
{
	(void)_cmd; (void)sel;
	return objc_getAssociatedObject(self, kA01ImplKey);
}

static id
a01_init_with_port(id self, SEL _cmd, unsigned int port)
{
	struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
	self = ((id (*)(struct objc_super *, SEL, unsigned int))objc_msgSendSuper)(&sup, _cmd, port);
	if (self == nil) {
		NSLog(@"A01Metal: _MTLDevice refused accelerator port %u", port);
		return nil;
	}
	A01MTLDeviceImpl *impl = [A01MTLDeviceImpl new];
	if (impl == nil) {
		NSLog(@"A01Metal: no Vulkan device for Metal: %@", A01MTLLastError());
		return nil;
	}
	objc_setAssociatedObject(self, kA01ImplKey, impl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	NSLog(@"A01Metal: Metal device ready on accelerator port %u (%@)", port, impl.name);
	return self;
}

__attribute__((constructor)) static void
a01_register_plugin_class(void)
{
	Class base = NSClassFromString(@"_MTLDevice");
	if (base == Nil || NSClassFromString(@"A01MTLDevice") != Nil) {
		return;   /* not inside Metal.framework's process, or already registered */
	}
	Class cls = objc_allocateClassPair(base, "A01MTLDevice", 0);
	if (cls == Nil) {
		return;
	}
	class_addMethod(cls, @selector(initWithAcceleratorPort:), (IMP)a01_init_with_port, "@@:I");
	class_addMethod(cls, @selector(forwardingTargetForSelector:), (IMP)a01_forwarding_target, "@@::");
	unsigned int n = 0;
	Method *ms = class_copyMethodList([A01MTLDeviceImpl class], &n);
	for (unsigned int i = 0; i < n; i++) {
		SEL s = method_getName(ms[i]);
		if (s == @selector(init) || s == NSSelectorFromString(@"dealloc") || s == @selector(initWithAcceleratorPort:)) {
			continue;
		}
		/* override _MTLDevice's version: the call is forwarded to A01MTLDeviceImpl */
		class_addMethod(cls, s, _objc_msgForward, method_getTypeEncoding(ms[i]));
	}
	free(ms);
	objc_registerClassPair(cls);
}
