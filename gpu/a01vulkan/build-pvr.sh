#!/bin/bash
# Cross-build Mesa's PowerVR Vulkan driver ("pvr", Rogue) for the Galaxy A01 Core's iOS 16
# userland (GE8100). Reuses the S7 recipe (gpu/mesa): Darwin patches, libdrm headers.
#   build-pvr.sh WORK OUT
set -euo pipefail
WORK=$(mkdir -p "$1" && cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
MESA=$HERE/../mesa
MESA_TAG=${MESA_TAG:-mesa-25.0.7}
LIBDRM_TAG=${LIBDRM_TAG:-libdrm-2.4.124}
MIN_IOS=16.0
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC_IOS="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=$MIN_IOS -isysroot $SDK"

cd "$WORK"
[ -d mesa ] || git clone -q --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git mesa
[ -d libdrm ] || git clone -q --depth 1 --branch "$LIBDRM_TAG" https://gitlab.freedesktop.org/mesa/drm.git libdrm
python3 "$MESA/patch-mesa.py" mesa

# libdrm: only headers and link symbols are needed here (the A01 kernel interface is the
# pvr "srv" winsys, which talks to the GE8100 driver directly, not through DRM).
mkdir -p drm-standin pc
$CC_IOS -O2 -dynamiclib -install_name @rpath/libdrm.2.dylib -I libdrm -I libdrm/include/drm \
  -I mesa/include -o drm-standin/libdrm.2.dylib "$MESA/herodrm.c" -framework IOKit -framework CoreFoundation
ln -sf libdrm.2.dylib drm-standin/libdrm.dylib
cat > pc/libdrm.pc <<PC
Name: libdrm
Description: libdrm stand-in
Version: ${LIBDRM_TAG#libdrm-}
Cflags: -I$WORK/libdrm -I$WORK/libdrm/include/drm
Libs: -L$WORK/drm-standin -ldrm
PC

cat > ios-cross.txt <<X
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-arch', 'arm64']
objc = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK', '-I$WORK/libdrm', '-I$WORK/libdrm/include/drm']
cpp_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
c_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
cpp_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$WORK/pc'
[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
X

cd mesa
[ -d build ] || meson setup build --cross-file ../ios-cross.txt --buildtype=release -Dprefix=/ \
  -Dvulkan-drivers=imagination-experimental -Dimagination-srv=true -Dgallium-drivers= \
  -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= -Dopengl=false \
  -Dgles1=disabled -Dgles2=disabled -Dshader-cache=disabled -Dvalgrind=disabled \
  -Dlibunwind=disabled -Dzstd=disabled -Dxmlconfig=disabled -Dbuild-tests=false \
  -Dglvnd=disabled -Dlmsensors=disabled -Dtools= -Dperfetto=false -Dvulkan-layers=
ninja -C build -k 0
cd ..
lib=$(ls mesa/build/src/imagination/vulkan/libvulkan_powervr_mesa*.dylib | head -1)
cp "$lib" "$OUT/libvulkan_powervr.dylib"
install_name_tool -id /usr/lib/libvulkan_powervr.dylib "$OUT/libvulkan_powervr.dylib"
codesign -s - -f "$OUT/libvulkan_powervr.dylib"
otool -L "$OUT/libvulkan_powervr.dylib"
