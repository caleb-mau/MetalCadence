#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

duration="${1:-15}"
seed="${2:-20261125}"
base="$HOME/Library/Application Support/MetalCadence"
out="$base/audit/cpp20-cadence"
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

for experiment in 30-1-2 30-2-2 30-4-2 60-1-2 60-2-2 30-2-1 30-2-3; do
    stop_clients
    IFS=- read -r source multiplier slots <<< "$experiment"
    runid="cpp20-cadence-${experiment}-${seed}"

    args=("--benchmark" "--${multiplier}x" "--seed=$seed" "--run-id=$runid"
          "--gpu-slots=$slots" "--pool-prewarm=0" "--pool-capacity=12"
          "--pool-budget-mib=512")
    [[ "$source" == 60 ]] && args+=("--source60")

    open -n FrameLabSDK.app --args "${args[@]}"
    sleep "$duration"
    metrics="$base/sdk-metrics-$runid.jsonl"
    cp "$metrics" "$out/${experiment}.jsonl"
    EXPERIMENT="$experiment" METRICS="$metrics" python3 - <<'PY'
import os, json, statistics
from pathlib import Path

a=[json.loads(l) for l in Path(os.environ["METRICS"]).read_text().splitlines() if l]
w=[r for r in a if 5<=r["elapsed"]<=a[-1]["elapsed"]-1]
if len(w)<5 or any(r.get("windowOccluded",True) for r in w):
    raise SystemExit("Invalid benchmark visibility or duration")
if any(b["callbacks"]<=a["callbacks"] for a,b in zip(w,w[1:])):
    raise SystemExit("Invalid display callback continuity")
x,z=w[0],w[-1]
duration=z["elapsed"]-x["elapsed"]
report={
  "configuration":os.environ["EXPERIMENT"],
  "screenHz":z["windowRefreshHz"],
  "freshFPS":round((z["presented"]-x["presented"])/duration,2),
  "processingP95Ms":round(z["processingP95Ms"],2),
  "sourcePresentP99Ms":round(z["sourceToPresentP99Ms"],2),
  "gapP99Ms":round(z["gapP99Ms"],2),
  "memoryMiB":round(z["memoryMiB"],1),
  "peakPoolMiB":round(z["textureBudgetPeakMiB"],1),
  "gpuWorkPercent":round(z["gpuCommandWorkPercent"],1),
  "textureAllocations":z["textureAllocations"],
  "textureReuses":z["textureReuses"],
  "peakBatches":z["peakBatches"],
  "superseded":z["superseded"],
  "audioDropped":z["audioDropped"],
  "gpuErrors":z["gpuErrors"],
  "interpolationErrors":z["interpolationErrors"]
}
print("CADENCE",json.dumps(report,sort_keys=True))
Path(os.environ["METRICS"]).with_suffix(".summary.json").write_text(json.dumps(report,indent=2))
PY
done

stop_clients
echo "All seven workload and concurrency configurations completed"
