#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$1"; label="$2"; seconds="${3:-12}"; seed="${4:-20261125}"
base="$HOME/Library/Application Support/MetalCadence"
out="$base/audit/$label"
mkdir -p "$out"
for spec in 30-1 30-2 30-4 60-1 60-2; do
 pkill -x FrameLabSDK 2>/dev/null || true
 pkill -x VirtualCapture 2>/dev/null || true
 sleep 1
 rm -f "$base/sdk-metrics.jsonl"
 src=${spec%-*}; mult=${spec#*-}
 args=("--${mult}x" "--seed=$seed" "--benchmark")
 if [[ "$src" == 60 ]]; then args+=(--source60); fi
 open -n "$app" --args "${args[@]}"
 sleep "$seconds"
 cp "$base/sdk-metrics.jsonl" "$out/$spec.jsonl"
 echo "$label $spec $(wc -l < "$out/$spec.jsonl") samples"
done
pkill -x FrameLabSDK 2>/dev/null || true
pkill -x VirtualCapture 2>/dev/null || true
