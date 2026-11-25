#!/bin/bash
set -e
cd "$(dirname "$0")"
mkdir -p FrameLabCadence.app/Contents/MacOS
cp Demo/Info.plist FrameLabCadence.app/Contents/Info.plist
xcrun clang -O3 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MetalCadence.m Demo/FrameLab.m -framework Cocoa -framework Metal -framework MetalKit -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework QuartzCore -framework IOKit -o FrameLabCadence.app/Contents/MacOS/FrameLabCadence
codesign --force --sign - FrameLabCadence.app
