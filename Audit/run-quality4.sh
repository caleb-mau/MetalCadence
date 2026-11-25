#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang -O3 -fobjc-arc Audit/quality4.m -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia -o /tmp/metalcadence-quality4
/tmp/metalcadence-quality4 "${1:-120}"
