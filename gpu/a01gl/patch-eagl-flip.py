#!/usr/bin/env python3
"""Trial: reverse IOSurface upload rows in the A01 Zink render server only.

The device's GL tests show BWRG instead of RGBW, even with flipped texture
coordinates. This is an empirical workaround, not a proven driver fix. It
changes copied IOSurface uploads, not direct GPU sharing. Set the render
server environment A01_IOSURFACE_FLIP=0 to disable it.
"""
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_bytes().decode('utf-8').replace('\r\n', '\n')
old = '''    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *sp = src + ((invert || g_target_attach) ? y : (h - 1 - y)) * bpr;   // render server (target-form attach): images keep their native top-down rows; CARenderer-style clients: flipped unless invert
'''
new = '''    /* A01: trial reversal for the Zink render server, with opt-out. */
    const char *a01_driver = getenv("GALLIUM_DRIVER");
    const char *a01_flip = getenv("A01_IOSURFACE_FLIP");
    BOOL a01_reverse = getprogname() && strcmp(getprogname(), "backboardd") == 0 &&
        a01_driver && strcmp(a01_driver, "zink") == 0 && !(a01_flip && a01_flip[0] == '0');
    for (uint32_t y = 0; y < h; y++) {
        uint32_t source_y = (invert || g_target_attach) ? y : (h - 1 - y);
        if (a01_reverse) source_y = h - 1 - source_y;
        const uint8_t *sp = src + (size_t)source_y * bpr;
'''
if src.count(old) != 1:
    raise SystemExit('EAGL IOSurface row copy not found exactly once')
Path(sys.argv[2]).write_bytes(src.replace(old, new, 1).encode('utf-8'))
