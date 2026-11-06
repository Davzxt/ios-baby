# NativeMetal integration for A01 Core

Status: initial board adapter only. Not compiled or installed. No functional
Metal UI, host import or GPU scanout is claimed.

Reference: https://github.com/mouseos/NativeMetal at
`23dcaf08a92f106b40489f357eeeed203cd5fb29`, the revision selected by
mouseos/UniXNU when inspected on 2026-11-05. The repository's default branch
at `c6d29caad6d880cc8204ebe3bc34d77479a3255d` lacks the required generic
NativeVulkanMetalPlugin.mm. Do not build against an unpinned default branch.

The adapter implements the four NativeMetalBoard.h entry points. It does not
borrow the GE8300 board's IOKit service ABI, memory import or display transport.
Configure the generic plugin's NATIVE_METAL_VULKAN_DRIVER with the existing
`/private/var/a01/lib/libvulkan.1.dylib` loader, which exports the Vulkan loader
entry points; verify the bridge's complete entry-point requirements first.

Required work before packaging:

1. Pin the matching UniXNU builder, NativeMobileDisplay headers and Rust
   metal2vulkan bridge; audit their iOS 16 ABI and SDK requirements.
2. Build the frontend plus A01NativeMetalBoard.mm with the matching bridge.
3. Validate accelerator discovery and sandbox permissions on the A01 kernel.
4. Implement and test host-memory import with retained memory descriptors,
   correct page sizes and completion synchronization. Current private PMR
   allocations cannot stand in for IOSurface ownership.
5. Run shader translation/render tests before publishing the Metal device.
6. Adapt the A01 display driver for actual GPU scanout; the current board hook
   explicitly reports it unavailable.

Existing Zink packages are unchanged. This directory is not part of the Odin
packaging script, and it must not be presented as a working replacement.
