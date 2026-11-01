# A01 Core GPU stack: plan (2026-11-01)

## Done

- GE8100 power-on and BVNC 22.49.21.16 read back (0311).
- MIPS firmware rgx.fw (DDK 1.11@5425693) loaded and booted under XNU (0314-0317).
- Host init structures, firmware started, one kernel-CCB HEALTH_CHECK answered (0318, user report).
- Metal layer skeleton on Vulkan (gpu/a01metal), compiles for iOS.

## The 1.11 vs 1.17 gap

Upstream Mesa pvr only talks to the DDK 1.17 kernel interface (`pvr_srv.c`: "Only the 1.17 driver is
supported"). JimVulkan/img-pvr (MIT, Mesa 27-devel) ports it to DDK 1.11: the 1.11 bridge calls,
firmware command layouts and job setup. It is tested on a GE8320 with kernel driver
1.11.5425693, the same DDK build as this phone's firmware. gpu/a01vulkan builds it for iOS with a
GE8100 (22.49.21.16) device entry.

## Kernel side: port the DDK 1.11 services server to XNU

img-pvr uses about 45 bridge calls: SRVCORE connect, MM (device memory contexts, heaps, PMRs, map
and unmap), SYNC (sync primitive blocks), RGXTA3D (render contexts, free lists, HWRT data, kick
TA/3D), RGXCMP (compute context, kick CDM), RGXTQ (transfer context, submit), RGXHWPERF (BVNC
flags), DMABUF (import and export).

The Samsung GPL kernel carries the matching server, drivers/misc/mediatek/gpu/gpu_rgx/m1.11ED5425693,
about 117k lines in services/server, licensed Dual MIT/GPLv2 (used here under MIT). The plan is to
compile its OS-independent core into XNU and write an `env/xnu` layer for what is Linux-specific
today:

1. OS layer: allocmem, osfunc (locks, timers, delays, cache maintenance), event objects, handles.
2. Physical memory: physmem_osmem (pages for PMRs), pmr_os (mapping PMRs into user space).
3. Device: register mapping, interrupts (GPU IRQ from the ADT), power hooks for the MFG domain
   (reuse 0311).
4. Bridge: an IOKit user client that takes (group, function, in, out) and calls the DDK's own
   bridge dispatch, replacing the Linux DRM ioctl entry.
5. Firmware loading through the DDK (rgxfwimageutils, rgxstartstop): replaces the hand-written
   0314-0318 loader. Its findings stay: 64 KiB register map, 32 KiB-aligned MIPS page table,
   BRN 63553 remap.

## Userland side

- img-pvr's srv winsys opens `/dev/dri/renderD128` and uses Linux sync_file fds. On iOS it gets a
  winsys shim that talks to the user client and waits on fences through it.
- Then the Vulkan test on the phone, then the Metal layer (gpu/a01metal) on top of it, then the
  CoreAnimation integration.

## Not claimed

Nothing above "firmware answers a ping" has run on the device. Smoothness can only be measured
once Metal draws.
