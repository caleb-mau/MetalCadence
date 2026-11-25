#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang++ -std=c++20 -O3 -fobjc-arc Audit/hashbench.mm -framework Foundation -framework QuartzCore -framework Metal -framework CoreVideo -o /tmp/metalcadence-hashbench
/tmp/metalcadence-hashbench
