#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang -O3 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/*.m Audit/rangebench.m -framework Foundation -framework Metal -framework QuartzCore -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework AudioToolbox -framework IOKit -o /tmp/metalcadence-rangebench
/tmp/metalcadence-rangebench
