// a01metal-test: creates the A01Metal device and runs a blit (fill + copy) through Vulkan.
#import "A01Metal.h"
#include <stdio.h>
#include <string.h>

int main(void)
{
	@autoreleasepool {
		id<MTLDevice> dev = A01MTLCreateSystemDefaultDevice();
		if (!dev) {
			printf("A01Metal: no device: %s\n", A01MTLLastError().UTF8String);
			return 1;
		}
		printf("A01Metal: device %s\n", dev.name.UTF8String);
		id<MTLBuffer> a = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
		id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
		memset(b.contents, 0, 4096);
		id<MTLCommandQueue> q = [dev newCommandQueue];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
		[bl fillBuffer:a range:NSMakeRange(0, 4096) value:0x5a];
		[bl endEncoding];
		bl = [cb blitCommandEncoder];
		[bl copyFromBuffer:a sourceOffset:0 toBuffer:b destinationOffset:0 size:4096];
		[bl endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		const uint8_t *p = b.contents;
		unsigned bad = 0;
		for (unsigned i = 0; i < 4096; i++) bad += p[i] != 0x5a;
		printf("A01Metal: blit status %ld, %u wrong bytes -> %s\n", (long)cb.status, bad,
		       (cb.status == MTLCommandBufferStatusCompleted && !bad) ? "PASS" : "FAIL");
		return bad ? 2 : 0;
	}
}
