#!/usr/bin/env bash
# Compare display-link placement using the same app, source and random seed.
# Usage: ./Audit/run-presentation-v2.sh [seconds] [seed] [sourceFPS] [multiplier] [requestedHz]
set -euo pipefail
cd "$(dirname "$0")/.."

seconds="${1:-22}"
seed="${2:-20261125}"
source="${3:-30}"
factor="${4:-2}"
requested_hz="${5:-165}"
base="$HOME/Library/Application Support/MetalCadence"
out="$base/audit/presentation-v2"
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

for placement in main dedicated; do
    stop_clients
    runid="pv2-${placement}-${source}-${factor}-${seed}-${requested_hz}"
    args=("--benchmark" "--${factor}x" "--seed=$seed" "--run-id=$runid"
          "--refresh-hz=$requested_hz")
    [[ "$source" == 60 ]] && args+=("--source60")
    if [[ "$placement" == dedicated ]]; then
        args+=("--dedicated-display")
    else
        args+=("--main-display")
    fi

    open -n FrameLabSDK.app --args "${args[@]}"
    sleep "$seconds"

    log="$base/sdk-metrics-$runid.jsonl"
    cp "$log" "$out/${placement}-${source}-${factor}-${seed}-${requested_hz}.jsonl"
    RUN="$runid" LOG="$log" python3 - <<'PY'
import json
import os
import statistics
from pathlib import Path

a = [json.loads(line) for line in Path(os.environ["LOG"]).read_text().splitlines()
     if line.strip()]
w = [r for r in a if 5 <= r["elapsed"] <= a[-1]["elapsed"] - 1]
if len(w) < 8:
    raise SystemExit("Insufficient measurement window")
if any(r.get("windowOccluded", True) for r in w):
    raise SystemExit("Invalid: benchmark window occluded")
if any(b["callbacks"] <= a["callbacks"] for a, b in zip(w, w[1:])):
    raise SystemExit("Invalid: display-link callbacks stopped")
x, z = w[0], w[-1]
duration = z["elapsed"] - x["elapsed"]

fields = [
    "windowRefreshHz", "requestedCallbackHz", "observedCallbackHz",
    "dedicatedRenderThread", "selectionMode", "callbackGapP99Ms",
    "callbackLeadP50Ms", "readyToSelectP95Ms", "readyToSelectP99Ms",
    "encodeCostP95Ms", "gpuQueueWaitP95Ms", "selectToPresentP99Ms",
    "presentationTargetErrorP99Ms", "sourceToPresentP50Ms",
    "sourceToPresentP95Ms", "sourceToPresentP99Ms", "gapP95Ms",
    "gapP99Ms", "callbackDeadlineMisses", "superseded",
    "interactiveSuperseded", "overflow", "busyRefreshes",
    "audioDropped", "gpuErrors", "interpolationErrors",
    "memoryMiB", "cpuPercentOneCore", "thermalState"
]
report = {name: z.get(name) for name in fields}
report["freshFPS"] = round((z["presented"] - x["presented"]) / duration, 3)
report["playoutMedianMs"] = round(statistics.median(r["playoutDelayMs"] for r in w), 3)
report["durationSeconds"] = round(duration, 3)
report["session"] = os.environ["RUN"]
Path(os.environ["LOG"]).with_suffix(".summary.json").write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n")
print("PRESENTATION_V2", json.dumps(report, sort_keys=True))
PY
done

stop_clients
