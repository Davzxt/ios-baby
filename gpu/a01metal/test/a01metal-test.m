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
#include <pthread.h>
#include <stdarg.h>
#include <time.h>
#include <mach/mach.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <fcntl.h>
#include "tri_spv.h"   /* tri_vert_spv / tri_frag_spv, built from tri.vert / tri.frag */

/* ---- diagnostics ----
 * The kernel shows the first ~1 KB of autorun.out at the next boot. Output is not appended: the
 * file is rewritten as a whole (our lines + a status footer) on every line and once a second by a
 * watcher thread. So a run that is killed (SIGKILL, jetsam) or stuck inside a kernel call still
 * leaves its last state: step, seconds, memory footprint, last GE8100 bridge calls (the one in
 * progress included). Mesa's stderr goes through a pipe into the same text. */
#define A01_HANG_SECONDS 120

static char g_log[1400];
static size_t g_len;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static int g_out = STDOUT_FILENO;
static time_t g_t0;
static const char *volatile g_state = "rodando";
/* Live mode (boot without a5fb_noconsole, the GPU_DIAG package): the kernel text console stays on
 * screen, so every line also goes to /dev/console and the result is read in the same boot. */
static int g_console = -1;

static void
console_write(const char *s, size_t n)
{
	if (g_console >= 0 && n > 0) {
		write(g_console, s, n);
	}
}

static size_t
footprint_kb(void)
{
	task_vm_info_data_t vi;
	mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) != KERN_SUCCESS) {
		return 0;
	}
	return (size_t)(vi.phys_footprint / 1024);
}

static void
snapshot(const char *state, int locked)
{
	static char buf[2600];
	size_t n = 0;
	if (!locked) {
		pthread_mutex_lock(&g_mx);
	}
	/* status first: the boot report shows only the first ~1 KB */
	n += (size_t)snprintf(buf + n, sizeof(buf) - n, "[%s | etapa: %s | %ld s | mem %zu KB]\n", state, A01MTLStep,
	                      (long)(time(NULL) - g_t0), footprint_kb());
	void *drm = dlopen("/private/var/a01/lib/libdrm.2.dylib", RTLD_NOLOAD | RTLD_LAZY);
	void (*dump)(FILE *) = drm ? (void (*)(FILE *))dlsym(drm, "a01drm_trace_dump") : NULL;
	if (dump && n < sizeof(buf) - 1) {
		FILE *f = fmemopen(buf + n, sizeof(buf) - n, "w");
		if (f) {
			dump(f);
			fflush(f);
			n += (size_t)ftell(f);
			fclose(f);
		}
	}
	if (n + g_len < sizeof(buf)) {
		memcpy(buf + n, g_log, g_len);
		n += g_len;
	}
	/* The phone is usually reset by force (the HFS journal is replayed at the next boot), so
	 * the file must be on disk at every moment: always the same size, overwritten in place
	 * (NUL padding ends the text for the kernel's report) and fsync'd. Truncating and then
	 * writing left an empty file after a forced reset. */
	memset(buf + n, 0, sizeof(buf) - n);
	pwrite(g_out, buf, sizeof(buf), 0);
	fsync(g_out);
	if (!locked) {
		pthread_mutex_unlock(&g_mx);
	}
}

