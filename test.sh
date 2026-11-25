#!/bin/bash
set -e
cd "$(dirname "$0")"
./scripts/format.sh --check
swift build
xcrun clang++ -std=c++20 -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MetalCadence.mm Tests/policy.mm -framework Foundation -framework Metal -framework QuartzCore -o /tmp/metalcadence-policy-test
/tmp/metalcadence-policy-test
