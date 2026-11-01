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
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

static NSString *gLastError = @"not tried";
NSString *A01MTLLastError(void) { return gLastError; }

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
	void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		gLastError = [NSString stringWithFormat:@"no Vulkan library at %s", path];
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
#undef IFN
	uint32_t n = 1;
	if (pvkEnumeratePhysicalDevices(vk->inst, &n, &vk->phys) < 0 || n == 0) {
		gLastError = @"no Vulkan physical device (GE8100 kernel driver not ready)";
		return NO;
	}
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
	if (pvkCreateDevice(vk->phys, &dci, NULL, &vk->dev) != VK_SUCCESS) {
		gLastError = @"vkCreateDevice failed";
		return NO;
	}
	pvkGetDeviceQueue(vk->dev, vk->qfam, 0, &vk->queue);
	return YES;
}

static int32_t A01VKMemType(A01VK *vk, uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < vk->mem.memoryTypeCount; i++) {
		if ((bits & (1u << i)) && (vk->mem.memoryTypes[i].propertyFlags & want) == want) return (int32_t)i;
	}
	return -1;
}

@class A01MTLDevice;

/* ---- MTLBuffer -------------------------------------------------------------------------- */
@interface A01MTLBuffer : NSObject <MTLBuffer>
@property (nonatomic, readonly) VkBuffer vkBuffer;
@end

@implementation A01MTLBuffer {
	A01MTLDevice *_dev;
	A01VK *_vk;
	VkDeviceMemory _mem;
	void *_map;
	NSUInteger _len;
	MTLResourceOptions _opts;
}
@synthesize label;

- (nullable instancetype)initWithDevice:(A01MTLDevice *)d vk:(A01VK *)vk length:(NSUInteger)len
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
// A metallib holds Metal AIR (LLVM bitcode). Turning a function into SPIR-V is metal2vulkan's
// job; until it is linked in, functions exist but pipelines cannot be built from them.
@interface A01MTLFunction : NSObject <MTLFunction>
@end
@implementation A01MTLFunction {
	NSString *_name;
	id<MTLDevice> _dev;
}
@synthesize label;
- (instancetype)initWithName:(NSString *)n device:(id<MTLDevice>)d
{
	if ((self = [super init])) { _name = [n copy]; _dev = d; }
	return self;
}
- (NSString *)name { return _name; }
- (id<MTLDevice>)device { return _dev; }
- (MTLFunctionType)functionType { return MTLFunctionTypeKernel; }
@end

@interface A01MTLLibrary : NSObject <MTLLibrary>
@end
@implementation A01MTLLibrary {
	NSData *_air;
	id<MTLDevice> _dev;
}
@synthesize label;
- (instancetype)initWithData:(NSData *)d device:(id<MTLDevice>)dev
{
	if ((self = [super init])) { _air = d; _dev = dev; }
	return self;
}
- (id<MTLDevice>)device { return _dev; }
- (NSArray<NSString *> *)functionNames { return @[]; /* filled by the metallib parser (todo) */ }
- (nullable id<MTLFunction>)newFunctionWithName:(NSString *)name
{
	return [[A01MTLFunction alloc] initWithName:name device:_dev];
}
@end

/* ---- command buffers and encoders -------------------------------------------------------- */
@interface A01MTLCommandBuffer : NSObject <MTLCommandBuffer>
- (instancetype)initWithQueue:(id<MTLCommandQueue>)q vk:(A01VK *)vk pool:(VkCommandPool)pool;
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

@implementation A01MTLCommandBuffer {
	id<MTLCommandQueue> _queue;
	A01VK *_vk;
	VkCommandPool _pool;
	VkFence _fence;
	MTLCommandBufferStatus _status;
	NSMutableArray<MTLCommandBufferHandler> *_completed;
	NSError *_error;
}
@synthesize label;

- (instancetype)initWithQueue:(id<MTLCommandQueue>)q vk:(A01VK *)vk pool:(VkCommandPool)pool
{
	if (!(self = [super init])) return nil;
	_queue = q; _vk = vk; _pool = pool; _completed = [NSMutableArray new];
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
	(void)d;
	_error = A01Err(@"render encoders need textures and render passes, not implemented yet");
	return nil;
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
	_status = (r == VK_SUCCESS) ? MTLCommandBufferStatusCompleted : MTLCommandBufferStatusError;
	if (r != VK_SUCCESS) _error = A01Err([NSString stringWithFormat:@"fence wait failed (%d)", r]);
	for (MTLCommandBufferHandler h in _completed) h(self);
	[_completed removeAllObjects];
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
@interface A01MTLDevice : NSObject <MTLDevice>
@end
@implementation A01MTLDevice {
	A01VK _vk;
}

- (nullable instancetype)init
{
	if (!(self = [super init])) return nil;
	if (!A01VKLoad(&_vk)) return nil;
	return self;
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
	(void)d;
	if (error) *error = A01Err(@"render pipelines not implemented yet");
	return nil;
}
@end

id<MTLDevice> A01MTLCreateSystemDefaultDevice(void)
{
	static A01MTLDevice *dev;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ dev = [A01MTLDevice new]; });
	return dev;
}
