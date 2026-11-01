#!/bin/sh
# Build the Galaxy A01 Core loader: out/a01core.Image (raw arm64 Image,
# position independent). Pack it with tools/a01core-pack-boot.py: alone it
# is the PROBE boot image; with --append payload.bin it boots XNU.
# Any bare-metal or Linux aarch64 GCC works, e.g.
#   CROSS=aarch64-linux-gnu- sh build.sh
#   CROSS=aarch64-none-elf- sh build.sh
set -eu
cd "$(dirname "$0")"
: "${CROSS:=aarch64-linux-gnu-}"
mkdir -p out
CFLAGS="-c -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -fno-pie -nostdlib -fno-asynchronous-unwind-tables -fno-jump-tables -mgeneral-regs-only -mstrict-align -mcpu=cortex-a53 -Wall -Wextra -Werror ${A01CORE_DEFINES:-}"
"${CROSS}gcc" $CFLAGS start.S -o out/start.o
"${CROSS}gcc" $CFLAGS a01core.c -o out/a01core.o
"${CROSS}ld" -static -T image.ld --build-id=none --no-warn-rwx-segments out/start.o out/a01core.o -o out/a01core.elf
# A raw Image must be position independent: no absolute relocations.
if "${CROSS}readelf" -r out/start.o out/a01core.o | grep -q 'ABS64'; then
    echo "a01core: absolute relocation found" >&2
    exit 1
fi
"${CROSS}objcopy" -O binary out/a01core.elf out/a01core.Image
end=$("${CROSS}nm" out/a01core.elf | awk '$3 == "_image_end" { print $1 }')
python3 - out/a01core.Image "$end" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]).read_bytes()
assert p[56:60] == b'ARMd', 'missing arm64 Image magic'
# --append puts the payload at the 4 KiB-padded end, which must be _image_end.
assert (len(p) + 4095) // 4096 * 4096 == int(sys.argv[2], 16), '_image_end mismatch'
print(f'{sys.argv[1]}: {len(p)} bytes; arm64 Image header OK')
PY
