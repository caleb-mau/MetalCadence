#!/bin/bash
set -e
cd "$(dirname "$0")"
./test.sh
xcrun clang -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/*.m Tests/sdk.m -framework Foundation -framework QuartzCore -framework Metal -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework AudioToolbox -framework IOKit -o /tmp/metalcadence-sdk-test
/tmp/metalcadence-sdk-test
