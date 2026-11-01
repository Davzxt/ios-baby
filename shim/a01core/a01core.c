/* SPDX-License-Identifier: GPL-2.0-only
 * Galaxy A01 Core (SM-A013F/G/M, MediaTek MT6739) loader for 4 KiB XNU.
 * Payload handling and boot_args follow shim/herolte/xnu_boot.c
 * (mkpayload.py version 1); everything MediaTek is new and NOT YET RUN ON
 * THE PHONE.
 *
 * Two modes:
 *  - PROBE (no SWEETXNU payload appended): stop the LK watchdog, then show
 *    on the screen what the A01CORE port must be configured with: entry
 *    EL, the RAM and reserved-memory map LK passed, the framebuffer address
 *    from /chosen and what DISP_OVL0 actually scans out (address, pitch,
 *    format), and whether the default XNU window collides with anything.
 *    Then it waits; hold Power + Volume Down to reboot.
 *  - BOOT: the same checks, then copy XNU, the ADT and boot_args into the
 *    payload's RAM window and jump. It refuses (and says why on the screen)
 *    when the window, the scaled iOS surface or the framebuffer overlap a
 *    reserved range or each other.
 * Every line drawn is also appended as ASCII to a page in Samsung's
 * sec-log carve-out (0x4b100200), for /proc/last_kmsg in a recovery.
 */
#include <stdint.h>
#include "../font.h"

#define LOG_PA          0x4b100000UL   /* binary slots +0..0xff, XNU marker +0x100 */
#define LOG_TEXT_OFF    0x200UL
#define PAGE            4096UL

#define TOPRGU_PA       0x10007000UL   /* MTK watchdog (Linux mtk_wdt.c) */
#define WDT_MODE        0x00U
#define WDT_MODE_EN     0x1U
#define WDT_MODE_KEY    0x22000000U
#define WDT_SWRST       0x14U
#define WDT_SWRST_KEY   0x1209U        /* Linux mtk_wdt.c */

#define OVL0_PA         0x1400a000UL   /* DISP_OVL0 (Linux mtk_disp_ovl.c) */
#define OVL_SRC_CON     0x2cU
#define OVL_CON(n)      (0x30U + 0x20U * (n))
#define OVL_SRC_SIZE(n) (0x38U + 0x20U * (n))
#define OVL_PITCH(n)    (0x44U + 0x20U * (n))
#define OVL_ADDR(n)     (0xf40U + 0x20U * (n))

#define FB_W            720U
#define FB_H            1480U   /* measured: OVL0 720x1480 */
#define TEXT_SCALE      2U
#define CELL_W          (8U * TEXT_SCALE)
#define CELL_H          (16U * TEXT_SCALE)
#define COLS            (FB_W / CELL_W)
#define ROWS            (FB_H / CELL_H)

/* Defaults that the kernel build and mkadt_a01core.py also use. */
#define DEFAULT_RAM_BASE   0x80000000UL   /* free on the 2 GB A01 Core (probe 2026-11-01) */
#define DEFAULT_RAM_SIZE   0x1ff00000UL
#define SURFACE_PA         0xa0000000UL   /* A01CORE_SCALED_SURFACE_PA */
#define SURFACE_SIZE       0x01000000UL   /* 828x1792x4 rounded up */
/* Where the A01CORE kernel was compiled to draw (pexpert A5XELTE.h A01CORE_FB_PA /
 * A01CORE_FB_STRIDE). Build both with the same values; these are the defaults. */
#ifndef A01CORE_FB_PA
#define A01CORE_FB_PA      0x76740000UL
#endif
#ifndef A01CORE_FB_STRIDE
#define A01CORE_FB_STRIDE  2944U
#endif

#define BOOT_LINE_LENGTH 608
#define MAX_RANGES       48

/* ---- freestanding helpers (the compiler may call memcpy/memset) ---- */
void *memcpy(void *d, const void *s, __SIZE_TYPE__ n);
void *memset(void *d, int c, __SIZE_TYPE__ n);
void *memcpy(void *d, const void *s, __SIZE_TYPE__ n)
{
    volatile uint8_t *dd = d;
    const volatile uint8_t *ss = s;
    while (n--)
        *dd++ = *ss++;
    return d;
}
void *memset(void *d, int c, __SIZE_TYPE__ n)
{
    volatile uint8_t *dd = d;
    while (n--)
        *dd++ = (uint8_t)c;
    return d;
}

