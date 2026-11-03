#!/bin/bash
# make_boot.sh XNU_RUN_ID SHIM_RUN_ID OUTDIR : download artifacts and build the Odin boot packages
set -euo pipefail
XNU_RUN=$1; SHIM_RUN=$2; M=$3
P=/c/A01CORE_RECOVERY/PORT_TEST; O=/c/A01CORE_RECOVERY/IOS_ROOT
REPO=/c/Users/Admin/Desktop/ios_a03_v2
mkdir -p "$M"
cd "$M"
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill 2>/dev/null | sed -n 's/^password=//p')
art() { curl -s "https://api.github.com/repos/Davzxt/ios-baby/actions/runs/$1/artifacts" | python -c "import sys,json;print([a['id'] for a in json.load(sys.stdin)['artifacts'] if a['name'].startswith('$2')][0])"; }
curl -sL -H "Authorization: Bearer $TOKEN" -o k.zip "https://api.github.com/repos/Davzxt/ios-baby/actions/artifacts/$(art $XNU_RUN xnu-kernel)/zip"
unzip -o -q k.zip kernel.development.a01core SHA256SUMS
sha256sum -c SHA256SUMS
curl -sL -H "Authorization: Bearer $TOKEN" -o s.zip "https://api.github.com/repos/Davzxt/ios-baby/actions/artifacts/$(art $SHIM_RUN a01core-shim)/zip"
unzip -o -q s.zip a01core.Image
cd "$REPO"
python tools/mkadt_a01core.py "$M/a01core.adt" | tail -1
BASE="cpus=1 keepsyms=1 -noprogress rd=emmcroot0 emmcroot=userdata emmcwrite=1 rootrw=1 cs_enforcement_disable=1 unentitled_ios_sim_launch=1 ignition_level=1 launchd_unsecure_cache=1 wdt=-1 -wdt_no_pmu wdt_test=no_user_checkin a5fb_keep_on=1 a5fb_noconsole=1 a01keys_home=1 sweetfb_lw=828 sweetfb_lh=1792 a01quiet=1"
for v in 1GB_RAM 1GB_RAM_4CPU 1GB_RAM_GPU_TESTE 1GB_RAM_GPU_DDK 1GB_RAM_GPU_DIAG 1GB_RAM_GPU_METAL_UI 1GB_RAM_GPU_GL_UI 1GB_RAM_GPU_GL_ZINK 1GB_RAM_GPU_GL_ZINK_DIAG 1GB_RAM_GPU_DIAG_2CPU 1GB_RAM_GPU_DIAG_3CPU 1GB_RAM_3CPU_SEM_GPU; do

  cmd="$BASE"; [ "$v" = 1GB_RAM_GPU_TESTE ] && cmd="${BASE/ a5fb_noconsole=1/} a01gpu=1 serial=3 debug=0xc"
  [ "$v" = 1GB_RAM_4CPU ] && { cmd="${BASE/ a5fb_noconsole=1/} a01gpu=2 serial=3"; cmd="${cmd/cpus=1/cpus=4}"; }   # GPU_DIAG with cpus=4 only
  [ "$v" = 1GB_RAM_3CPU_SEM_GPU ] && cmd="${BASE/cpus=1/cpus=3}"   # UI on the CPU (no GPU driver, no GL shim), 3 cores, clean screen
  [ "$v" = 1GB_RAM_GPU_DDK ] && cmd="$BASE a01gpu=2 serial=3"
  [ "$v" = 1GB_RAM_GPU_DIAG ] && { cmd="${BASE/ a5fb_noconsole=1/} a01gpu=2 serial=3 herogl=1 a01gl=zink"; cmd="${cmd/cpus=1/cpus=2}"; }   # 2 CPUs boot (2026-11-03)
  [ "$v" = 1GB_RAM_GPU_DIAG_3CPU ] && { cmd="${BASE/ a5fb_noconsole=1/} a01gpu=2 serial=3 herogl=1 a01gl=zink"; cmd="${cmd/cpus=1/cpus=3}"; }   # GPU_DIAG with 3 CPUs
  [ "$v" = 1GB_RAM_GPU_DIAG_2CPU ] && { cmd="${BASE/ a5fb_noconsole=1/} a01gpu=2 serial=3 herogl=1 a01gl=zink"; cmd="${cmd/cpus=1/cpus=2}"; }   # GPU_DIAG with 2 CPUs   # kernel text stays on screen
  [ "$v" = 1GB_RAM_GPU_GL_UI ] && cmd="$BASE a01gpu=2 serial=3 herogl=1"             # UI through the EAGL shim, softpipe
  [ "$v" = 1GB_RAM_GPU_GL_ZINK ] && cmd="$BASE a01gpu=2 serial=3 herogl=1 a01gl=zink"  # UI through the EAGL shim, Zink on the GE8100
  [ "$v" = 1GB_RAM_GPU_GL_ZINK_DIAG ] && cmd="${BASE/ a5fb_noconsole=1/} a01gpu=2 serial=3 herogl=1 a01gl=zink"  # same, console lines (GL/CODIGO) stay on screen
  [ "$v" = 1GB_RAM_GPU_METAL_UI ] && cmd="$BASE a01gpu=2 a01metal=1 serial=3"
  extra=""; case "$v" in 1GB_RAM_4CPU|1GB_RAM_GPU_DDK|1GB_RAM_GPU_DIAG|1GB_RAM_GPU_METAL_UI|1GB_RAM_GPU_GL_UI|1GB_RAM_GPU_GL_ZINK|1GB_RAM_GPU_GL_ZINK_DIAG|1GB_RAM_GPU_DIAG_2CPU|1GB_RAM_GPU_DIAG_3CPU) [ -n "${DROP:-}" ] && extra="--blob A01Drop=$DROP";; esac
  rm -f "$M/$v/odin/boot.img"; mkdir -p "$M/$v/odin"
  python tools/mkpayload.py "$M/kernel.development.a01core" "$M/a01core.adt" "$M/$v/payload.bin" \
    --blob TouchFirmware=$P/m3/td4150_a01core.img --blob TouchFirmwareNVT=/c/Users/Admin/Desktop/ios_a03_core/a01core-kernel/firmware/tsp_novatek/nt36525_a01core_tp.bin --blob GPUFirmware=/c/A01CORE_RECOVERY/VENDOR_EXTRACT/vendor/firmware/rgx.fw $extra --cmdline "$cmd" | grep '^size'
  python tools/a01core-pack-boot.py pack $P/stock/boot.img "$M/a01core.Image" "$M/$v/odin/boot.img" --append "$M/$v/payload.bin" | tail -1
  cp $P/vbmeta_disabled.img "$M/$v/odin/vbmeta.img"
  python tools/a01core-odin-pack.py tar "$O/AP_IOS16_BOOT_$v.tar.md5" "$M/$v/odin/boot.img" "$M/$v/odin/vbmeta.img"
done
