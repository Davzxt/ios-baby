#!/bin/bash
# build-a01metal.sh OUTDIR: libA01Metal.dylib and a01metal-test for iOS arm64 (macOS + Xcode).
set -euo pipefail
OUT=$1; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
VKH="$OUT/Vulkan-Headers"
[ -d "$VKH" ] || git clone -q --depth 1 --branch v1.3.290 https://github.com/KhronosGroup/Vulkan-Headers "$VKH"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot $SDK -fobjc-arc -O2 -Wall -I$HERE/src -I$VKH/include"
$CC -dynamiclib -install_name /private/var/a01/lib/libA01Metal.dylib -framework Foundation -framework Metal \
    "$HERE/src/A01Metal.m" -o "$OUT/libA01Metal.dylib"
# test shaders: GLSL -> SPIR-V (glslang), embedded in the test as C arrays
glslangValidator -V -o "$OUT/tri.vert.spv" "$HERE/test/tri.vert"
glslangValidator -V -o "$OUT/tri.frag.spv" "$HERE/test/tri.frag"
glslangValidator -V -o "$OUT/tex.vert.spv" "$HERE/test/tex.vert"
glslangValidator -V -o "$OUT/tex.frag.spv" "$HERE/test/tex.frag"
glslangValidator -V -o "$OUT/uv.frag.spv" "$HERE/test/uv.frag"
( cd "$OUT" && xxd -i tex.vert.spv && xxd -i tex.frag.spv && xxd -i uv.frag.spv ) \
    | sed -e 's/^unsigned char/static const unsigned char __attribute__((aligned(4)))/' -e 's/^unsigned int/static const unsigned int/' \
    > "$OUT/tex_spv.h"
( cd "$OUT" && xxd -i tri.vert.spv && xxd -i tri.frag.spv ) \
    | sed -e 's/^unsigned char/static const unsigned char/' -e 's/^unsigned int/static const unsigned int/' \
    > "$OUT/tri_spv.h"
$CC -I"$OUT" -framework Foundation -framework Metal "$HERE/test/a01metal-test.m" "$HERE/test/a01vktex.c" "$OUT/libA01Metal.dylib" \
    -o "$OUT/a01metal-test"
codesign -f -s - "$OUT/libA01Metal.dylib" "$OUT/a01metal-test"
rm -rf "$VKH"
ls -la "$OUT"

# The Metal driver bundle iOS loads (MetalPluginName A01Metal, class A01MTLDevice):
# /System/Library/Extensions/A01Metal.bundle, installed by the A01 drop (tools/a01core-drop.py).
B="$OUT/A01Metal.bundle"
mkdir -p "$B"
VKH="$OUT/Vulkan-Headers"
[ -d "$VKH" ] || git clone -q --depth 1 --branch v1.3.290 https://github.com/KhronosGroup/Vulkan-Headers "$VKH"
$CC -I"$VKH/include" -dynamiclib -install_name /System/Library/Extensions/A01Metal.bundle/A01Metal \
    -framework Foundation -framework Metal "$HERE/src/A01Metal.m" -o "$B/A01Metal"
cat > "$B/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>A01Metal</string>
	<key>CFBundleIdentifier</key><string>com.a01core.A01Metal</string>
	<key>CFBundleName</key><string>A01Metal</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>NSPrincipalClass</key><string>A01MTLDevice</string>
</dict>
</plist>
PLIST
codesign -f -s - "$B/A01Metal"
rm -rf "$VKH"
ls -la "$B"