static inline uint32_t mmio_rd(uintptr_t a)
{
    return *(volatile uint32_t *)a;
}
static inline void mmio_wr(uintptr_t a, uint32_t v)
{
    *(volatile uint32_t *)a = v;
#ifndef A01_HOST_TEST
    __asm__ volatile("dsb sy" ::: "memory");
#endif
}

static void clean_range(uintptr_t start, uintptr_t end)
{
#ifdef A01_HOST_TEST
    (void)start;
    (void)end;
    return;
#endif
    uint64_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    uintptr_t line = 4UL << ((ctr >> 16) & 0xf);
    for (uintptr_t p = start & ~(line - 1); p < end; p += line)
        __asm__ volatile("dc civac, %0" ::"r"(p) : "memory");
    __asm__ volatile("dsb sy" ::: "memory");
}

/* ---- screen + log ---- */
static uintptr_t fb_base;
static uint32_t fb_stride = 736U * 4U, fb_bpp = 32;
static int fb_layer = -1;
static unsigned row_next;
static uintptr_t log_text = LOG_PA + LOG_TEXT_OFF;

static void put_px(unsigned x, unsigned y, uint32_t rgb)
{
    if (!fb_base)
        return;
    uintptr_t row = fb_base + (uintptr_t)y * fb_stride;
    if (fb_bpp == 16) {
        uint16_t v = (uint16_t)(((rgb >> 8) & 0xf800) | ((rgb >> 5) & 0x07e0) | ((rgb >> 3) & 0x1f));
        *(volatile uint16_t *)(row + x * 2U) = v;
    } else {
        *(volatile uint32_t *)(row + x * 4U) = 0xff000000U | rgb;
    }
}

static void draw_char(unsigned col, unsigned row, char ch, uint32_t color)
{
    if (!fb_base || col >= COLS || row >= ROWS)
        return;
    unsigned idx = (ch >= 32 && ch <= 126) ? (unsigned)(ch - 32) : (unsigned)('?' - 32);
    for (unsigned gy = 0; gy < 16; gy++) {
        uint8_t bits = font8x16[idx][gy];
        for (unsigned gx = 0; gx < 8; gx++) {
            uint32_t c = (bits & (0x80U >> gx)) ? color : 0;
            for (unsigned sy = 0; sy < TEXT_SCALE; sy++)
                for (unsigned sx = 0; sx < TEXT_SCALE; sx++)
                    put_px(col * CELL_W + gx * TEXT_SCALE + sx,
                           row * CELL_H + gy * TEXT_SCALE + sy, c);
        }
    }
}

static void log_char(char c)
{
    if (log_text < LOG_PA + PAGE - 1) {
        *(volatile char *)log_text = c;
        log_text++;
    }
}

/* A line under construction: text is drawn and logged on line_end(). */
static char line[64];
static unsigned line_len;

static void s(const char *str)
{
    while (*str && line_len < sizeof(line) - 1)
        line[line_len++] = *str++;
}

static void hex(uint64_t v)
{
    char buf[19];
    unsigned n = 0;
    buf[n++] = '0';
    buf[n++] = 'x';
    int started = 0;
    for (int shift = 60; shift >= 0; shift -= 4) {
        unsigned d = (unsigned)(v >> shift) & 0xf;
        if (d || started || shift == 0) {
            buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
            started = 1;
        }
    }
    buf[n] = 0;
    s(buf);
}

