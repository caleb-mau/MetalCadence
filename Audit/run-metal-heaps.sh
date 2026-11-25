#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/format.sh --check
xcrun clang++ -std=c++20 -O3 -fobjc-arc Audit/metal-heap-bench.mm \
    -framework Foundation -framework Metal -framework QuartzCore \
    -o /tmp/metalcadence-heap-bench
/tmp/metalcadence-heap-bench
