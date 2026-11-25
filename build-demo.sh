#!/bin/bash
set -e
cd "$(dirname "$0")"
./scripts/format.sh --check
mkdir -p FrameLabCadence.app/Contents/MacOS
cp Demo/Info.plist FrameLabCadence.app/Contents/Info.plist
xcrun clang -O3 -fobjc-arc -I Sources/MetalCadence/include -I Tools Sources/MetalCadence/MetalCadence.m Demo/FrameLab.m -framework Cocoa -framework Metal -framework MetalKit -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework QuartzCore -framework IOKit -framework AVFoundation -o FrameLabCadence.app/Contents/MacOS/FrameLabCadence
codesign --force --sign - FrameLabCadence.app
xcrun clang -O3 -fobjc-arc Tools/VirtualCapture.m -framework Foundation -framework Metal -framework QuartzCore -framework AVFoundation -framework CoreVideo -framework CoreMedia -o FrameLabCadence.app/Contents/MacOS/VirtualCapture
codesign --force --sign - FrameLabCadence.app/Contents/MacOS/VirtualCapture
codesign --force --sign - FrameLabCadence.app
