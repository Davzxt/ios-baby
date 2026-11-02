#!/bin/bash
# Galaxy A01 Core: OpenGL ES for CoreAnimation's render server, the HakiOS/Bergamota way (gpu/eagl,
# gpu/hakios-gl): backboardd gets an EAGL context from the shim libheroeagl.dylib (inserted by the
# kernel, bsd/dev/herolte_gl.c, boot-arg herogl=1), which renders through Mesa's OSMesa:
#   GALLIUM_DRIVER=softpipe  CPU rendering (works without the GPU)
#   GALLIUM_DRIVER=zink      OpenGL over Vulkan: Zink -> libvulkan.1.dylib (a01vkloader.c) ->
#                            the GE8100 ICD (gpu/a01vulkan) -> DDK 1.11 -> GE8100   (boot-arg a01gl=zink)
# Runs on a macOS runner with Xcode (iphoneos SDK).
#
#   build-a01gl.sh WORK OUT
#
# OUT/lib: libOSMesa.8.dylib, libglapi.0.dylib (@rpath names), libvulkan.1.dylib, libheroeagl.dylib;
# all installed by the A01 drop under /private/var/a01/lib. Ad-hoc signed; nothing of Apple's.
set -euo pipefail

WORK=$(mkdir -p "$1" && cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
MESA_TAG=${MESA_TAG:-mesa-25.0.7}
MIN_IOS=16.0
LIBDIR=/private/var/a01/lib
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC_IOS="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=$MIN_IOS -isysroot $SDK"

cd "$WORK"
[ -d mesa ] || git clone -q --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git mesa
python3 "$HERE/../mesa/patch-mesa.py" mesa
python3 "$HERE/patch-a01gl.py" mesa
mkdir -p pc

cat > ios-cross.txt <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-arch', 'arm64']
objc = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
ranlib = ['xcrun', '--sdk', 'iphoneos', 'ranlib']
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
cpp_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
objc_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
c_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
cpp_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
objc_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']

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
EOF

cd mesa
[ -d build ] || meson setup build --cross-file ../ios-cross.txt \
  --buildtype=release -Db_ndebug=true -Dprefix=/ \
  -Dgallium-drivers=softpipe,zink -Dvulkan-drivers= \
  -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= \
  -Dosmesa=true -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dshared-glapi=enabled \
  -Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled \
  -Dxmlconfig=disabled -Dbuild-tests=false -Dglvnd=disabled -Dlmsensors=disabled \
  -Dgallium-opencl=disabled -Dgallium-rusticl=false -Dgallium-xa=disabled \
  -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dtools= -Dperfetto=false
ninja -C build -k 0
cd ..

mkdir -p "$OUT/lib"
osmesa=$(ls mesa/build/src/gallium/targets/osmesa/libOSMesa.8*.dylib | head -1)
glapi=$(ls mesa/build/src/mapi/shared-glapi/libglapi.0*.dylib 2>/dev/null | head -1 || true)
cp "$osmesa" "$OUT/lib/libOSMesa.8.dylib"
[ -n "$glapi" ] && cp "$glapi" "$OUT/lib/libglapi.0.dylib"
for lib in "$OUT"/lib/*.dylib; do
  name=$(basename "$lib")
  install_name_tool -id "@rpath/$name" "$lib"
  for dep in $(otool -L "$lib" | awk 'NR > 1 { print $1 }'); do
    case "$dep" in
      /usr/lib/*|/System/*|@rpath/*) ;;
      *) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib" ;;
    esac
  done
  install_name_tool -add_rpath "$LIBDIR" "$lib" 2>/dev/null || true
done

# The Vulkan "loader" Zink opens (gpu/a01gl/a01vkloader.c).
$CC_IOS -O2 -Wall -dynamiclib -fvisibility=hidden -install_name "$LIBDIR/libvulkan.1.dylib" \
  -o "$OUT/lib/libvulkan.1.dylib" "$HERE/a01vkloader.c"

# The EAGL shim (gpu/eagl, Bergamota's, as on the S7) over this OSMesa, installed under $LIBDIR.
EAGL="$HERE/../eagl"
OBJ=$(mktemp -d)
python3 "$EAGL/tools/gen_gl_stubs.py" > "$OBJ/gl_stubs.c"
CF="-O2 -g -fvisibility=hidden -Wall -Wno-deprecated-declarations -Wno-unused-function -I$EAGL/src -I$WORK/mesa/include"
$CC_IOS $CF -c "$OBJ/gl_stubs.c" -o "$OBJ/gl_stubs.o"
for f in gl_resolve gl_unimpl osm macro_ctx macro_slots hero_log hero_backboardd hero_prof; do
  $CC_IOS $CF -c "$EAGL/src/$f.c" -o "$OBJ/$f.o"
done
$CC_IOS $CF -fno-objc-arc -fobjc-exceptions -DEAGL_INJECT -c "$EAGL/src/eagl.m" -o "$OBJ/eagl.o"
$CC_IOS -dynamiclib -o "$OUT/lib/libheroeagl.dylib" \
  "$OBJ"/{gl_stubs,gl_resolve,gl_unimpl,osm,macro_ctx,macro_slots,hero_log,hero_backboardd,hero_prof,eagl}.o \
  -install_name "$LIBDIR/libheroeagl.dylib" \
  -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface \
  -L "$OUT/lib" -lOSMesa.8 -Wl,-rpath,"$LIBDIR" -Wl,-undefined,error

for f in "$OUT"/lib/*.dylib; do
  codesign -s - -f "$f"
  otool -L "$f"
done
ls -la "$OUT/lib"
