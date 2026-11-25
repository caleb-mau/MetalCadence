#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build
xcrun clang -O2 -fobjc-arc -I Sources/MetalCadence/include Sources/MetalCadence/MetalCadence.m Tests/policy.m -framework Foundation -framework Metal -framework QuartzCore -o /tmp/metalcadence-policy-test
/tmp/metalcadence-policy-test
