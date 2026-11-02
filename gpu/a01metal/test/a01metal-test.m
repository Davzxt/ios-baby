// a01metal-test: GPU tests through Metal (A01Metal) -> Vulkan (img-pvr) -> DDK 1.11 -> GE8100.
//   TESTE 1: copia de memoria (blit fill + copy)
//   TESTE 2: textura + render pass (clear para vermelho, leitura dos pixels)
//   TESTE 3: shader simples (pipeline SPIR-V desenha um triangulo verde, leitura dos pixels)
// Output goes to /private/var/herolte/autorun.out; the kernel prints it at the next boot.
#import "A01Metal.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "tri_spv.h"   /* tri_vert_spv / tri_frag_spv, built from tri.vert / tri.frag */

static int
check_pixels(id<MTLBuffer> b, unsigned w, unsigned h, uint8_t r, uint8_t g, uint8_t bl, uint8_t a, unsigned *bad_out)
{
	const uint8_t *p = b.contents;
	unsigned bad = 0;
	for (unsigned i = 0; i < w * h; i++) {
		if (p[4 * i] != r || p[4 * i + 1] != g || p[4 * i + 2] != bl || p[4 * i + 3] != a) bad++;
	}
	*bad_out = bad;
	return bad == 0;
}

static void
pause_between(void)
{
	fflush(stdout);
	sleep(3);
}

int main(void)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		printf("=== A01Metal: testes da GPU (Metal -> Vulkan -> DDK -> GE8100) ===\n");
		id<MTLDevice> dev = A01MTLCreateSystemDefaultDevice();
		if (!dev) {
			printf("ERRO: sem dispositivo Metal: %s\n", A01MTLLastError().UTF8String);
			return 1;
		}
		printf("dispositivo: %s\n", dev.name.UTF8String);
		id<MTLCommandQueue> q = [dev newCommandQueue];
		int failures = 0;

		/* TESTE 1 */
		{
			id<MTLBuffer> a = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
			id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
			memset(b.contents, 0, 4096);
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
			[bl fillBuffer:a range:NSMakeRange(0, 4096) value:0x5a];
			[bl copyFromBuffer:a sourceOffset:0 toBuffer:b destinationOffset:0 size:4096];
			[bl endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			const uint8_t *p = b.contents;
			unsigned bad = 0;
			for (unsigned i = 0; i < 4096; i++) bad += p[i] != 0x5a;
			int ok = cb.status == MTLCommandBufferStatusCompleted && !bad;
			printf("TESTE 1 (copia de memoria): %s (status %ld, %u bytes errados%s%s)\n", ok ? "OK" : "ERRO",
			       (long)cb.status, bad, cb.error ? ", " : "", cb.error ? cb.error.localizedDescription.UTF8String : "");
			failures += !ok;
		}
		pause_between();

		/* TESTE 2 */
		{
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
			                                                                               width:64 height:64 mipmapped:NO];
			td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
			id<MTLTexture> t = [dev newTextureWithDescriptor:td];
			id<MTLBuffer> out = [dev newBufferWithLength:64 * 64 * 4 options:MTLResourceStorageModeShared];
			if (!t || !out) {
				printf("TESTE 2 (textura + render pass): ERRO (textura ou buffer nao criados)\n");
				failures++;
			} else {
				memset(out.contents, 0, 64 * 64 * 4);
				MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
				rp.colorAttachments[0].texture = t;
				rp.colorAttachments[0].loadAction = MTLLoadActionClear;
				rp.colorAttachments[0].storeAction = MTLStoreActionStore;
				rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
				id<MTLCommandBuffer> cb = [q commandBuffer];
				id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
				if (!re) {
					printf("TESTE 2 (textura + render pass): ERRO (%s)\n", cb.error.localizedDescription.UTF8String);
					failures++;
				} else {
					[re endEncoding];
					id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
					[bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
					         sourceSize:MTLSizeMake(64, 64, 1) toBuffer:out destinationOffset:0
					destinationBytesPerRow:64 * 4 destinationBytesPerImage:64 * 64 * 4];
					[bl endEncoding];
					[cb commit];
					[cb waitUntilCompleted];
					unsigned bad;
					int ok = cb.status == MTLCommandBufferStatusCompleted && check_pixels(out, 64, 64, 255, 0, 0, 255, &bad);
					const uint8_t *p = out.contents;
					printf("TESTE 2 (textura + render pass): %s (status %ld, %u pixels errados, pixel 0 = %u,%u,%u,%u)\n",
					       ok ? "OK" : "ERRO", (long)cb.status, bad, p[0], p[1], p[2], p[3]);
					failures += !ok;
				}
			}
		}
		pause_between();

		/* TESTE 3 */
		{
			NSError *e = nil;
			id<MTLLibrary> vl = [dev newLibraryWithData:(dispatch_data_t)[NSData dataWithBytes:tri_vert_spv length:sizeof(tri_vert_spv)] error:&e];
			id<MTLLibrary> fl = [dev newLibraryWithData:(dispatch_data_t)[NSData dataWithBytes:tri_frag_spv length:sizeof(tri_frag_spv)] error:&e];
			MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
			pd.vertexFunction = [vl newFunctionWithName:@"main"];
			pd.fragmentFunction = [fl newFunctionWithName:@"main"];
			pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
			id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
			                                                                               width:64 height:64 mipmapped:NO];
			id<MTLTexture> t = [dev newTextureWithDescriptor:td];
			id<MTLBuffer> out = [dev newBufferWithLength:64 * 64 * 4 options:MTLResourceStorageModeShared];
			if (!ps || !t || !out) {
				printf("TESTE 3 (shader simples): ERRO (%s)\n", e ? e.localizedDescription.UTF8String : "textura ou buffer nao criados");
				failures++;
			} else {
				memset(out.contents, 0, 64 * 64 * 4);
				MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
				rp.colorAttachments[0].texture = t;
				rp.colorAttachments[0].loadAction = MTLLoadActionClear;
				rp.colorAttachments[0].storeAction = MTLStoreActionStore;
				rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
				id<MTLCommandBuffer> cb = [q commandBuffer];
				id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
				[re setRenderPipelineState:ps];
				[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[re endEncoding];
				id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
				[bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
				         sourceSize:MTLSizeMake(64, 64, 1) toBuffer:out destinationOffset:0
				destinationBytesPerRow:64 * 4 destinationBytesPerImage:64 * 64 * 4];
				[bl endEncoding];
				[cb commit];
				[cb waitUntilCompleted];
				unsigned bad;
				int ok = cb.status == MTLCommandBufferStatusCompleted && check_pixels(out, 64, 64, 0, 255, 0, 255, &bad);
				const uint8_t *p = out.contents;
				printf("TESTE 3 (shader simples): %s (status %ld, %u pixels errados, pixel central = %u,%u,%u,%u)\n",
				       ok ? "OK" : "ERRO", (long)cb.status, bad, p[4 * (32 * 64 + 32)], p[4 * (32 * 64 + 32) + 1],
				       p[4 * (32 * 64 + 32) + 2], p[4 * (32 * 64 + 32) + 3]);
				failures += !ok;
			}
		}
		printf("=== resultado: %d de 3 testes com ERRO ===\n", failures);
		return failures;
	}
}
