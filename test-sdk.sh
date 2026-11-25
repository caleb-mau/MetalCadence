#!/bin/bash
set -e
cd "$(dirname "$0")"
./scripts/format.sh --check
./test.sh
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/*.mm Tests/sdk.mm -framework Foundation -framework QuartzCore -framework Metal -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework AudioToolbox -framework IOKit -o /tmp/metalcadence-sdk-test
/tmp/metalcadence-sdk-test
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/*.mm Tests/profiles.mm -framework Foundation -framework QuartzCore -framework Metal -framework MetalFX -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework AudioToolbox -framework IOKit -o /tmp/metalcadence-profiles-test
/tmp/metalcadence-profiles-test
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MCFrameBudgetController.mm Tests/budget.mm -framework Foundation -o /tmp/metalcadence-budget-test
/tmp/metalcadence-budget-test
xcrun clang++ -std=c++20 -O3 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MCLatencyController.mm Tests/latency.mm -framework Foundation -o /tmp/metalcadence-latency-test
/tmp/metalcadence-latency-test


# Verify every successful unique source frame produces the requested output
# count. This catches silent fallback from 2× to 1×.
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence/include     Sources/MetalCadence/*.mm Tests/output.mm     -framework Foundation -framework QuartzCore -framework Metal     -framework MetalFX -framework VideoToolbox -framework CoreVideo     -framework CoreMedia -framework AVFoundation -framework AudioToolbox     -framework IOKit -o /tmp/metalcadence-output-test
/tmp/metalcadence-output-test

# Exercise C++20 lifetime and memory-budget invariants independently of the
# Objective-C adapter and the display scheduler.
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence     Tests/cpp-resource.mm -framework Foundation -framework Metal     -o /tmp/metalcadence-cpp-resource-test
/tmp/metalcadence-cpp-resource-test
