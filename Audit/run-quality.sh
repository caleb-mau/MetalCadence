#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang -O3 -fobjc-arc Audit/quality.m -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia -o /tmp/metalcadence-quality
/tmp/metalcadence-quality "${1:-240}"
