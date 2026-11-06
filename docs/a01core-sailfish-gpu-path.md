# Adapting the Sailfish GPU presentation path to A01 Core

Reference inspected: joranv1/ios-sailfish commit
`6f27e41ff249f2680540ebe8ee5ab982c5e641c9`. Sailfish runs CoreAnimation
through an EAGL shim and Mesa Freedreno on Adreno 530, not Metal. Its
`tools/sweetgl/eagl.c` imports an IOSurface as an MSM GEM handle and passes
the handle, stride and page offset to Gallium `resource_from_handle`; its
display path uses GPU copies and double-buffered scanout. Its DRM ABI and
Adreno commands must not be sent to the A01 PowerVR device.

The A01 already has an EAGL shim and GPU execution through Zink and the
PowerVR Vulkan ICD. `gpu/a01gl/a01_hw_stub.c` deliberately disables shared
surface hooks. `gpu/ddk-1.11/env/xnu/physmem_xnu.c` creates PMRs only from
owned `a01gpu_buf` allocations; it does not import a SweetSurface. Therefore
changing the presentation hook alone would not make an IOSurface GPU-visible.

The first required implementation is a retained, bounds-checked IOSurface
import on the PowerVR side, with a PMR owning a reference to the surface and
its IOMemoryDescriptor. The import must reject unsupported physical addresses,
handle the GPU and CPU page sizes, preserve the byte offset and stride, and
release references on every error and finalization path. GPU completion and
CPU cache visibility must be established before either side reuses memory.
The handle must be exposed through the A01 bridge and then through a supported
Vulkan external-memory import and Zink resource path. The scanout and scaling
step remains separate. Existing texture-coordinate failures must also be
resolved; direct presentation alone cannot correct them.

No such import or direct presentation has been implemented or tested yet.
