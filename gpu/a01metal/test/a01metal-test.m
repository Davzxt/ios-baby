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
#include <mach-o/dyld.h>
#include <sys/ucontext.h>
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
/* Where the main thread is, sampled by the watcher (pc, lr and the frame-pointer chain): shows
 * where a run is stuck when it makes no more bridge calls. */
static mach_port_t g_main_thread = MACH_PORT_NULL;
static char g_where[420];
static char g_mesa[160] = "-";   /* the last Mesa log line (its stderr), for the verdict */
static char g_err[160] = "";     /* A01Metal's error, for the verdict */
static char g_code[140] = "?";   /* short "lib+offset" of the innermost GPU-stack frame, easy to type */
static void refresh_images(void);

static size_t
where_frame(char *s, size_t room, uintptr_t a)
{
	Dl_info di;
	if (a != 0 && dladdr((void *)a, &di) && di.dli_fname) {
		const char *lib = strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname;
		int n = snprintf(s, room, " %s+0x%lx", lib, (unsigned long)(a - (uintptr_t)di.dli_fbase));
		return n < 0 ? 0 : MIN((size_t)n, room - 1);
	}
	int n = snprintf(s, room, " %#lx", (unsigned long)a);
	return n < 0 ? 0 : MIN((size_t)n, room - 1);
}

static void
sample_main_thread(void)
{
	if (g_main_thread == MACH_PORT_NULL || thread_suspend(g_main_thread) != KERN_SUCCESS) {
		return;
	}
	/* only raw addresses while it is suspended: it may hold dyld's or malloc's lock */
	uintptr_t a[8];
	int na = 0;
	arm_thread_state64_t ts;
	mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
	if (thread_get_state(g_main_thread, ARM_THREAD_STATE64, (thread_state_t)&ts, &cnt) == KERN_SUCCESS) {
		a[na++] = (uintptr_t)arm_thread_state64_get_pc(ts);
		a[na++] = (uintptr_t)arm_thread_state64_get_lr(ts);
		uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(ts);
		while (na < 8 && fp != 0 && (fp & 7) == 0) {
			const uintptr_t *f = (const uintptr_t *)fp;   /* {previous fp, return address} */
			a[na++] = f[1];
			if (f[0] <= fp) {
				break;
			}
			fp = f[0];
		}
	}
	thread_resume(g_main_thread);
	char s[sizeof(g_where)];
	size_t n = (size_t)snprintf(s, sizeof(s), "onde:");
	/* CODIGO: where the CPU is (pc) and the innermost GPU-stack frame, e.g.
	 * "libsystem_malloc+0x1a2b / libvulkan_powervr+0x188604" */
	char pcf[64] = "", gpuf[64] = "";
	for (int i = 0; i < na && n < sizeof(s) - 40; i++) {
		size_t k = where_frame(s + n, sizeof(s) - n, a[i]);
		char *f = i == 0 ? pcf : (gpuf[0] == '\0' && (strstr(s + n, "vulkan") || strstr(s + n, "A01Metal") ||
		                                               strstr(s + n, "drm"))) ? gpuf : NULL;
		if (f != NULL) {
			snprintf(f, 64, "%s", s + n + 1);   /* skip the leading space */
			char *dot = strstr(f, ".dylib");
			if (dot) {
				memmove(dot, dot + 6, strlen(dot + 6) + 1);
			}
		}
		n += k;
	}
	snprintf(g_code, sizeof(g_code), "%s%s%s", pcf, gpuf[0] && strcmp(pcf, gpuf) ? " / " : "",
	         strcmp(pcf, gpuf) ? gpuf : "");
	snprintf(s + n, sizeof(s) - n, "\n");
	memcpy(g_where, s, sizeof(g_where));
}

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
	/* MACH_TASK_BASIC_INFO: TASK_VM_INFO's count from the 18.5 SDK is larger than this kernel's,
	 * which logged a warning on the console every second */
	mach_task_basic_info_data_t bi;
	mach_msg_type_number_t n = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&bi, &n) != KERN_SUCCESS) {
		return 0;
	}
	return (size_t)(bi.resident_size / 1024);
}

