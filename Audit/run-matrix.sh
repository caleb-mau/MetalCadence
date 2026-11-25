#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$1"; label="$2"; seconds="${3:-12}"; seed="${4:-20261125}"; extra="${5:-}"
base="$HOME/Library/Application Support/MetalCadence"
out="$base/audit/$label"
mkdir -p "$out"
stop_audit_apps() {
 pkill -x FrameLabSDK 2>/dev/null || true
 pkill -x VirtualCapture 2>/dev/null || true
 sleep 1
 for proc in FrameLabSDK VirtualCapture; do
  pgrep -x "$proc" 2>/dev/null | while read -r pid; do
   kill -KILL "$pid" 2>/dev/null || true
  done
 done
}
for spec in 30-1 30-2 30-4 60-1 60-2; do
 stop_audit_apps
 src=${spec%-*}; mult=${spec#*-}
 runid="${label}-${spec}-${seed}-${RANDOM}"
 args=("--${mult}x" "--seed=$seed" "--benchmark" "--run-id=$runid")
 if [[ "$src" == 60 ]]; then args+=(--source60); fi
 if [[ -n "$extra" ]]; then args+=("$extra"); fi
 open -n "$app" --args "${args[@]}"
 sleep "$seconds"
 cp "$base/sdk-metrics-$runid.jsonl" "$out/$spec.jsonl"
 echo "$label $spec $(wc -l < "$out/$spec.jsonl") samples"
done
stop_audit_apps
