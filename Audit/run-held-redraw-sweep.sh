#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

seconds="${1:-18}"
seed="${2:-20261125}"
out="$HOME/Library/Application Support/MetalCadence/audit/presentation-v2"
mkdir -p "$out"

stop_clients() {
    for process in FrameLabSDK VirtualCapture; do
        for pid in $(pgrep -x "$process" 2>/dev/null || true); do
            kill -TERM "$pid" 2>/dev/null || true
        done
    done
    sleep 2
}

for mode in draw every2 every3 skip; do
    stop_clients
    runid="pv2-held-${mode}-${seed}"
    args=("--benchmark" "--2x" "--seed=$seed" "--run-id=$runid")
    case "$mode" in
        draw) args+=("--draw-held") ;;
        every2) args+=("--held-redraw-every=2") ;;
        every3) args+=("--held-redraw-every=3") ;;
        skip) args+=("--skip-held") ;;
    esac

    open -n FrameLabSDK.app --args "${args[@]}"
    sleep "$seconds"

    metrics="$HOME/Library/Application Support/MetalCadence/sdk-metrics-$runid.jsonl"
    cp "$metrics" "$out/${mode}-${seed}.jsonl"
    MODE="$mode" METRICS="$metrics" python3 - <<'PY'
import os, json
from pathlib import Path

a=[json.loads(l) for l in Path(os.environ["METRICS"]).read_text().splitlines() if l]
w=[r for r in a if 5<=r["elapsed"]<=a[-1]["elapsed"]-1]
if len(w)<7 or any(r.get("windowOccluded",True) for r in w):
    raise SystemExit("Invalid window/duration")
if any(b["callbacks"]<=a["callbacks"] for a,b in zip(w,w[1:])):
    raise SystemExit("Display link suspended")
x,z=w[0],w[-1]
report={k:z.get(k) for k in (
    "windowRefreshHz","observedCallbackHz","redundantDrawsSkipped",
    "heldRefreshDrawEvery","skipHeldDraws","displayRefreshPresentations",
    "callbackGapP99Ms","callbackDeadlineMisses","sourceToPresentP99Ms",
    "gapP95Ms","gapP99Ms","readyToSelectP99Ms","presentationTargetErrorP99Ms",
    "cpuPercentOneCore","gpuCommandWorkPercent","displayGPUms",
    "audioDropped","gpuErrors","interpolationErrors","memoryMiB")}
report["mode"]=os.environ["MODE"]
report["freshFPS"]=round((z["presented"]-x["presented"])/(z["elapsed"]-x["elapsed"]),3)
print("HELD_SWEEP",json.dumps(report,sort_keys=True))
PY
done
stop_clients
