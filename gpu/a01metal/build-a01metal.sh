#!/bin/bash
# build-a01metal.sh OUTDIR: libA01Metal.dylib and a01metal-test for iOS arm64 (macOS + Xcode).
set -euo pipefail
OUT=$1; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
VKH="$OUT/Vulkan-Headers"
[ -d "$VKH" ] || git clone -q --depth 1 --branch v1.3.290 https://github.com/KhronosGroup/Vulkan-Headers "$VKH"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot $SDK -fobjc-arc -O2 -Wall -I$HERE/src -I$VKH/include"
$CC -dynamiclib -install_name /usr/lib/libA01Metal.dylib -framework Foundation -framework Metal \
    "$HERE/src/A01Metal.m" -o "$OUT/libA01Metal.dylib"
$CC -framework Foundation -framework Metal "$HERE/test/a01metal-test.m" "$OUT/libA01Metal.dylib" \
    -o "$OUT/a01metal-test"
codesign -f -s - "$OUT/libA01Metal.dylib" "$OUT/a01metal-test"
rm -rf "$VKH"
ls -la "$OUT"
