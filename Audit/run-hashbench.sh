#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun clang -O3 -fobjc-arc Audit/hashbench.m -framework Foundation -framework QuartzCore -framework Metal -framework CoreVideo -o /tmp/metalcadence-hashbench
/tmp/metalcadence-hashbench
