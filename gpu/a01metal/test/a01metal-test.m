// a01metal-test: GPU tests through Metal (A01Metal) -> Vulkan (img-pvr) -> DDK 1.11 -> GE8100.
//   TESTE 1: copia de memoria (blit fill + copy)
//   TESTE 2: textura + render pass (clear para vermelho, leitura dos pixels)
//   TESTE 3: shader simples (pipeline SPIR-V desenha um triangulo verde, leitura dos pixels)
// Output goes to /private/var/herolte/autorun.out; the kernel prints it at the next boot.
#import "A01Metal.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <dlfcn.h>
#include <execinfo.h>
#include "tri_spv.h"   /* tri_vert_spv / tri_frag_spv, built from tri.vert / tri.frag */

/* ---- diagnostics: a crash or a hang still leaves a readable report in autorun.out ---- */
#define A01_HANG_SECONDS 120

static void
dump_bridge_calls(void)
{
	void *drm = dlopen("/private/var/a01/lib/libdrm.2.dylib", RTLD_NOLOAD | RTLD_LAZY);
	void (*dump)(FILE *) = drm ? (void (*)(FILE *))dlsym(drm, "a01drm_trace_dump") : NULL;
	if (dump) {
		dump(stdout);
	} else {
		printf("  a01drm: nao carregada\n");
	}
}

static void
crash_handler(int sig, siginfo_t *si, void *ctx)
{
	(void)ctx;
	if (sig == SIGALRM) {
		printf("ERRO: TRAVOU por %d s na etapa: %s\n", A01_HANG_SECONDS, A01MTLStep);
	} else {
		printf("ERRO: CAIU com sinal %d (%s) endereco %p na etapa: %s\n", sig, strsignal(sig),
		       si ? si->si_addr : NULL, A01MTLStep);
	}
	dump_bridge_calls();
	void *frames[12];
	int n = backtrace(frames, 12);
	for (int i = 2; i < n; i++) {   /* skip this handler and the signal trampoline */
		Dl_info di;
		if (dladdr(frames[i], &di) && di.dli_fname) {
			const char *lib = strrchr(di.dli_fname, '/');
			printf("  %s+0x%lx %s\n", lib ? lib + 1 : di.dli_fname, (unsigned long)((char *)frames[i] - (char *)di.dli_fbase),
			       di.dli_sname ? di.dli_sname : "?");
		} else {
			printf("  %p\n", frames[i]);
		}
	}
	fflush(stdout);
	_exit(100 + sig);
}

static void
install_diagnostics(void)
{
	/* launchd appends to autorun.out: keep only this run so the boot report fits on screen */
	ftruncate(STDOUT_FILENO, 0);
	lseek(STDOUT_FILENO, 0, SEEK_SET);
	dup2(STDOUT_FILENO, STDERR_FILENO);   /* Mesa logs to stderr: keep them in order with ours */
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = crash_handler;
	sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
	int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS, SIGALRM };
	for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
		sigaction(sigs[i], &sa, NULL);
	}
	alarm(A01_HANG_SECONDS);
}

#define STEP(s) (A01MTLStep = (s))

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
		setvbuf(stdout, NULL, _IONBF, 0);
		install_diagnostics();
		printf("=== A01Metal: testes da GPU (Metal -> Vulkan -> DDK -> GE8100) ===\n");
		id<MTLDevice> dev = A01MTLCreateSystemDefaultDevice();
		if (!dev) {
			printf("ERRO: sem dispositivo Metal: %s (etapa: %s)\n", A01MTLLastError().UTF8String, A01MTLStep);
			dump_bridge_calls();
			return 1;
		}
		printf("dispositivo: %s\n", dev.name.UTF8String);
		id<MTLCommandQueue> q = [dev newCommandQueue];
		int failures = 0;

		/* TESTE 1 */
		STEP("TESTE 1 (copia de memoria)");
		alarm(A01_HANG_SECONDS);
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
		STEP("TESTE 2 (textura + render pass)");
		alarm(A01_HANG_SECONDS);
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
		STEP("TESTE 3 (shader simples)");
		alarm(A01_HANG_SECONDS);
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
		alarm(0);
		printf("=== resultado: %d de 3 testes com ERRO ===\n", failures);
		return failures;
	}
}
