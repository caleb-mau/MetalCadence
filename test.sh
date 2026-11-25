#!/bin/bash
set -e
cd "$(dirname "$0")"
./scripts/format.sh --check
swift build
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MetalCadence.mm Tests/policy.mm -framework Foundation -framework Metal -framework QuartzCore -o /tmp/metalcadence-policy-test
/tmp/metalcadence-policy-test


# Bounded C++20 telemetry must not allocate or sort on the display callback.
xcrun clang++ -std=c++20 -O2 -I Sources/MetalCadence     Tests/timing-window.mm -o /tmp/metalcadence-timing-window-test
/tmp/metalcadence-timing-window-test


# Repeated run-loop startup/shutdown must not orphan the presentation thread.
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence/include     Sources/MetalCadence/MetalCadence.mm Tests/presentation-thread.mm     -framework Foundation -framework Metal -framework QuartzCore     -o /tmp/metalcadence-presentation-thread-test
/tmp/metalcadence-presentation-thread-test

# Exercise the platform-independent deadline selector and overdue pressure policy.
xcrun clang++ -std=c++20 -O2 -I Sources/MetalCadence Tests/scheduler-policy.cpp -o /tmp/metalcadence-scheduler-policy-test
/tmp/metalcadence-scheduler-policy-test

# Scene cut guard is pure C++20 and works on Linux or macOS.
xcrun clang++ -std=c++20 -O2 -I Sources/MetalCadence Tests/scene-discontinuity.cpp \
  -o /tmp/metalcadence-scene-discontinuity-test
/tmp/metalcadence-scene-discontinuity-test
