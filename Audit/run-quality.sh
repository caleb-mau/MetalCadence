#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang++ -std=c++20 -O3 -fobjc-arc Audit/quality.mm -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia -o /tmp/metalcadence-quality
/tmp/metalcadence-quality "${1:-240}"
