#!/bin/bash
# Cross-build the PowerVR Vulkan driver (Mesa pvr on DDK 1.11, img-pvr) for the Galaxy A01 Core's iOS 16
# userland (GE8100). Reuses the S7 recipe (gpu/mesa): Darwin patches, libdrm headers.
#   build-pvr.sh WORK OUT
set -euo pipefail
WORK=$(mkdir -p "$1" && cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
MESA=$HERE/../mesa
MESA_TAG=${MESA_TAG:-mesa-26.2.3}
LIBDRM_TAG=${LIBDRM_TAG:-libdrm-2.4.124}
MIN_IOS=16.0
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC_IOS="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=$MIN_IOS -isysroot $SDK"

cd "$WORK"
# Mesa pvr ported to the DDK 1.11 kernel interface (MIT): github.com/JimVulkan/img-pvr
IMGPVR_SHA=${IMGPVR_SHA:-9e1c0279d6c0a3e6419c5818a82ae6903e0d921c}
if [ ! -d mesa ]; then
  git init -q mesa && git -C mesa fetch -q --depth 1 https://github.com/JimVulkan/img-pvr "$IMGPVR_SHA" && git -C mesa checkout -q FETCH_HEAD
fi
[ -d libdrm ] || git clone -q --depth 1 --branch "$LIBDRM_TAG" https://gitlab.freedesktop.org/mesa/drm.git libdrm
python3 "$MESA/patch-mesa.py" mesa || echo "patch-mesa.py: some S7 patches did not apply to $MESA_TAG"
python3 "$HERE/patch-ge8100.py" mesa
python3 "$HERE/patch-pvr-darwin.py" mesa
# img-pvr ships only the Android Vulkan headers; Darwin builds also need the beta and Apple ones
cp -n "$HERE"/vulkan-headers/*.h mesa/include/vulkan/
cp -R "$HERE/compat/." mesa/include/   # sys/sysmacros.h, linux/const.h, linux/types.h for Darwin

# libdrm: only headers and link symbols are needed here (the A01 kernel interface is the
# pvr "srv" winsys, which talks to the GE8100 driver directly, not through DRM).
mkdir -p drm-standin pc
# iOS libdrm: link stand-in only; the srv winsys will talk to the XNU GE8100 user client
# libdrm over the A01CoreGPU IOKit service; IOKit headers are not in the iOS SDK (S7 copies)
$CC_IOS -O2 -dynamiclib -install_name @rpath/libdrm.2.dylib -I libdrm -I libdrm/include/drm \
  -I "$HERE/../hakios-gl/include" -o drm-standin/libdrm.2.dylib "$HERE/a01drm.c" \
  -framework IOKit -framework CoreFoundation
ln -sf libdrm.2.dylib drm-standin/libdrm.dylib
cat > pc/libdrm.pc <<PC
Name: libdrm
Description: libdrm stand-in
Version: ${LIBDRM_TAG#libdrm-}
Cflags: -I$WORK/libdrm -I$WORK/libdrm/include/drm
Libs: -L$WORK/drm-standin -ldrm
PC

# Mesa 26 precompiles internal shaders with mesa_clc (OpenCL C, needs LLVM). Cross builds use host
# copies of mesa_clc and the driver's precomp compiler, built here for the macOS runner.
if [ ! -x host-tools/bin/mesa_clc ]; then
  LLVM=$(brew --prefix llvm)
  mkdir -p host-pc && cp pc/libdrm.pc host-pc/
  # host libdrm: only the host tools are used from this build, the driver itself may not link
  echo 'void a01_host_drm_stub(void) {}' > host-drm.c
  xcrun clang -O2 -dynamiclib -install_name "$WORK/host-drm/libdrm.2.dylib" -o host-drm-lib.dylib host-drm.c
  mkdir -p host-drm && mv host-drm-lib.dylib host-drm/libdrm.2.dylib && ln -sf libdrm.2.dylib host-drm/libdrm.dylib
  sed -i '' "s#-L$WORK/drm-standin#-L$WORK/host-drm#" host-pc/libdrm.pc
  (cd mesa && CC=/usr/bin/clang CXX=/usr/bin/clang++ AR=/usr/bin/ar LLVM_CONFIG="$LLVM/bin/llvm-config" PATH="$PATH:$LLVM/bin" PKG_CONFIG_PATH="$WORK/host-pc:$(brew --prefix)/lib/pkgconfig:$LLVM/lib/pkgconfig"     meson setup ../host-build -Dprefix="$WORK/host-tools" --buildtype=release     -Dc_args="-I$WORK/libdrm -I$WORK/libdrm/include/drm"     -Dvulkan-drivers=imagination -Dgallium-drivers= -Dllvm=enabled -Dmesa-clc=enabled     -Dinstall-mesa-clc=true -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true     -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled     -Dgles2=disabled -Dbuild-tests=false -Dtools= -Dvulkan-layers= -Dxmlconfig=disabled -Dzstd=disabled)
  ninja -C host-build -k 0 || true
  mkdir -p host-tools/bin
  find host-build -type f -perm -u+x \( -name 'mesa_clc' -o -name 'vtn_bindgen*' -o -name '*_clc' -o -name '*precomp*' \)     -exec cp {} host-tools/bin/ \;
  ls -la host-tools/bin
fi
export PATH="$WORK/host-tools/bin:$PATH"

cat > ios-cross.txt <<X
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-arch', 'arm64']
objc = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK', '-I$HERE/compat', '-I$WORK/libdrm', '-I$WORK/libdrm/include/drm']
cpp_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
c_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK', '-L$WORK/drm-standin', '-ldrm']
cpp_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK', '-L$WORK/drm-standin', '-ldrm']
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
  -Dvulkan-drivers=imagination -Dimagination-srv=true -Dgallium-drivers= \
  -Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= -Dopengl=false \
  -Dgles1=disabled -Dgles2=disabled -Dshader-cache=disabled -Dvalgrind=disabled \
  -Dlibunwind=disabled -Dzstd=disabled -Dxmlconfig=disabled -Dbuild-tests=false \
  -Dglvnd=disabled -Dlmsensors=disabled -Dtools= -Dperfetto=false -Dvulkan-layers=
ninja -C build -k 0
cd ..
lib=$(ls mesa/build/src/imagination/vulkan/libvulkan_powervr_mesa*.dylib | head -1)
cp "$lib" "$OUT/libvulkan_powervr.dylib"
# installed by the A01 drop under /private/var/a01/lib (tools/a01core-drop.py)
install_name_tool -id /private/var/a01/lib/libvulkan_powervr.dylib -add_rpath /private/var/a01/lib "$OUT/libvulkan_powervr.dylib"
strip -x "$OUT/libvulkan_powervr.dylib" || true
cp drm-standin/libdrm.2.dylib "$OUT/" && codesign -s - -f "$OUT/libdrm.2.dylib"
codesign -s - -f "$OUT/libvulkan_powervr.dylib"
otool -L "$OUT/libvulkan_powervr.dylib"
# dyld refuses the whole driver if a non-weak symbol is left to dynamic lookup and nothing defines it
strong=$(nm -m "$OUT/libvulkan_powervr.dylib" | grep "dynamically looked up" | grep -v " weak " || true)
if [ -n "$strong" ]; then echo "non-weak symbols left undefined:"; echo "$strong"; exit 1; fi
