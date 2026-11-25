#!/bin/bash
set -e
cd "$(dirname "$0")"
app=FrameLabSDK.app
mkdir -p "$app/Contents/MacOS"
cp Demo/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable FrameLabSDK' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.caleb.metalcadence.sdkdemo' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName FrameLabSDK' "$app/Contents/Info.plist"
xcrun clang -O3 -fobjc-arc -I Sources/MetalCadence/include -I Tools Sources/MetalCadence/*.m Demo/SDKDemo.m -framework Cocoa -framework Metal -framework MetalKit -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework QuartzCore -framework IOKit -framework AVFoundation -framework AudioToolbox -o "$app/Contents/MacOS/FrameLabSDK"
xcrun clang -O3 -fobjc-arc Tools/VirtualCapture.m -framework Foundation -framework Metal -framework QuartzCore -framework AVFoundation -framework CoreVideo -framework CoreMedia -o "$app/Contents/MacOS/VirtualCapture"
codesign --force --sign - "$app/Contents/MacOS/VirtualCapture"
codesign --force --sign - "$app"
