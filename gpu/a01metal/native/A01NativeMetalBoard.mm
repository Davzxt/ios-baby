// A01 board hooks for NativeMetal 23dcaf08a92f106b40489f357eeeed203cd5fb29.
// This is an integration scaffold, not a published Metal device.
#include "NativeMetalBoard.h"
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

extern "C" void native_metal_board_prepare(unsigned port)
{
    // A01's Vulkan ICD opens A01CoreGPU through a01drm itself.
    // Do not reuse the GE8300's service selectors or retain this borrowed port.
    (void)port;
    fprintf(stderr, "A01 NativeMetal: board prepared; scanout unavailable\n");
}

extern "C" void native_metal_board_mark(uint32_t value)
{
    fprintf(stderr, "A01 NativeMetal: marker %08x\n", value);
}

extern "C" void native_metal_board_text(const char *line)
{
    char message[112];
    int n = snprintf(message, sizeof(message), "A01 >>> METAL: %.63s <<<\n", line ? line : "");
    if (n <= 0) return;
    size_t len = (size_t)n < sizeof(message) ? (size_t)n : sizeof(message) - 1;
    fprintf(stderr, "%s", message);
    int fd = open("/dev/console", O_WRONLY | O_NONBLOCK);
    if (fd >= 0) { (void)write(fd, message, len); close(fd); }
}

extern "C" bool native_metal_board_scanout(gpuscanout::Transport *transport)
{
    if (transport) *transport = {};
    // No compatible NativeGOP transport exists on A01. Never report a fake
    // GPU handoff or send the other board's selectors to A01CoreGPU.
    return false;
}
