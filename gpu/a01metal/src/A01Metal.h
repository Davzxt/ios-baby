// A01Metal: our own Metal driver for the Galaxy A01 Core (PowerVR GE8100), layered on Vulkan.
//
// Layering: Metal objects (this library) -> Vulkan (Mesa "pvr", loaded at run time) -> the
// GE8100 kernel driver in XNU. Shaders: Metal AIR -> SPIR-V through metal2vulkan
// (github.com/steelbrain/metal2vulkan), hooked in A01MTLLibrary.
//
// Status: the Vulkan side has no GPU under it yet (the GE8100 firmware does not boot yet,
// see A01CORE_PROGRESS.md). A01MTLCreateSystemDefaultDevice() returns nil until a Vulkan
// physical device exists; nothing here pretends to draw.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// The Vulkan library to load (Mesa pvr ICD built for iOS). Overridden by A01METAL_VULKAN.
#define A01METAL_DEFAULT_VULKAN "/private/var/a01/lib/libvulkan_powervr.dylib"

// nil when no Vulkan device is available.
FOUNDATION_EXPORT id<MTLDevice> _Nullable A01MTLCreateSystemDefaultDevice(void);

// Last reason device creation failed (for logs and tests).
FOUNDATION_EXPORT NSString *A01MTLLastError(void);

NS_ASSUME_NONNULL_END
