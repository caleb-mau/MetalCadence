#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
./scripts/format.sh --check
mkdir -p .build/metalfx
xcrun -sdk macosx metal -std=metal3.1 -c Shaders/Production.metal \
  -o .build/metalfx/Production.air
xcrun -sdk macosx metal -std=metal3.1 -c Shaders/UpscaleExport.metal \
  -o .build/metalfx/UpscaleExport.air
xcrun -sdk macosx metallib .build/metalfx/Production.air .build/metalfx/UpscaleExport.air \
  -o .build/metalfx/MetalFX.metallib
xcrun clang++ -std=c++20 -O3 -fobjc-arc -I Sources/MetalCadence/include \
  Demo/UpscaleClip.mm -framework Foundation -framework AVFoundation \
  -framework CoreVideo -framework CoreMedia -framework Metal \
  -framework MetalFX -framework QuartzCore \
  -o .build/metalfx/upscale-clip
echo "Built .build/metalfx/upscale-clip"
