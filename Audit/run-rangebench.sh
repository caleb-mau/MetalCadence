#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang++ -std=c++20 -O3 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/*.mm Audit/rangebench.mm -framework Foundation -framework Metal -framework QuartzCore -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework AudioToolbox -framework IOKit -o /tmp/metalcadence-rangebench
/tmp/metalcadence-rangebench
