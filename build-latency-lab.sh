#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
./scripts/format.sh --check
app="MetalCadenceLatencyLab.app"
resources="$app/Contents/Resources"
binary="$app/Contents/MacOS"
mkdir -p "$resources" "$binary"
cp Demo/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable MetalCadenceLatencyLab' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.caleb.metalcadence.latencylab' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName MetalCadence Latency Lab' "$app/Contents/Info.plist"
xcrun -sdk macosx metal -std=metal3.1 -c Shaders/Production.metal \
    -o /tmp/MetalCadenceLatencyLab.air
xcrun -sdk macosx metallib /tmp/MetalCadenceLatencyLab.air \
    -o "$resources/MetalCadence.metallib"
xcrun clang++ -std=c++20 -O3 -fobjc-arc \
    -I Sources/MetalCadence/include -I Tools \
    Sources/MetalCadence/*.mm Demo/LatencyLab.mm Demo/MCWindowCapture.mm Demo/MCLocalClipSource.mm \
    -framework Cocoa -framework Metal -framework MetalKit -framework MetalFX \
    -framework VideoToolbox -framework CoreVideo -framework CoreMedia \
    -framework QuartzCore -framework IOKit -framework ScreenCaptureKit -framework AVFoundation \
    -framework AudioToolbox -framework UniformTypeIdentifiers -o "$binary/MetalCadenceLatencyLab"
codesign --force --sign - "$app"
echo "Built $app"
