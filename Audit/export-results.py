#!/usr/bin/env python3
"""Build portable evidence from isolated replay benchmark logs without leaking raw media."""
from pathlib import Path
from collections import defaultdict
import json,statistics
root=Path.home()/"Library/Application Support/MetalCadence"
audit=root/"audit"
def load(path):
 return [json.loads(s) for s in path.read_text().splitlines() if s.strip()]
def mode(path):
 rows=load(path)
 if len(rows)<6:raise ValueError(f"Not enough observations: {path}")
 if any(b["elapsed"]<=a["elapsed"] or b["presented"]<a["presented"] for a,b in zip(rows,rows[1:])):raise ValueError(f"Mixed source or counter reset in {path}")
 start=rows[3];final=rows[-1];duration=final["elapsed"]-start["elapsed"]
 return {"durationSeconds":round(duration,3),"freshFPS":round((final["presented"]-start["presented"])/duration,3),
 "processingP50Ms":final.get("processingP50Ms"),"processingP95Ms":final["processingP95Ms"],"processingP99Ms":final["processingP99Ms"],
 "presentationGapP95Ms":final["gapP95Ms"],"presentationGapP99Ms":final["gapP99Ms"],
 "sourceToPresentP95Ms":final["sourceToPresentP95Ms"],"sourceToPresentP99Ms":final["sourceToPresentP99Ms"],
 "gpuScalingMedianMs":final["scaleGPUMedianMs"],"memoryMiB":final["memoryMiB"],
 "textureAllocations":final["textureAllocations"],"textureReuses":final["textureReuses"],
 "ingressDrops":final["ingressDrops"],"superseded":final["superseded"],
 "gpuErrors":final["gpuErrors"],"vtErrors":final["interpolationErrors"],"audioDropped":final["audioDropped"],
 "thermalState":final["thermalState"]}
data={"environment":{"hardware":"Apple M5 MacBook Air, 10 GPU cores","desktop":"2560x1440 main LG UltraGear at 165 Hz, secondary rotated LG","source":"Big Buck Bunny, independently decoded 1920x1080 at 60Hz, 30 or 60 unique frames","audio":"48 kHz stereo PCM from recording, no synthetic tone","clock":"source PTS to Metal drawable presentation callback (software), not controller-to-photon","replaySeed":20261125},"matrices":{},"randomizedStress":{},"endurance":{},"displayTest":{}}
for label in ("corrected-vt","corrected-blend"):
 folder=audit/label
 data["matrices"][label]={p.stem:mode(p) for p in sorted(folder.glob("*.jsonl"))}
 if len(data["matrices"][label])!=5:raise ValueError(f"Expected five configurations for {label}")
for p in sorted((audit/"stress").glob("*.jsonl")):
 data["randomizedStress"][p.stem]=mode(p)
if len(data["randomizedStress"])!=9:raise ValueError("Expected nine randomized/seeded stress cases")
for label,file in (("fixed4x","thermal-4x.jsonl"),("adaptive4x","thermal-adaptive4x-confirmed-90210.jsonl")):
 rows=load(audit/file)
 if any(b["elapsed"]<=a["elapsed"] or b["presented"]<a["presented"] or b["multiplier"]!=4 for a,b in zip(rows,rows[1:])):raise ValueError(f"Invalid endurance series: {file}")
 d={"totalSeconds":round(rows[-1]["elapsed"],1)}
 for lo,hi in ((20,80),(140,200),(180,200)):
  x=[r for r in rows if lo<=r["elapsed"]<=hi]
  if not x:continue
  fps=sorted(r["rollingFPS"] for r in x)
  d[f"{lo}-{hi}s"]={"meanFreshFPS":round(statistics.mean(fps),2),"minOneSecondFPS":round(fps[0],2),"p05OneSecondFPS":round(fps[int((len(fps)-1)*.05)],2)}
 d["finalSourceToPresentP99Ms"]=rows[-1]["sourceToPresentP99Ms"];d["finalMemoryMiB"]=rows[-1]["memoryMiB"]
 d["gpuErrors"]=rows[-1]["gpuErrors"];d["vtErrors"]=rows[-1]["interpolationErrors"]
 d["thermalStates"]=sorted(set(r["thermalState"] for r in rows))
 if label=="adaptive4x":
  first=next((r for r in rows if r.get("fallbackTransitions",0)>0),None)
  if first:d["firstFallbackSeconds"]=round(first["elapsed"],1)
  d["finalActiveMultiplier"]=rows[-1].get("activeMultiplier")
 data["endurance"][label]=d
phases=defaultdict(list)
for row in load(root/"sdk-metrics-display-stress-1.jsonl"):phases[row.get("uiPhase","unknown")].append(row)
for phase,rows in phases.items():
 last=rows[-1];data["displayTest"][phase]={"durationSamples":len(rows),"meanFreshFPS":round(statistics.mean(r["rollingFPS"] for r in rows),2),"displayRefreshHz":last.get("windowRefreshHz"),"fullscreen":last.get("windowIsFullscreen"),"gpuErrors":last["gpuErrors"],"vtErrors":last["interpolationErrors"],"noDrawable":last["noDrawable"],"presentationGapP99Ms":last["gapP99Ms"]}
out=Path("Audit/verified-results.json");out.write_text(json.dumps(data,indent=2,sort_keys=True)+"\n")
print("Exported",out,round(out.stat().st_size/1024,1),"KiB; 10 seeded mode cases, nine stress cases, two endurance cases, five display phases")
