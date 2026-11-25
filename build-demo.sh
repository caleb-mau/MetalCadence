#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
./scripts/format.sh --check

app="FrameLabCadence.app"
resources="$app/Contents/Resources"
macos="$app/Contents/MacOS"
shader_build="/tmp/MetalCadenceShaderBuild"
mkdir -p "$macos" "$resources" "$shader_build"
cp Demo/Info.plist "$app/Contents/Info.plist"

# The legacy demo renders its own diagnostics. It does not link the SDK's
# production shaders but its independent capture process uses the diagnostic
# library for the optional artificial-3D stress mode.
xcrun -sdk macosx metal -std=metal3.1 -c Shaders/Diagnostic.metal \
    -o "$shader_build/Diagnostic.air"
xcrun -sdk macosx metallib "$shader_build/Diagnostic.air" \
    -o "$resources/MetalCadenceDiagnostics.metallib"

xcrun -sdk macosx metal -std=metal3.1 -c Shaders/LegacyDemo.metal \
    -o "$shader_build/LegacyDemo.air"
xcrun -sdk macosx metallib "$shader_build/LegacyDemo.air" \
    -o "$resources/MetalCadenceLegacyDemo.metallib"

xcrun clang++ -std=c++20 -O3 -fobjc-arc \
    -I Sources/MetalCadence/include -I Tools \
    Sources/MetalCadence/MetalCadence.mm Demo/FrameLab.mm \
    -framework Cocoa -framework Metal -framework MetalKit \
    -framework MetalFX -framework VideoToolbox -framework CoreVideo \
    -framework CoreMedia -framework QuartzCore -framework IOKit \
    -framework AVFoundation \
    -o "$macos/FrameLabCadence"

xcrun clang++ -std=c++20 -O3 -fobjc-arc Tools/VirtualCapture.mm \
    -framework Foundation -framework Metal -framework QuartzCore \
    -framework AVFoundation -framework CoreVideo -framework CoreMedia \
    -o "$macos/VirtualCapture"

codesign --force --sign - "$macos/VirtualCapture"
codesign --force --sign - "$app"
