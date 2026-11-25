#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-FrameLabSDK.app}"
seconds="${2:-18}"
base="$HOME/Library/Application Support/MetalCadence"
out="$base/audit/stress"
mkdir -p "$out"
stop_audit_apps() {
 pkill -x FrameLabSDK 2>/dev/null || true
 pkill -x VirtualCapture 2>/dev/null || true
 sleep 1
 for proc in FrameLabSDK VirtualCapture; do
  pgrep -x "$proc" 2>/dev/null | while read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done
 done
}
for spec in "30-2" "30-4" "60-2"; do
 source="${spec%-*}"; multiplier="${spec#*-}"
 for seed in 0 112358 314159; do
  stop_audit_apps
  runid="stress-${spec}-${seed}-${RANDOM}"
  args=("--${multiplier}x" "--benchmark" "--seed=${seed}" "--run-id=$runid")
  [[ "$source" == 60 ]] && args+=("--source60")
  open -n "$app" --args "${args[@]}"
  sleep "$seconds"
  cp "$base/sdk-metrics-$runid.jsonl" "$out/${spec}-seed${seed}.jsonl"
  echo "$spec seed=$seed rows=$(wc -l < "$out/${spec}-seed${seed}.jsonl")"
 done
done
stop_audit_apps
python3 - <<'PY'
import json,pathlib,statistics
folder=pathlib.Path.home()/"Library/Application Support/MetalCadence/audit/stress"
for path in sorted(folder.glob("*.jsonl")):
 a=[json.loads(l) for l in path.read_text().splitlines() if l]
 if len(a)<7:print(path.stem,"INSUFFICIENT");continue
 first,last=a[3],a[-1];d=last["elapsed"]-first["elapsed"]
 if d<=0 or first["presented"]>last["presented"]:print(path.stem,"INVALID");continue
 print("STRESS",path.stem,"freshFPS",round((last["presented"]-first["presented"])/d,1),"presentP99ms",round(last["gapP99Ms"],1),"sourceP99ms",round(last["sourceToPresentP99Ms"],1),"ingressDrops",last["ingressDrops"],"GPUerrors",last["gpuErrors"],"VTerrors",last["interpolationErrors"],"audioDrops",last["audioDropped"],"thermal",last["thermalState"])
PY
