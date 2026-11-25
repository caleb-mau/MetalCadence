#!/bin/bash
set -e
cd "$(dirname "$0")"
./scripts/format.sh --check
./test.sh
xcrun clang -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/*.m Tests/sdk.m -framework Foundation -framework QuartzCore -framework Metal -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework AudioToolbox -framework IOKit -o /tmp/metalcadence-sdk-test
/tmp/metalcadence-sdk-test
xcrun clang -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/*.m Tests/profiles.m -framework Foundation -framework QuartzCore -framework Metal -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework AudioToolbox -framework IOKit -o /tmp/metalcadence-profiles-test
/tmp/metalcadence-profiles-test
xcrun clang -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MCFrameBudgetController.m Tests/budget.m -framework Foundation -o /tmp/metalcadence-budget-test
/tmp/metalcadence-budget-test
xcrun clang -O3 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MCLatencyController.m Tests/latency.m -framework Foundation -o /tmp/metalcadence-latency-test
/tmp/metalcadence-latency-test


# Verify every successful unique source frame produces the requested output
# count. This catches silent fallback from 2× to 1×.
xcrun clang -O2 -fobjc-arc -I Sources/MetalCadence/include     Sources/MetalCadence/*.m Tests/output.m     -framework Foundation -framework QuartzCore -framework Metal     -framework MetalFX -framework VideoToolbox -framework CoreVideo     -framework CoreMedia -framework AVFoundation -framework AudioToolbox     -framework IOKit -o /tmp/metalcadence-output-test
/tmp/metalcadence-output-test
