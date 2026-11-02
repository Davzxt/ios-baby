/*
 * The XNU kernel interfaces the A01 DDK OS layer uses, declared here so env/xnu builds without
 * the XNU headers (they clash with the DDK's own types). Each matches the XNU 8792 (iOS 16)
 * declaration named next to it; the link against the kernel checks the names.
 */
#ifndef XNU_KPI_H
#define XNU_KPI_H
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>

typedef struct a01_lck_grp lck_grp_t;          /* osfmk/kern/lock_group.h */
typedef struct a01_lck_attr lck_attr_t;
typedef struct a01_lck_mtx lck_mtx_t;          /* osfmk/kern/lock_mtx.h */
typedef struct a01_lck_rw lck_rw_t;            /* osfmk/kern/lock_rw.h */
typedef struct a01_thread *thread_t;           /* osfmk/kern/thread.h */
typedef struct a01_vm_map *vm_map_t;
typedef uintptr_t vm_offset_t;
typedef uintptr_t vm_size_t;
typedef uint32_t ppnum_t;
typedef int kern_return_t;
typedef uint64_t user_addr_t;
struct a01_timespec { long tv_sec; long tv_nsec; };  /* bsd/sys/_types/_timespec.h */

extern lck_grp_t *lck_grp_alloc_init(const char *name, void *attr);
extern lck_mtx_t *lck_mtx_alloc_init(lck_grp_t *grp, lck_attr_t *attr);
extern void lck_mtx_free(lck_mtx_t *lck, lck_grp_t *grp);
extern void lck_mtx_lock(lck_mtx_t *lck);
extern void lck_mtx_unlock(lck_mtx_t *lck);
extern int lck_mtx_try_lock(lck_mtx_t *lck);   /* boolean_t */
extern lck_rw_t *lck_rw_alloc_init(lck_grp_t *grp, lck_attr_t *attr);
extern void lck_rw_free(lck_rw_t *lck, lck_grp_t *grp);
extern void lck_rw_lock_shared(lck_rw_t *lck);
extern void lck_rw_lock_exclusive(lck_rw_t *lck);
extern void lck_rw_unlock_shared(lck_rw_t *lck);
extern void lck_rw_unlock_exclusive(lck_rw_t *lck);

extern void *IOMalloc(vm_size_t size);         /* iokit/IOKit/IOLib.h */
extern void IOFree(void *address, vm_size_t size);
extern void IOSleep(unsigned milliseconds);
extern int PE_parse_boot_argn(const char *arg_string, void *arg_ptr, int max_arg);   /* pexpert */
extern void delay(int usec);                   /* osfmk/kern/clock.h */
extern uint64_t mach_absolute_time(void);
extern void absolutetime_to_nanoseconds(uint64_t abstime, uint64_t *result);

/* bsd/sys/systm.h: sleep on a channel with a mutex; wakeup everyone on it */
extern int msleep(void *chan, lck_mtx_t *mtx, int pri, const char *wmesg, struct a01_timespec *ts);
extern void wakeup(void *chan);
#define A01_EWOULDBLOCK 35

extern kern_return_t kernel_thread_start(void (*continuation)(void *, int), void *parameter, thread_t *new_thread);
extern void thread_deallocate(thread_t thread);
extern void thread_block(void *continuation);  /* thread_block(THREAD_CONTINUE_NULL) yields */
extern thread_t current_thread(void);
extern int proc_selfpid(void);                 /* bsd/sys/proc.h */
extern void proc_selfname(char *buf, int size);

extern int copyin(user_addr_t uaddr, void *kaddr, size_t len);
extern int copyout(const void *kaddr, user_addr_t udaddr, size_t len);

extern vm_offset_t ml_io_map(vm_offset_t phys_addr, vm_size_t size);
extern vm_offset_t ml_io_map_wcomb(vm_offset_t phys_addr, vm_size_t size);
extern void ml_io_unmap(vm_offset_t addr, vm_size_t sz);
extern uint64_t kvtophys(vm_offset_t va);
extern vm_map_t kernel_map;
extern uint64_t max_mem;
extern int page_shift;

/* osfmk/arm/caches_internal.h */
extern void flush_dcache(vm_offset_t addr, unsigned count, int phys);
extern void clean_dcache(vm_offset_t addr, unsigned count, int phys);
extern void FlushPoC_Dcache(void);

extern int printf(const char *fmt, ...);
extern int vprintf(const char *fmt, va_list ap);
extern int vsnprintf(char *str, size_t size, const char *fmt, va_list ap);
extern int vsscanf(const char *str, const char *fmt, va_list ap);
extern size_t strlcpy(char *dst, const char *src, size_t siz);
extern size_t strnlen(const char *s, size_t max);
extern int strncmp(const char *s1, const char *s2, size_t n);
extern int strcmp(const char *s1, const char *s2);
extern char *strncpy(char *dst, const char *src, size_t n);
extern void panic(const char *str, ...);
#endif
