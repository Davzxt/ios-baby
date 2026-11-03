#!/bin/bash
# Kernel + Metal for HEAD, Vulkan 41444249019; drop with the autorun the root registers; packages.
set -u
R=/c/Users/Admin/Desktop/ios_a03_v2
S="C:/Users/Admin/AppData/Local/Temp/claude/C--Users-Admin-Desktop-ios-a03-v2/a2ed0fa5-fa72-44c1-8a7a-4f978e73605f/scratchpad"
MB="C:/Users/Admin/AppData/Local/Temp/claude/C--Users-Admin-Desktop-ios-a03-v2/a3d74d84-65b3-4ea2-b7e0-b224ecc6211d/scratchpad/make_boot.sh"
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill | sed -n 's/^password=//p')
SHA=c9f28de42dba61f178e729d5307e0f2092dcc6f2
api() { curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/Davzxt/ios-baby/$1"; }
run_for() {
  for i in $(seq 1 40); do
    id=$(api "actions/workflows/$1/runs?head_sha=$SHA&per_page=1" | python -c "import sys,json;r=json.load(sys.stdin)['workflow_runs'];print(r[0]['id'] if r else '')")
    [ -n "$id" ] && { echo "$id"; return; }; sleep 15
  done
}
wait_run() {
  for i in $(seq 1 200); do
    r=$(api "actions/runs/$1" | python -c "import sys,json;j=json.load(sys.stdin);print(j['status'],j['conclusion'])")
    case "$r" in completed*) echo "$r"; return;; esac; sleep 30
  done
}
XNU=41716709067; MT=41716709141; VK=$(run_for a01vulkan.yml); GL=41609024535
echo "runs: xnu $XNU metal $MT vulkan $VK"
rg=$(wait_run $GL); echo "a01gl $rg"; case "$rg" in *failure*) exit 1;; esac; rm_=$(wait_run $MT); echo "metal $rm_"; case "$rm_" in *failure*) exit 1;; esac; rx=$(wait_run $VK); echo "vulkan $rx"; case "$rx" in *failure*) exit 1;; esac; rk=$(wait_run $XNU); echo "xnu $rk"; case "$rk" in *failure*) exit 1;; esac
case "$rx $rm_" in *failure*|*cancelled*) echo "build failed"; exit 1;; esac
art() { api "actions/runs/$1/artifacts" | python -c "import sys,json;print(json.load(sys.stdin)['artifacts'][0]['id'])"; }
D="$S/drop-$SHA"; mkdir -p "$D"
for pair in "$VK:vk" "$MT:mt" "$GL:gl"; do
  id=${pair%%:*}; n=${pair##*:}
  curl -sL -H "Authorization: Bearer $TOKEN" -o "$D/$n.zip" "https://api.github.com/repos/Davzxt/ios-baby/actions/artifacts/$(art $id)/zip" && unzip -o -q "$D/$n.zip" -d "$D/$n"
done
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' python -I "C:/Users/Admin/Desktop/ios_a03_v2/tools/a01core-drop.py" "$D/a01drop.pkg" \
  /System/Library/Extensions/A01Metal.bundle/A01Metal="$D/mt/A01Metal.bundle/A01Metal" \
  /System/Library/Extensions/A01Metal.bundle/Info.plist="$D/mt/A01Metal.bundle/Info.plist" \
  lib/libvulkan_powervr.dylib="$D/vk/libvulkan_powervr.dylib" lib/libdrm.2.dylib="$D/vk/libdrm.2.dylib" \
  lib/libA01Metal.dylib="$D/mt/libA01Metal.dylib" lib/libOSMesa.8.dylib="$D/gl/lib/libOSMesa.8.dylib" lib/libvulkan.1.dylib="$D/gl/lib/libvulkan.1.dylib" lib/libheroeagl.dylib="$D/gl/lib/libheroeagl.dylib" /private/var/herolte/autorun="$D/mt/a01metal-test"
DROP="$D/a01drop.pkg" bash "$MB" "$XNU" 41338560241 "$S/boot-$SHA" 2>&1 | grep -E "tar.md5|exceeds|rror"
"C:/Program Files/LLVM/bin/llvm-objdump.exe" --macho --bind "$D/vk/libvulkan_powervr.dylib" | grep flat-namespace | grep -v weak_import || echo "no strong flat symbols"
cd /c/A01CORE_RECOVERY/IOS_ROOT && python -I -c "
import hashlib
for f in ['AP_IOS16_BOOT_1GB_RAM_GPU_DIAG.tar.md5','AP_IOS16_BOOT_1GB_RAM_GPU_GL_ZINK.tar.md5','AP_IOS16_BOOT_1GB_RAM_GPU_GL_ZINK_DIAG.tar.md5','AP_IOS16_BOOT_1GB_RAM_GPU_DIAG_3CPU.tar.md5','AP_IOS16_BOOT_1GB_RAM_3CPU_SEM_GPU.tar.md5']:
    b=open(f,'rb').read(); n=len(b)//512*512; print(f, b[n:].split()[0].decode()==hashlib.md5(b[:n]).hexdigest())
"
