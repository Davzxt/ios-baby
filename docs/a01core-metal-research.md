# A01 Core: Metal on the PowerVR GE8100 (research, 2026-11-01)

Goal: `MTLCreateSystemDefaultDevice()` returns a working device on the SM-A013M (PowerVR GE8100,
BVNC 22.49.21.16) running iOS 16, at least partially.

## Facts

- Apple's Metal driver (AGXMetal*.bundle) only targets Apple GPUs; it cannot drive a PowerVR.
- Without a Metal device, iOS UI can run with QuartzCore's software path, but anything that holds a
  Metal context crashes. eShard hit exactly this in iOS 14 on QEMU: SpringBoard showed, Preferences
  crashed on a null Metal context.
  https://www.eshard.com/blog/emulating-ios-14-with-qemu-part2
- Shader translation exists: steelbrain/metal2vulkan (alpha, LGPL-3.0) turns Metal AIR into SPIR-V
  without LLVM on the production path. https://github.com/steelbrain/metal2vulkan
  Other Metal-over-Vulkan efforts: iglunix/indium (Metal-like C API over Vulkan), Darling discussion #1646.
- Vulkan for this GPU family: Mesa "pvr" supports Rogue 8XE (GE8300 22.102.54.38 is listed); Mesa 25.3
  added device info for more 8XE cores, unofficial. GE8100 22.49.21.16 is not confirmed in Mesa.
  https://docs.mesa3d.org/drivers/powervr.html
  https://phoronix.com/news/PowerVR-Mesa-More-GPUs
- On this device: the GE8100 powers on and reads back its BVNC under XNU (0311). The MIPS firmware load
  (0314/0315) has not been confirmed on screen yet.

## Stack needed (bottom to top)

1. XNU GPU kernel driver: firmware running (RGXFWIF_INIT, KCCB/FWCCB), memory/MMU contexts,
   command submission, interrupts. Port of DDK 1.11 services or of the upstream `powervr` DRM uAPI,
   exposed as an IOKit user client.
2. Mesa pvr (Vulkan) built as a Mach-O dylib for iOS, with a winsys for that user client and a
   device-info entry for 22.49.21.16.
3. A Metal driver bundle (our own code): MTLDevice / command queue / buffers / textures / encoders on
   Vulkan, shaders through metal2vulkan (AIR to SPIR-V). To check: how iOS 16 Metal.framework picks its
   driver bundle from the IOKit GPU service (on Apple GPUs the accelerator node names the plugin).
4. IOSurface and CoreAnimation integration, so the drawables end up on the display.

## Partial milestones

- M1: firmware boots and answers a no-op command (kernel only).
- M2: Mesa pvr runs a Vulkan compute test (vector add) on the phone.
- M3: a Metal device exists: buffers, blit and compute kernels through metal2vulkan. Apps that only
  check for a Metal device stop crashing.
- M4: render pipelines (triangle to an IOSurface), then CoreAnimation.

Each milestone needs the previous one. Nothing above M0 (power-on + BVNC) is done.
