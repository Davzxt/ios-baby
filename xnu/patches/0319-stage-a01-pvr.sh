#!/bin/bash
# Stage the PowerVR DDK 1.11 kernel services (gpu/ddk-1.11) for the A01 Core GE8100 driver.
# dxb runs patches/*.sh from the XNU source root before applying *.patch; 0319 then lists the
# wrappers in bsd/conf/files and gives them their flags in bsd/conf/Makefile.template.
set -euo pipefail

# Staged for every board: the wrappers compile to nothing unless ARM64_BOARD_CONFIG_A01CORE.
src="${GITHUB_WORKSPACE:?}/gpu/ddk-1.11"
[[ -f "$src/env/xnu/sources.txt" && -f bsd/kern/bsd_init.c ]]
dst=bsd/a01_pvr
[[ ! -e "$dst" ]] || { echo "refusing to overwrite $dst" >&2; exit 1; }
mkdir -p "$dst"
cp -R "$src" "$dst/ddk"
rm -rf "$dst/ddk/env/xnu/build-check" "$dst/ddk/services/server/env/linux"
# One wrapper per DDK source: unique object names (pvr_<file>.o) next to XNU's own objects.
while read -r f; do
    [[ -n "$f" ]] || continue
    printf '#include <pexpert/arm64/board_config.h>\n#if defined(ARM64_BOARD_CONFIG_A01CORE)\n#include "ddk/%s"\n#endif\n' \
        "$f" > "$dst/pvr_$(basename "$f")"
done < "$src/env/xnu/sources.txt"
ls "$dst" | grep -c '^pvr_.*\.c$'
