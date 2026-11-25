#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
./scripts/format.sh --check

app="FrameLabSDK.app"
resources="$app/Contents/Resources"
macos="$app/Contents/MacOS"
shader_build="/tmp/MetalCadenceShaderBuild"
mkdir -p "$resources" "$macos" "$shader_build"

cp Demo/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable FrameLabSDK' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.caleb.metalcadence.sdkdemo' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName FrameLabSDK' "$app/Contents/Info.plist"

compile_shader() {
    local name="$1"
    local output="$2"
    xcrun -sdk macosx metal -std=metal3.1 -c "Shaders/$name.metal" \
        -o "$shader_build/$name.air"
    xcrun -sdk macosx metallib "$shader_build/$name.air" \
        -o "$resources/$output.metallib"
}
compile_shader Production MetalCadence
compile_shader Diagnostic MetalCadenceDiagnostics

frameworks=(
    -framework Cocoa
    -framework Metal
    -framework MetalKit
    -framework MetalFX
    -framework VideoToolbox
    -framework CoreVideo
    -framework CoreMedia
    -framework QuartzCore
    -framework IOKit
    -framework AVFoundation
    -framework AudioToolbox
)
xcrun clang++ -std=c++20 -O3 -fobjc-arc \
    -I Sources/MetalCadence/include -I Tools \
    Sources/MetalCadence/*.mm Demo/SDKDemo.mm \
    "${frameworks[@]}" \
    -o "$macos/FrameLabSDK"

xcrun clang++ -std=c++20 -O3 -fobjc-arc Tools/VirtualCapture.mm \
    -framework Foundation -framework Metal -framework QuartzCore \
    -framework AVFoundation -framework CoreVideo -framework CoreMedia \
    -o "$macos/VirtualCapture"

codesign --force --sign - "$macos/VirtualCapture"
codesign --force --sign - "$app"
