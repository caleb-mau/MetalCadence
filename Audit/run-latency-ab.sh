#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
base="$HOME/Library/Application Support/MetalCadence"
folder="$base/audit/latency-ab"
mkdir -p "$folder"
seconds="${1:-24}"
seed="${2:-20261125}"
specs="${3:-30-2 60-1}"
for spec in $specs; do
 src="${spec%-*}"; multiplier="${spec#*-}"
 for build in before after; do
   for process in FrameLabSDK VirtualCapture; do
     for pid in $(pgrep -x "$process" 2>/dev/null || true); do kill -TERM "$pid" 2>/dev/null || true; done
   done
   sleep 2
   for process in FrameLabSDK VirtualCapture; do
     for pid in $(pgrep -x "$process" 2>/dev/null || true); do kill -KILL "$pid" 2>/dev/null || true; done
   done
   if [[ "$build" == before ]]; then app=/tmp/MetalCadenceLatency/OldFloating.app
   else app=/tmp/MetalCadenceLatency/AdaptiveFloating.app; fi
   runid="latency-${build}-${spec}-${seed}"
   args=("--benchmark" "--${multiplier}x" "--seed=$seed" "--run-id=$runid")
   if [[ "$src" == 60 ]]; then args+=("--source60"); fi
   open -n "$app" --args "${args[@]}"
   sleep "$seconds"
   filename="$base/sdk-metrics-$runid.jsonl"
   cp "$filename" "$folder/$runid.jsonl"
   echo "$build $spec seed=$seed $(wc -l < "$filename") samples"
   python3 Audit/compare-latency.py "$filename"
 done
done
for process in FrameLabSDK VirtualCapture; do
 for pid in $(pgrep -x "$process" 2>/dev/null || true); do kill -TERM "$pid" 2>/dev/null || true; done
done
