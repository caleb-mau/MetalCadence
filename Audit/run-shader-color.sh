#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tools/generate-shaders.py --check
mkdir -p /tmp/MetalCadenceShaders
xcrun -sdk macosx metal -std=metal3.1 -c Shaders/Production.metal \
    -o /tmp/MetalCadenceShaders/Production.air
xcrun -sdk macosx metallib /tmp/MetalCadenceShaders/Production.air \
    -o /tmp/MetalCadenceShaders/MetalCadence.metallib
xcrun clang++ -std=c++20 -O2 -fobjc-arc \
    -I Sources/MetalCadence Tests/shader-color.mm \
    -framework Foundation -framework Metal \
    -o /tmp/metalcadence-shader-color-test
/tmp/metalcadence-shader-color-test