static void
snapshot(const char *state, int locked)
{
	static char buf[2600];
	size_t n = 0;
	if (!locked) {
		pthread_mutex_lock(&g_mx);
	}
	/* the verdict first, as one line to read off the screen at the next boot's report (which shows
	 * only the first ~1 KB); the details follow */
	if (strncmp(state, "fim OK", 6) == 0) {
		n += (size_t)snprintf(buf + n, sizeof(buf) - n, "A01METAL: >>> RESULTADO: FUNCIONOU (3 de 3 testes OK) <<<\n");
	} else if (strncmp(state, "fim", 3) == 0 || strncmp(state, "ERRO", 4) == 0) {
		/* the first kernel call that answered with an error (a01drm), the most useful clue */
		void *drm1 = dlopen("/private/var/a01/lib/libdrm.2.dylib", RTLD_NOLOAD | RTLD_LAZY);
		const char *(*first)(void) = drm1 ? (const char *(*)(void))dlsym(drm1, "a01drm_first_error") : NULL;
		const char *fe = first ? first() : NULL;
		n += (size_t)snprintf(buf + n, sizeof(buf) - n,
		                      "A01METAL: >>> RESULTADO: FALHOU (%s) em \"%s\": %s. KERNEL: %s. MESA: %s. CODIGO: %s <<<\n",
		                      state, A01MTLStep, g_err[0] ? g_err : "?", fe && fe[0] ? fe : "-", g_mesa, g_code);
	} else {
		n += (size_t)snprintf(buf + n, sizeof(buf) - n, "A01METAL: >>> PAROU em \"%s\" depois de %ld s. CODIGO: %s <<<\n",
		                      A01MTLStep, (long)(time(NULL) - g_t0), g_code);
	}
	n += (size_t)snprintf(buf + n, sizeof(buf) - n, "[%s | etapa: %s | %ld s | mem %zu KB]\n%s", state, A01MTLStep,
	                      (long)(time(NULL) - g_t0), footprint_kb(), g_where);
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
	time_t step_since = time(NULL);
	for (unsigned t = 1;; t++) {
		/* the line to read off the screen when it is stuck */
		if (g_console >= 0 && A01MTLStep == last_step && time(NULL) - step_since >= 30 && t % 10 == 0) {
			char s[200];
			int n = snprintf(s, sizeof(s), "A01METAL: >>> TRAVADO em \"%s\" ha %ld s. CODIGO: %s <<<\n", A01MTLStep,
			                 (long)(time(NULL) - step_since), g_code);
			console_write(s, n > 0 ? (size_t)MIN((size_t)n, sizeof(s) - 1) : 0);
		}
		if (A01MTLStep != last_step) {
			step_since = time(NULL);
		}
		sleep(1);
		if (t % 5 == 0) {
			refresh_images();
			sample_main_thread();
		}
		snapshot(g_state, 0);
		/* live mode: the step whenever it changes, and the bridge calls every 10 s while stuck */
		if (g_console >= 0 && (A01MTLStep != last_step || t % 10 == 0)) {
			char s[200];
			int n = snprintf(s, sizeof(s), "A01METAL: [%s | etapa: %s | %ld s | mem %zu KB]\n", g_state, A01MTLStep,
			                 (long)(time(NULL) - g_t0), footprint_kb());
			console_write(s, n > 0 ? (size_t)MIN((size_t)n, sizeof(s) - 1) : 0);
			if (A01MTLStep == last_step) {
				console_write(g_where, strnlen(g_where, sizeof(g_where)));
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
			snprintf(g_mesa, sizeof(g_mesa), "%s", line);
			char *eol = strchr(g_mesa, '\n');
			if (eol) {
				*eol = '\0';
			}
			report("%s", line);
			len = 0;
		}
	}
	return NULL;
}

/* Loaded images (base, short name), refreshed by the watcher: the crash handler maps addresses to
 * lib+offset without dladdr, which takes dyld's lock. */
#define A01_IMAGES 640
static struct { uintptr_t base; const char *name; } g_img[A01_IMAGES];
static volatile unsigned g_nimg;

static void
refresh_images(void)
{
	uint32_t n = _dyld_image_count();
	unsigned k = 0;
	for (uint32_t i = 0; i < n && k < A01_IMAGES; i++) {
		const char *p = _dyld_get_image_name(i);
		const struct mach_header *h = _dyld_get_image_header(i);
		if (p == NULL || h == NULL) {
			continue;
		}
		const char *s = strrchr(p, '/');
		g_img[k].base = (uintptr_t)h;
		g_img[k].name = s ? s + 1 : p;
		k++;
	}
	g_nimg = k;
}

/* async-signal-safe text building: no malloc, no locks */
static size_t
put_str(char *b, size_t at, size_t cap, const char *s)
{
	while (*s && at + 1 < cap) {
		b[at++] = *s++;
	}
	b[at] = '\0';
	return at;
}

static size_t
put_hex(char *b, size_t at, size_t cap, uintptr_t v)
{
	char t[20];
	int n = 0;
	do {
		t[n++] = "0123456789abcdef"[v & 15];
		v >>= 4;
	} while (v && n < 16);
	at = put_str(b, at, cap, "0x");
	while (n > 0 && at + 1 < cap) {
		b[at++] = t[--n];
	}
	b[at] = '\0';
	return at;
}

static size_t
put_addr(char *b, size_t at, size_t cap, uintptr_t a)
{
	unsigned best = A01_IMAGES;
	for (unsigned i = 0; i < g_nimg; i++) {
		if (g_img[i].base <= a && (best == A01_IMAGES || g_img[i].base > g_img[best].base)) {
			best = i;
		}
	}
	if (best == A01_IMAGES) {
		return put_hex(b, at, cap, a);
	}
	const char *nm = g_img[best].name;
	while (*nm && *nm != '.' && at + 1 < cap) {   /* "libvulkan_powervr.dylib" -> "libvulkan_powervr" */
		b[at++] = *nm++;
	}
	b[at] = '\0';
	at = put_str(b, at, cap, "+");
	return put_hex(b, at, cap, a - g_img[best].base);
}

static void
crash_handler(int sig, siginfo_t *si, void *ctx)
{
	/* Only async-signal-safe work: a crash inside malloc (the last one was stuck in free()) must
	 * not deadlock here. The verdict line goes in place at the top of autorun.out (fsync'd) and to
	 * the console; the kernel shows it live (0328) and at the next boot. */
	static char line[600];
	size_t n = 0;
	n = put_str(line, n, sizeof(line), "A01METAL: >>> RESULTADO: FALHOU - ");
	if (sig == SIGALRM) {
		n = put_str(line, n, sizeof(line), "TRAVOU 120 s");
	} else {
		n = put_str(line, n, sizeof(line), "CAIU sinal ");
		n = put_hex(line, n, sizeof(line), (uintptr_t)sig);
		n = put_str(line, n, sizeof(line), " end ");
		n = put_hex(line, n, sizeof(line), si ? (uintptr_t)si->si_addr : 0);
	}
	n = put_str(line, n, sizeof(line), " em \"");
	n = put_str(line, n, sizeof(line), A01MTLStep);
	n = put_str(line, n, sizeof(line), "\". CODIGO: ");
	ucontext_t *uc = ctx;
	if (sig != SIGALRM && uc != NULL && uc->uc_mcontext != NULL) {
		n = put_str(line, n, sizeof(line), "pc=");
		n = put_addr(line, n, sizeof(line), (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
		n = put_str(line, n, sizeof(line), " lr=");
		n = put_addr(line, n, sizeof(line), (uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
	} else {
		n = put_str(line, n, sizeof(line), g_code);
	}
	n = put_str(line, n, sizeof(line), " <<<\n");
	/* the verdict replaces the first line; NUL-padding ends the text for the kernel's report */
	static char pad[64];
	pwrite(g_out, line, n, 0);
	pwrite(g_out, pad, sizeof(pad), (off_t)n);
	fsync(g_out);
	console_write(line, n);
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

/* The tests build their descriptors from these plain classes instead of Metal.framework's: on the
 * phone, creating MTLTextureDescriptor / MTLRenderPassDescriptor blocked inside Metal.framework
 * (mach_msg, TESTE 2 hung for 120 s) while no system Metal device exists (GPU_DIAG). A01Metal
 * only reads these properties. */
@interface A01TexDesc : NSObject
@property (nonatomic) NSUInteger width, height;
@property (nonatomic) MTLPixelFormat pixelFormat;
@property (nonatomic) MTLTextureUsage usage;
@end
@implementation A01TexDesc
@end
@interface A01ColorAttachment : NSObject
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic) MTLLoadAction loadAction;
@property (nonatomic) MTLStoreAction storeAction;
@property (nonatomic) MTLClearColor clearColor;
@property (nonatomic) MTLPixelFormat pixelFormat;
@end
@implementation A01ColorAttachment
@end
@interface A01PassDesc : NSObject
@property (nonatomic, strong) NSArray<A01ColorAttachment *> *colorAttachments;
@end
@implementation A01PassDesc
@end
@interface A01PipeDesc : NSObject
@property (nonatomic, strong) id<MTLFunction> vertexFunction, fragmentFunction;
@property (nonatomic, strong) NSArray<A01ColorAttachment *> *colorAttachments;
@end
@implementation A01PipeDesc
@end

static A01TexDesc *
tex64(void)
{
	A01TexDesc *d = [A01TexDesc new];
	d.width = 64;
	d.height = 64;
	d.pixelFormat = MTLPixelFormatRGBA8Unorm;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	return d;
}

static A01PassDesc *
pass_clear(id<MTLTexture> t, double r, double g, double b)
{
	A01ColorAttachment *ca = [A01ColorAttachment new];
	ca.texture = t;
	ca.loadAction = MTLLoadActionClear;
	ca.storeAction = MTLStoreActionStore;
	ca.clearColor = MTLClearColorMake(r, g, b, 1);
	A01PassDesc *d = [A01PassDesc new];
	d.colorAttachments = @[ ca ];
	return d;
}

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

int main(int argc, char **argv)
{
	(void)argc;
	@autoreleasepool {
		wait_for_install(argv);
		/* The driver compiles its internal shaders in vkCreateDevice; without NDEBUG Mesa validates
		 * the whole shader after every NIR pass, many times slower on the single A53 (sampled in
		 * nir_opt_dead_write_vars). */
		setenv("NIR_DEBUG", "novalidate", 0);
		g_main_thread = mach_thread_self();
		install_diagnostics();
		report("=== A01Metal: testes da GPU (Metal -> Vulkan -> DDK -> GE8100) ===\n");
		id<MTLDevice> dev = A01MTLCreateSystemDefaultDevice();
		if (!dev) {
			report("ERRO: sem dispositivo Metal: %s\n", A01MTLLastError().UTF8String);
			snprintf(g_err, sizeof(g_err), "%s", A01MTLLastError().UTF8String);
			report("A01METAL: >>> RESULTADO: FALHOU ao criar a GPU (%s) <<<\n", A01MTLLastError().UTF8String);
			g_state = "fim com ERRO";
			snapshot(g_state, 0);
			return 1;   /* keep the report: it is shown at the next boot */
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
			const volatile uint8_t *p = b.contents, *pa = a.contents;
			unsigned bad = 0, bad_a = 0;
			for (unsigned i = 0; i < 4096; i++) bad += p[i] != 0x5a;
			int ok = cb.status == MTLCommandBufferStatusCompleted && !bad;
			report("TESTE 1 (copia de memoria): %s (status %ld, %u bytes errados%s%s)\n", ok ? "OK" : "ERRO",
			       (long)cb.status, bad, cb.error ? ", " : "", cb.error ? cb.error.localizedDescription.UTF8String : "");
			if (bad) {
				/* which part failed: the fill of a (GPU never ran), the copy, or only the timing */
				for (unsigned i = 0; i < 4096; i++) bad_a += pa[i] != 0x5a;
				sleep(3);
				unsigned bad_late = 0;
				for (unsigned i = 0; i < 4096; i++) bad_late += p[i] != 0x5a;
				void *drm1 = dlopen("/private/var/a01/lib/libdrm.2.dylib", RTLD_NOLOAD | RTLD_LAZY);
				const char *(*first)(void) = drm1 ? (const char *(*)(void))dlsym(drm1, "a01drm_first_error") : NULL;
				const char *fe = first ? first() : NULL;
				report("  detalhe: origem com %u bytes errados (a[0]=%02x), destino b[0]=%02x; 3 s depois: %u errados; "
				       "KERNEL: %s\n", bad_a, pa[0], p[0], bad_late, fe && fe[0] ? fe : "-");
			}
			failures += !ok;
		}
		pause_between();

		/* TESTE 2 */
		STEP("TESTE 2 (textura + render pass)");
		alarm(A01_HANG_SECONDS);
		{
			MTLTextureDescriptor *td = (MTLTextureDescriptor *)tex64();
			id<MTLTexture> t = [dev newTextureWithDescriptor:td];
			id<MTLBuffer> out = [dev newBufferWithLength:64 * 64 * 4 options:MTLResourceStorageModeShared];
			if (!t || !out) {
				report("TESTE 2 (textura + render pass): ERRO (textura ou buffer nao criados)\n");
				failures++;
			} else {
				memset(out.contents, 0, 64 * 64 * 4);
				MTLRenderPassDescriptor *rp = (MTLRenderPassDescriptor *)pass_clear(t, 1, 0, 0);
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
			A01PipeDesc *pd = [A01PipeDesc new];
			pd.vertexFunction = [vl newFunctionWithName:@"main"];
			pd.fragmentFunction = [fl newFunctionWithName:@"main"];
			A01ColorAttachment *pca = [A01ColorAttachment new];
			pca.pixelFormat = MTLPixelFormatRGBA8Unorm;
			pd.colorAttachments = @[ pca ];
			id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)pd error:&e];
			MTLTextureDescriptor *td = (MTLTextureDescriptor *)tex64();
			id<MTLTexture> t = [dev newTextureWithDescriptor:td];
			id<MTLBuffer> out = [dev newBufferWithLength:64 * 64 * 4 options:MTLResourceStorageModeShared];
			if (!ps || !t || !out) {
				report("TESTE 3 (shader simples): ERRO (%s)\n", e ? e.localizedDescription.UTF8String : "textura ou buffer nao criados");
				failures++;
			} else {
				memset(out.contents, 0, 64 * 64 * 4);
				MTLRenderPassDescriptor *rp = (MTLRenderPassDescriptor *)pass_clear(t, 0, 0, 0);
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
		if (failures == 0) {
			report("A01METAL: >>> RESULTADO: FUNCIONOU (3 de 3 testes OK) <<<\n");
		} else {
			report("A01METAL: >>> RESULTADO: FALHOU (%d de 3 testes com ERRO, veja as linhas TESTE acima) <<<\n", failures);
		}
		return failures;   /* the report stays: the next boot shows the verdict line first */
	}
}
