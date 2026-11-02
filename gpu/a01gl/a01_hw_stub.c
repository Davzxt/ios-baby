/*
 * Galaxy A01 Core: the OSMesaSweet* entry points (gpu/mesa/osmesa_hero.inc) call these HeroGPU
 * hooks. The A01 has no Panfrost screen, so there is no hardware blit into IOSurfaces: every hook
 * answers "inactive" and the EAGL shim takes its glReadPixels + CPU copy path. Rendering itself
 * runs on the Gallium driver GALLIUM_DRIVER names (softpipe, or zink over the GE8100 Vulkan
 * driver), set by the kernel for backboardd (bsd/dev/herolte_gl.c, boot-arg a01gl).
 */
#include <stddef.h>
#include <stdint.h>

struct pipe_resource;

/* the declarations osmesa_hero.inc uses (Mesa builds with -Werror=missing-prototypes) */
int hero_hw_active(void);
struct pipe_resource *hero_hw_surface_resource(uint32_t surface_id, int opaque, unsigned *w, unsigned *h);
void hero_hw_surface_sync(uint32_t surface_id);
void hero_hw_surface_forget(uint32_t surface_id);

int hero_hw_active(void) { return 0; }

struct pipe_resource *
hero_hw_surface_resource(uint32_t surface_id, int opaque, unsigned *w, unsigned *h)
{
	(void)surface_id; (void)opaque; (void)w; (void)h;
	return NULL;
}

void hero_hw_surface_sync(uint32_t surface_id) { (void)surface_id; }
void hero_hw_surface_forget(uint32_t surface_id) { (void)surface_id; }