static void dec(uint64_t v)
{
    char buf[21];
    int n = 20;
    buf[n] = 0;
    do {
        buf[--n] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    s(&buf[n]);
}

static void line_end(uint32_t color)
{
    line[line_len] = 0;
    unsigned row = row_next++ % ROWS;
    for (unsigned c = 0; c < COLS; c++)
        draw_char(c, row, c < line_len ? line[c] : ' ', color);
    for (unsigned i = 0; i < line_len; i++)
        log_char(line[i]);
    log_char('\n');
    line_len = 0;
}

#define WHITE  0xffffffU
#define GREEN  0x40ff40U
#define YELLOW 0xffff40U
#define RED    0xff4040U

/* ---- flattened device tree ---- */
#define FDT_MAGIC 0xd00dfeedU
#define FDT_BEGIN_NODE 1U
#define FDT_END_NODE 2U
#define FDT_PROP 3U
#define FDT_NOP 4U
#define FDT_END 9U

static uint32_t be32(uintptr_t a)
{
    return __builtin_bswap32(*(volatile uint32_t *)a);
}
static uint64_t be64(uintptr_t a)
{
    return ((uint64_t)be32(a) << 32) | be32(a + 4);
}

static int prefix(const char *str, const char *pre)
{
    while (*pre)
        if (*str++ != *pre++)
            return 0;
    return 1;
}
static int streq(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return *a == *b;
}

struct range {
    uint64_t base, size;
};
static struct range mem[8], rsv[MAX_RANGES];
static unsigned nmem, nrsv;
static uint64_t fb_fdt, vram_size, initrd_start, initrd_end;
static int have_fb_l;
static char lcm_name[48];

static void add(struct range *r, unsigned *n, unsigned max, uint64_t base, uint64_t size)
{
    if (*n < max && size) {
        r[*n].base = base;
        r[*n].size = size;
        (*n)++;
    }
}

static uint64_t prop_num(uintptr_t v, uint32_t len)
{
    return len >= 8 ? be64(v) : (len >= 4 ? be32(v) : 0);
}

/* Walk the tree once; root and /reserved-memory use 2 address and 2 size
 * cells in the A01 Core DTB. */
static int fdt_scan(uintptr_t fdt)
{
    if (!fdt || (fdt & 3) || be32(fdt) != FDT_MAGIC)
        return 0;
    uintptr_t st = fdt + be32(fdt + 8), strs = fdt + be32(fdt + 12);
    uintptr_t rsvmap = fdt + be32(fdt + 16);
    for (unsigned i = 0; i < 64; i++, rsvmap += 16) {
        uint64_t b = be64(rsvmap), z = be64(rsvmap + 8);
        if (!b && !z)
            break;
        add(rsv, &nrsv, MAX_RANGES, b, z);
    }
    int depth = 0;
    int in_mem = 0, in_rsv = 0, in_chosen = 0;
    uintptr_t p = st;
    for (unsigned guard = 0; guard < 400000; guard++) {
        uint32_t tok = be32(p);
        p += 4;
        if (tok == FDT_BEGIN_NODE) {
            const char *name = (const char *)p;
            depth++;
            if (depth == 2) {
                in_mem = prefix(name, "memory");
                in_rsv = prefix(name, "reserved-memory");
                in_chosen = streq(name, "chosen");
            }
            while (*(volatile char *)p)
                p++;
            p = (p + 4) & ~(uintptr_t)3;
        } else if (tok == FDT_END_NODE) {
            if (depth == 2)
                in_mem = in_rsv = in_chosen = 0;
            depth--;
        } else if (tok == FDT_PROP) {
            uint32_t len = be32(p), nameoff = be32(p + 4);
            uintptr_t val = p + 8;
            const char *pname = (const char *)(strs + nameoff);
            if (streq(pname, "reg") && ((in_mem && depth == 2) || (in_rsv && depth == 3))) {
                for (uint32_t o = 0; o + 16 <= len; o += 16) {
                    if (in_mem)
                        add(mem, &nmem, 8, be64(val + o), be64(val + o + 8));
                    else
                        add(rsv, &nrsv, MAX_RANGES, be64(val + o), be64(val + o + 8));
                }
            } else if (in_chosen && depth == 2) {
                if (streq(pname, "atag,videolfb-fb_base_l") && len >= 4) {
                    fb_fdt |= be32(val);
                    have_fb_l = 1;
                } else if (streq(pname, "atag,videolfb-fb_base_h") && len >= 4) {
                    fb_fdt |= (uint64_t)be32(val) << 32;
                } else if (streq(pname, "atag,videolfb-vramSize") && len >= 4) {
                    vram_size = be32(val);
                } else if (streq(pname, "atag,videolfb-lcmname")) {
                    for (uint32_t i = 0; i < len && i < sizeof(lcm_name) - 1; i++)
                        lcm_name[i] = *(volatile char *)(val + i);
                } else if (streq(pname, "linux,initrd-start")) {
                    initrd_start = prop_num(val, len);
                } else if (streq(pname, "linux,initrd-end")) {
                    initrd_end = prop_num(val, len);
                }
            }
            p = (val + len + 3) & ~(uintptr_t)3;
        } else if (tok == FDT_NOP) {
            continue;
        } else {
            return tok == FDT_END;
        }
    }
    return 0;
}

static int overlaps(uint64_t a, uint64_t as, uint64_t b, uint64_t bs)
{
    return a < b + bs && b < a + as;
}

/* Returns the index of a reserved range overlapping [base, base+size), or -1. */
static int first_conflict(uint64_t base, uint64_t size)
{
    for (unsigned i = 0; i < nrsv; i++)
        if (overlaps(base, size, rsv[i].base, rsv[i].size))
            return (int)i;
    return -1;
}

static int inside_dram(uint64_t base, uint64_t size)
{
    for (unsigned i = 0; i < nmem; i++)
        if (base >= mem[i].base && base + size <= mem[i].base + mem[i].size)
            return 1;
    return 0;
}

/* Report one region; returns 1 if it is usable. */
static int check_region(const char *what, uint64_t base, uint64_t size)
{
    int c = first_conflict(base, size);
    int ok = c < 0 && inside_dram(base, size) &&
             !(fb_base && overlaps(base, size, fb_base, (uint64_t)fb_stride * FB_H));
    s(what);
    s(" ");
    hex(base);
    s("+");
    hex(size);
    if (ok) {
        s(" OK");
        line_end(GREEN);
        return 1;
    }
    if (c >= 0) {
        s(" HITS ");
        hex(rsv[c].base);
    } else if (!inside_dram(base, size)) {
        s(" NOT IN DRAM");
    } else {
        s(" HITS FB");
    }
    line_end(RED);
    return 0;
}

/* ---- framebuffer discovery ---- */
static void find_framebuffer(void)
{
    uint32_t src = mmio_rd(OVL0_PA + OVL_SRC_CON);
    if (have_fb_l)
        fb_base = (uintptr_t)fb_fdt;
    /* Prefer what OVL0 really scans out from inside the LK vram. */
    for (unsigned n = 0; n < 4; n++) {
        if (!(src & (1U << n)))
            continue;
        uint64_t addr = mmio_rd(OVL0_PA + OVL_ADDR(n));
        uint32_t pitch = mmio_rd(OVL0_PA + OVL_PITCH(n)) & 0xffffU;
        uint32_t fmt = (mmio_rd(OVL0_PA + OVL_CON(n)) >> 12) & 0xfU;
        if (have_fb_l && addr >= fb_fdt && addr < fb_fdt + (vram_size ? vram_size : 0x2000000) &&
            pitch >= FB_W * 2U) {
            fb_base = (uintptr_t)addr;
            fb_stride = pitch;
            fb_bpp = fmt == 0 ? 16 : 32;   /* OVL_CON_CLRFMT_RGB565 = 0 */
            fb_layer = (int)n;
            break;
        }
    }
    if (fb_layer >= 0)
        return;
    /* No (usable) framebuffer in the FDT: take what OVL0 scans out, if it looks like a
     * 720-pixel-wide buffer in DRAM. */
    for (unsigned n = 0; n < 4; n++) {
        if (!(src & (1U << n)))
            continue;
        uint64_t addr = mmio_rd(OVL0_PA + OVL_ADDR(n));
        uint32_t pitch = mmio_rd(OVL0_PA + OVL_PITCH(n)) & 0xffffU;
        uint32_t fmt = (mmio_rd(OVL0_PA + OVL_CON(n)) >> 12) & 0xfU;
        if (addr >= 0x40000000ULL && addr + (uint64_t)pitch * FB_H <= 0xc0000000ULL &&
            pitch >= FB_W * 2U && pitch <= FB_W * 4U + 512U) {
            fb_base = (uintptr_t)addr;
            fb_stride = pitch;
            fb_bpp = fmt == 0 ? 16 : 32;
            fb_layer = (int)n;
            return;
        }
    }
}

static void report_framebuffer(void)
{
    s("FB FDT ");
    hex(fb_fdt);
    s(" VRAM ");
    hex(vram_size);
    line_end(WHITE);
    s("LCM ");
    s(lcm_name[0] ? lcm_name : "?");
    line_end(WHITE);
    uint32_t src = mmio_rd(OVL0_PA + OVL_SRC_CON);
    s("OVL0 SRC_CON ");
    hex(src);
    line_end(WHITE);
    for (unsigned n = 0; n < 4; n++) {
        if (!(src & (1U << n)))
            continue;
        uint32_t size = mmio_rd(OVL0_PA + OVL_SRC_SIZE(n));
        s("L");
        dec(n);
        s(" ");
        hex(mmio_rd(OVL0_PA + OVL_ADDR(n)));
        s(" P ");
        dec(mmio_rd(OVL0_PA + OVL_PITCH(n)) & 0xffffU);
        s(" ");
        dec(size & 0xffffU);
        s("X");
        dec(size >> 16);
        s(" F ");
        dec((mmio_rd(OVL0_PA + OVL_CON(n)) >> 12) & 0xfU);
        line_end(WHITE);
    }
    s("USE FB ");
    hex(fb_base);
    s(" STRIDE ");
    dec(fb_stride);
    s(" BPP ");
    dec(fb_bpp);
    line_end(fb_bpp == 32 ? YELLOW : RED);
    if (fb_bpp != 32) {
        s("RGB565 SCANOUT: XNU EXPECTS 32 BPP");
        line_end(RED);
    }
}

/* ---- payload (mkpayload.py version 1, as shim/herolte) ---- */
struct payload_seg {
    uint64_t vmaddr, vmsize, file_off, file_size;
};
struct payload {
    char magic[8];
    uint32_t version, nsegs;
    uint64_t virt_base, entry_va, adt_off, adt_size, kernel_end;
    uint64_t phys_base, mem_size;
    char cmdline[BOOT_LINE_LENGTH];
    struct payload_seg segs[];
};
struct boot_video {
    uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};
struct boot_args {
    uint16_t Revision, Version;
    uint64_t virtBase, physBase, memSize, topOfKernelData;
    struct boot_video Video;
    uint32_t machineType;
    uint64_t deviceTreeP;
    uint32_t deviceTreeLength;
    char CommandLine[BOOT_LINE_LENGTH];
    uint64_t bootFlags, memSizeActual;
};
_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args size");

extern uint64_t a01_boot_args_pa;
extern char _start[], _image_end[];

static int magic_ok(const char *v)
{
    const char *want = "SWEETXNU";
    for (unsigned i = 0; i < 8; i++)
        if (v[i] != want[i])
            return 0;
    return 1;
}

static uintptr_t fail(const char *why)
{
    s("STOP: ");
    s(why);
    line_end(RED);
    s("HOLD POWER+VOL DOWN TO REBOOT");
    line_end(WHITE);
    clean_range(LOG_PA, LOG_PA + PAGE);
    return 0;
}

/* Returns the XNU entry PA, or 0 to halt. */
static uint64_t ticks(void)
{
#ifdef A01_HOST_TEST
    static uint64_t t;
    return t += 1000;
#else
    uint64_t v;
    __asm__ volatile ("isb; mrs %0, cntpct_el0" : "=r"(v));
    return v;
#endif
}

/*
 * The kernel draws at a compiled-in address (A01CORE_FB_PA, A01CORE_FB_STRIDE). If LK put
 * its scanout buffer elsewhere, move the picture there and point DISP_OVL0 at it, so the
 * kernel does not have to be rebuilt with the probe's numbers. The target must be DRAM and
 * either free or inside LK's own video memory, and clear of everything the shim loads.
 */
static int pin_framebuffer(uint64_t xnu_base, uint64_t xnu_size, uintptr_t payload, uint64_t plen,
                           uintptr_t fdt)
{
    uint64_t want = A01CORE_FB_PA, size = (uint64_t)A01CORE_FB_STRIDE * FB_H;
    if (fb_base == want && fb_stride == A01CORE_FB_STRIDE)
        return 1;
    s("FB ");
    hex(fb_base);
    s("/");
    dec(fb_stride);
    s(" -> ");
    hex(want);
    s("/");
    dec(A01CORE_FB_STRIDE);
    line_end(YELLOW);
    int c = first_conflict(want, size);
    int in_vram = have_fb_l && want >= fb_fdt && want + size <= fb_fdt + (vram_size ? vram_size : 0x2000000);
    int in_fb_rsv = c >= 0 && fb_base >= rsv[c].base && fb_base < rsv[c].base + rsv[c].size &&
                    want + size <= rsv[c].base + rsv[c].size && want >= rsv[c].base;
    if (fb_layer < 0 || A01CORE_FB_STRIDE < FB_W * 4U || !inside_dram(want, size) ||
        (c >= 0 && !in_vram && !in_fb_rsv) ||
        overlaps(want, size, xnu_base, xnu_size) || overlaps(want, size, SURFACE_PA, SURFACE_SIZE) ||
        overlaps(want, size, payload, plen) || overlaps(want, size, fdt, 0x100000) ||
        overlaps(want, size, (uintptr_t)_start, (uintptr_t)_image_end - (uintptr_t)_start) ||
        overlaps(want, size, LOG_PA, PAGE)) {
        s("FB TARGET NOT USABLE: BUILD XNU WITH");
        line_end(RED);
        s("A01CORE_FB_PA ");
        hex(fb_base);
        s(" STRIDE ");
        dec(fb_stride);
        line_end(RED);
        return 0;
    }
    /* copy the picture row by row, in the order that is safe if the ranges overlap */
    uint32_t row = FB_W * 4U;
    if (want > fb_base) {
        for (unsigned y = FB_H; y-- > 0;)
            memcpy((void *)(uintptr_t)(want + (uint64_t)y * A01CORE_FB_STRIDE),
                   (const void *)(fb_base + (uintptr_t)y * fb_stride), row);
    } else {
        for (unsigned y = 0; y < FB_H; y++)
            memcpy((void *)(uintptr_t)(want + (uint64_t)y * A01CORE_FB_STRIDE),
                   (const void *)(fb_base + (uintptr_t)y * fb_stride), row);
    }
    clean_range((uintptr_t)want, (uintptr_t)(want + size));
    uint32_t pitch = mmio_rd(OVL0_PA + OVL_PITCH(fb_layer));
    mmio_wr(OVL0_PA + OVL_PITCH(fb_layer), (pitch & ~0xffffU) | A01CORE_FB_STRIDE);
    mmio_wr(OVL0_PA + OVL_ADDR(fb_layer), (uint32_t)want);
    /* the new address is latched at the next frame: wait ~3 frames (13 MHz counter) */
    for (uint64_t t0 = ticks(); ticks() - t0 < 13000000ULL / 20U;)
        ;
    fb_base = (uintptr_t)want;
    fb_stride = A01CORE_FB_STRIDE;
    s("FB PINNED, OVL0 L");
    dec((uint64_t)fb_layer);
    s(" ADDR ");
    hex(mmio_rd(OVL0_PA + OVL_ADDR(fb_layer)));
    line_end(GREEN);
    return mmio_rd(OVL0_PA + OVL_ADDR(fb_layer)) == (uint32_t)want;
}

uintptr_t a01_main(uintptr_t fdt, uint64_t entry_el, uint64_t sctlr);
uintptr_t a01_main(uintptr_t fdt, uint64_t entry_el, uint64_t sctlr)
{
    volatile uint64_t *slots = (volatile uint64_t *)LOG_PA;
    memset((void *)LOG_PA, 0, PAGE);
    slots[0] = 0x31303045524f4341ULL;   /* "ACORE001" */
    slots[1] = entry_el;
    slots[2] = sctlr;
    slots[3] = fdt;

    /* LK leaves the TOPRGU watchdog running for Linux to feed. */
    uint32_t wdt_before = mmio_rd(TOPRGU_PA + WDT_MODE);
    mmio_wr(TOPRGU_PA + WDT_MODE, (wdt_before & ~WDT_MODE_EN) | WDT_MODE_KEY);
    uint32_t wdt_after = mmio_rd(TOPRGU_PA + WDT_MODE);
    slots[4] = ((uint64_t)wdt_before << 32) | wdt_after;

    int fdt_ok = fdt_scan(fdt);
    find_framebuffer();
#ifndef A01_HOST_TEST
    if (!fb_base) {
        /* Nothing to draw on: reboot at once, so "reboots right after the warning
         * screen" tells that this 64-bit code ran (and "stays on the warning" that it
         * did not). */
        mmio_wr(TOPRGU_PA + WDT_SWRST, WDT_SWRST_KEY);
        for (;;)
            __asm__ volatile ("wfi");
    }
#endif
    slots[5] = fb_base;
    slots[6] = fb_stride;

    s("A01CORE SHIM 1 - IOS 16 PORT");
    line_end(GREEN);
    s("EL ");
    dec(entry_el);
    s(" SCTLR ");
    hex(sctlr);
    line_end(entry_el == 1 || entry_el == 2 ? WHITE : RED);
    s("WDT ");
    hex(wdt_before);
    s(" -> ");
    hex(wdt_after);
    line_end((wdt_after & WDT_MODE_EN) ? RED : WHITE);
    s("FDT ");
    hex(fdt);
    s(fdt_ok ? " OK" : " UNREADABLE");
    line_end(fdt_ok ? WHITE : RED);
    for (unsigned i = 0; i < nmem; i++) {
        s("MEM ");
        hex(mem[i].base);
        s("+");
        hex(mem[i].size);
        line_end(WHITE);
    }
    for (unsigned i = 0; i < nrsv; i++) {
        s("RSV ");
        hex(rsv[i].base);
        s("+");
        hex(rsv[i].size);
        line_end(WHITE);
    }
    report_framebuffer();
    if (!fdt_ok || !nmem)
        return fail("NO USABLE FDT FROM LK");

    /* Payload: appended to this Image (bounded by its header image_size),
     * else an initrd. */
    uint64_t image_size = *(volatile uint64_t *)(uintptr_t)(_start + 16);
    uintptr_t rd_start = (uintptr_t)_image_end, rd_end = (uintptr_t)_start + image_size;
    if (rd_end <= rd_start || !magic_ok((const char *)rd_start)) {
        rd_start = (uintptr_t)initrd_start;
        rd_end = (uintptr_t)initrd_end;
    }
    const struct payload *p = (const struct payload *)rd_start;
    if (rd_end <= rd_start || rd_end - rd_start < sizeof(*p) || !magic_ok(p->magic)) {
        /* PROBE mode. */
        check_region("XNU RAM", DEFAULT_RAM_BASE, DEFAULT_RAM_SIZE);
        check_region("SURFACE", SURFACE_PA, SURFACE_SIZE);
        s("PROBE ONLY: NO XNU PAYLOAD.");
        line_end(YELLOW);
        s("PHOTOGRAPH THIS SCREEN.");
        line_end(YELLOW);
        return fail("PROBE DONE");
    }
    uint64_t length = rd_end - rd_start;
    if (p->version != 1 || !p->nsegs || p->nsegs > 32 ||
        __builtin_offsetof(struct payload, segs) + p->nsegs * sizeof(struct payload_seg) > length ||
        p->adt_off > length || p->adt_size > length - p->adt_off ||
        p->entry_va < p->virt_base || p->kernel_end < p->virt_base || !p->mem_size)
        return fail("BAD SWEETXNU PAYLOAD");

    int ok = check_region("XNU RAM", p->phys_base, p->mem_size);
    ok &= check_region("SURFACE", SURFACE_PA, SURFACE_SIZE);
    if (overlaps(p->phys_base, p->mem_size, SURFACE_PA, SURFACE_SIZE) ||
        overlaps(p->phys_base, p->mem_size, rd_start, length) ||
        overlaps(p->phys_base, p->mem_size, fdt, 0x100000) ||
        overlaps(p->phys_base, p->mem_size, (uintptr_t)_start, (uintptr_t)_image_end - (uintptr_t)_start) ||
        overlaps(p->phys_base, p->mem_size, LOG_PA, PAGE))
        return fail("XNU RAM OVERLAPS LOADER/PAYLOAD/SURFACE");
    if (!ok)
        return fail("RAM WINDOW NOT FREE: REBUILD ADT");
    if (fb_bpp != 32)
        return fail("FRAMEBUFFER IS NOT 32 BPP");
    if (!pin_framebuffer(p->phys_base, p->mem_size, rd_start, length, fdt))
        return fail("FRAMEBUFFER NOT WHERE THE KERNEL DRAWS");

    uintptr_t memory_end = p->phys_base + p->mem_size;
    uintptr_t kernel_end = p->phys_base + (p->kernel_end - p->virt_base);
    if (kernel_end >= memory_end)
        return fail("KERNEL TOO LARGE");
    s("COPYING ");
    dec(p->nsegs);
    s(" SEGMENTS");
    line_end(WHITE);
    for (uint32_t i = 0; i < p->nsegs; i++) {
        const struct payload_seg *g = &p->segs[i];
        if (g->vmaddr < p->virt_base || g->file_size > g->vmsize ||
            g->file_off > length || g->file_size > length - g->file_off ||
            g->vmsize > p->mem_size || g->vmaddr - p->virt_base > p->mem_size - g->vmsize)
            return fail("BAD SEGMENT");
        uintptr_t dst = p->phys_base + (g->vmaddr - p->virt_base);
        memcpy((void *)dst, (const void *)(rd_start + g->file_off), g->file_size);
        memset((void *)(dst + g->file_size), 0, g->vmsize - g->file_size);
        clean_range(dst, dst + g->vmsize);
    }
    uintptr_t adt_pa = kernel_end;
    uintptr_t ba_pa = (adt_pa + p->adt_size + PAGE - 1) & ~(PAGE - 1);
    if (ba_pa + PAGE > memory_end)
        return fail("NO ROOM FOR BOOT ARGS");
    memcpy((void *)adt_pa, (const void *)(rd_start + p->adt_off), p->adt_size);
    memset((void *)ba_pa, 0, PAGE);
    volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
    ba->Revision = 2;
    ba->Version = 2;
    ba->virtBase = p->virt_base;
    ba->physBase = p->phys_base;
    ba->memSize = p->mem_size;
    ba->topOfKernelData = ba_pa + PAGE;
    /* LK's scanout buffer, for PE_current_console users. */
    ba->Video.v_baseAddr = fb_base;
    ba->Video.v_display = 1;
    ba->Video.v_rowBytes = fb_stride;
    ba->Video.v_width = FB_W;
    ba->Video.v_height = FB_H;
    ba->Video.v_depth = 32;
    ba->deviceTreeP = p->virt_base + (adt_pa - p->phys_base);
    ba->deviceTreeLength = (uint32_t)p->adt_size;
    for (unsigned i = 0; i < BOOT_LINE_LENGTH; i++)
        ba->CommandLine[i] = p->cmdline[i];
    ba->memSizeActual = p->mem_size;
    clean_range(adt_pa, ba_pa + PAGE);

    uintptr_t entry_pa = p->phys_base + (p->entry_va - p->virt_base);
    if (entry_pa >= kernel_end)
        return fail("ENTRY OUTSIDE KERNEL");
    a01_boot_args_pa = ba_pa;
    slots[7] = entry_pa;
    slots[8] = ba_pa;
    s("JUMP TO XNU ");
    hex(entry_pa);
    line_end(GREEN);
    s("XNU EXPECTS FB ");
    hex(fb_base);
    s(" STRIDE ");
    dec(fb_stride);
    line_end(YELLOW);
    clean_range(LOG_PA, LOG_PA + PAGE);
    clean_range(fb_base, fb_base + (uintptr_t)fb_stride * FB_H);
    return entry_pa;
}