static void
report(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void
report(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	pthread_mutex_lock(&g_mx);
	char line[512];
	int k = vsnprintf(line, sizeof(line), fmt, ap);
	size_t len = k < 0 ? 0 : MIN((size_t)k, sizeof(line) - 1);
	console_write(line, len);
	if (len > 0 && g_len < sizeof(g_log) - 1) {
		size_t room = sizeof(g_log) - 1 - g_len;
		memcpy(g_log + g_len, line, MIN(len, room));
		g_len += MIN(len, room);
		g_log[g_len] = '\0';
	}
	snapshot(g_state, 1);
	pthread_mutex_unlock(&g_mx);
	va_end(ap);
}

static void *
watcher(void *arg)
{
	(void)arg;
	const char *last_step = NULL;
	for (unsigned t = 1;; t++) {
		sleep(1);
		snapshot(g_state, 0);
		/* live mode: the step whenever it changes, and the bridge calls every 10 s while stuck */
		if (g_console >= 0 && (A01MTLStep != last_step || t % 10 == 0)) {
			char s[200];
			int n = snprintf(s, sizeof(s), "A01METAL: [%s | etapa: %s | %ld s | mem %zu KB]\n", g_state, A01MTLStep,
			                 (long)(time(NULL) - g_t0), footprint_kb());
			console_write(s, n > 0 ? (size_t)MIN((size_t)n, sizeof(s) - 1) : 0);
			if (A01MTLStep == last_step) {
				void *drm = dlopen("/private/var/a01/lib/libdrm.2.dylib", RTLD_NOLOAD | RTLD_LAZY);
				void (*dump)(FILE *) = drm ? (void (*)(FILE *))dlsym(drm, "a01drm_trace_dump") : NULL;
				char d[600];
				FILE *f = dump ? fmemopen(d, sizeof(d), "w") : NULL;
				if (f) {
					dump(f);
					fflush(f);
					size_t dn = (size_t)ftell(f);
					fclose(f);
					console_write(d, MIN(dn, sizeof(d) - 1));
				}
			}
			last_step = A01MTLStep;
		}
	}
	return NULL;
}

static void *
stderr_reader(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char line[256];
	size_t len = 0;
	char c;
	while (read(fd, &c, 1) == 1) {
		if (len < sizeof(line) - 1) {
			line[len++] = c;
		}
		if (c == '\n') {
			line[len] = '\0';
			report("%s", line);
			len = 0;
		}
	}
	return NULL;
}

static void
crash_handler(int sig, siginfo_t *si, void *ctx)
{
	(void)ctx;
	char state[160];
	if (sig == SIGALRM) {
		snprintf(state, sizeof(state), "ERRO: TRAVOU %d s", A01_HANG_SECONDS);
	} else {
		snprintf(state, sizeof(state), "ERRO: CAIU sinal %d (%s) end %p", sig, strsignal(sig), si ? si->si_addr : NULL);
	}
	int locked = pthread_mutex_trylock(&g_mx) == 0;
	size_t bt0 = g_len;
	void *frames[10];
	int n = backtrace(frames, 10);
	for (int i = 2; i < n && g_len < sizeof(g_log) - 80; i++) {   /* skip this handler and the trampoline */
		Dl_info di;
		const char *lib = "?", *sym = "?";
		unsigned long off = (unsigned long)frames[i];
		if (dladdr(frames[i], &di) && di.dli_fname) {
			lib = strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname;
			off = (unsigned long)((char *)frames[i] - (char *)di.dli_fbase);
			sym = di.dli_sname ? di.dli_sname : "?";
		}
		g_len += (size_t)snprintf(g_log + g_len, sizeof(g_log) - g_len, " %s+0x%lx %s\n", lib, off, sym);
	}
	snapshot(state, 1);
	console_write("A01METAL: ", 10);
	console_write(state, strlen(state));
	console_write("\n", 1);
	console_write(g_log + bt0, g_len - bt0);   /* the backtrace */
	(void)locked;
	_exit(100 + sig);
}

/* One boot instead of two: launchd may start this job before the kernel has finished installing
 * a new A01 drop (the drop writes /private/var/a01/drop.txt last). Wait for that, and when this
 * binary was replaced during this boot, run the new one in place of this one. */
static void
wait_for_install(char **argv)
{
	struct timeval boot;
	size_t bl = sizeof(boot);
	if (getenv("A01_REEXEC") != NULL || sysctlbyname("kern.boottime", &boot, &bl, NULL, 0) != 0) {
		return;
	}
	for (int i = 0; i < 30; i++) {   /* up to 15 s; nothing is installed on most boots */
		struct stat d;
		if (stat("/private/var/a01/drop.txt", &d) == 0 && d.st_mtime >= boot.tv_sec) {
			struct stat self;
			sleep(1);   /* let the last file land */
			if (stat(argv[0], &self) == 0 && self.st_mtime >= boot.tv_sec) {
				setenv("A01_REEXEC", "1", 1);
				execv(argv[0], argv);
			}
			return;
		}
		usleep(500000);
	}
}

static void
install_diagnostics(void)
{
	g_t0 = time(NULL);
	char args[1024] = "";
	size_t al = sizeof(args) - 1;
	if (sysctlbyname("kern.bootargs", args, &al, NULL, 0) == 0 && strstr(args, "a5fb_noconsole=1") == NULL) {
		g_console = open("/dev/console", O_WRONLY | O_NOCTTY);
	}
	ftruncate(g_out, 0);   /* once: drop earlier runs; every later write is in place + fsync */
	int p[2];
	if (pipe(p) == 0) {
		dup2(p[1], STDERR_FILENO);
		pthread_t t;
		pthread_create(&t, NULL, stderr_reader, (void *)(intptr_t)p[0]);
	}
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = crash_handler;
	sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
	int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS, SIGALRM };
	for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
		sigaction(sigs[i], &sa, NULL);
	}
	pthread_t w;
	pthread_create(&w, NULL, watcher, NULL);
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

/* live mode: the result was on screen in this boot, so the next boot has nothing to report and
 * skips the kernel's 15 s report pause */
static void
clear_reports(void)
{
	if (g_console >= 0) {
		sleep(20);   /* time to read / photograph the result */
		unlink("/private/var/herolte/autorun.out");
		unlink("/private/var/a01/drop.txt");
	}
}

int main(int argc, char **argv)
{
	(void)argc;
	@autoreleasepool {
		wait_for_install(argv);
		install_diagnostics();
		report("=== A01Metal: testes da GPU (Metal -> Vulkan -> DDK -> GE8100) ===\n");
		id<MTLDevice> dev = A01MTLCreateSystemDefaultDevice();
		if (!dev) {
			report("ERRO: sem dispositivo Metal: %s\n", A01MTLLastError().UTF8String);
			g_state = "fim com ERRO";
			snapshot(g_state, 0);
			clear_reports();
			return 1;
		}
		report("dispositivo: %s\n", dev.name.UTF8String);
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
			report("TESTE 1 (copia de memoria): %s (status %ld, %u bytes errados%s%s)\n", ok ? "OK" : "ERRO",
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
				report("TESTE 2 (textura + render pass): ERRO (textura ou buffer nao criados)\n");
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
					report("TESTE 2 (textura + render pass): ERRO (%s)\n", cb.error.localizedDescription.UTF8String);
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
					report("TESTE 2 (textura + render pass): %s (status %ld, %u pixels errados, pixel 0 = %u,%u,%u,%u)\n",
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
				report("TESTE 3 (shader simples): ERRO (%s)\n", e ? e.localizedDescription.UTF8String : "textura ou buffer nao criados");
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
				report("TESTE 3 (shader simples): %s (status %ld, %u pixels errados, pixel central = %u,%u,%u,%u)\n",
				       ok ? "OK" : "ERRO", (long)cb.status, bad, p[4 * (32 * 64 + 32)], p[4 * (32 * 64 + 32) + 1],
				       p[4 * (32 * 64 + 32) + 2], p[4 * (32 * 64 + 32) + 3]);
				failures += !ok;
			}
		}
		alarm(0);
		g_state = failures ? "fim com ERRO" : "fim OK";
		report("=== resultado: %d de 3 testes com ERRO ===\n", failures);
		clear_reports();
		return failures;
	}
}
