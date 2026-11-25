#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

duration="${1:-16}"
seed="${2:-20261125}"
base="$HOME/Library/Application Support/MetalCadence"
out="$base/audit/cpp20-pools"
mkdir -p "$out"

stop_clients() {
    for process in FrameLabSDK VirtualCapture; do
        for pid in $(pgrep -x "$process" 2>/dev/null || true); do
            kill -TERM "$pid" 2>/dev/null || true
        done
    done
    sleep 2
    for process in FrameLabSDK VirtualCapture; do
        for pid in $(pgrep -x "$process" 2>/dev/null || true); do
            kill -KILL "$pid" 2>/dev/null || true
        done
    done
}

for capacity in 0 8 12 16 24 32; do
    stop_clients
    if [[ "$capacity" -eq 0 ]]; then
        prewarm=0
        limit=24
    else
        prewarm="$capacity"
        limit="$capacity"
    fi

    runid="cpp20-pool-${capacity}-${seed}"
    open -n FrameLabSDK.app --args --benchmark --2x --seed="$seed" \
        --run-id="$runid" --pool-prewarm="$prewarm" \
        --pool-capacity="$limit" --pool-budget-mib=1024 --gpu-slots=2
    sleep "$duration"

    source="$base/sdk-metrics-$runid.jsonl"
    cp "$source" "$out/${capacity}.jsonl"
    CAPACITY="$capacity" FILENAME="$source" python3 - <<'PY'
import json, os
from pathlib import Path

rows = [json.loads(line) for line in Path(os.environ["FILENAME"]).read_text().splitlines() if line]
if len(rows) < 10:
    raise SystemExit("Insufficient observation count")
valid = [row for row in rows if 5 <= row["elapsed"] <= rows[-1]["elapsed"] - 1]
if len(valid) < 5 or any(r.get("windowOccluded", True) for r in valid):
    raise SystemExit("Benchmark invalid: occluded window or too few samples")
if any(b["callbacks"] <= a["callbacks"] for a, b in zip(valid, valid[1:])):
    raise SystemExit("Benchmark invalid: stopped display callbacks")
first, last = valid[0], valid[-1]
seconds = last["elapsed"] - first["elapsed"]
metrics = {
    "capacity": int(os.environ["CAPACITY"]),
    "seconds": round(seconds, 2),
    "freshFPS": round((last["presented"] - first["presented"]) / seconds, 3),
    "p95ProcessingMs": round(last["processingP95Ms"], 3),
    "p99SourceToPresentMs": round(last["sourceToPresentP99Ms"], 3),
    "p99PresentGapMs": round(last["gapP99Ms"], 3),
    "textureAllocations": last["textureAllocations"],
    "textureReuses": last["textureReuses"],
    "nativeTextureAllocations": last["nativeTextureAllocations"],
    "nativeTextureReuses": last["nativeTextureReuses"],
    "textureBudgetPeakMiB": round(last["textureBudgetPeakMiB"], 1),
    "memoryMiB": round(last["memoryMiB"], 1),
    "cpuPercentOneCore": round(last["cpuPercentOneCore"], 1),
    "gpuCommandWorkPercent": round(last.get("gpuCommandWorkPercent", 0), 1),
    "gpuErrors": last["gpuErrors"],
    "interpolationErrors": last["interpolationErrors"],
    "audioDropped": last["audioDropped"],
    "thermalState": last["thermalState"],
}
Path(os.environ["FILENAME"]).with_suffix(".summary.json").write_text(json.dumps(metrics, indent=2))
print("POOL", json.dumps(metrics, sort_keys=True))
PY
done
stop_clients
echo "Six pool profiles validated. Raw traces: $out"
