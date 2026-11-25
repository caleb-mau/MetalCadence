#!/usr/bin/env python3
"""Compare isolated same-seed session logs and reject presentation suspension."""
import json,sys,statistics
from pathlib import Path
def evaluate(path):
 rows=[json.loads(x) for x in Path(path).read_text().splitlines() if x]
 active=[r for r in rows if r.get("elapsed",0)>=6]
 if len(active)<12:
  raise ValueError(f"{path}: insufficient test duration ({len(active)} samples)")
 samples=[r for r in active if r["elapsed"]<=min(28,active[-1]["elapsed"])]
 if len(samples)<12:raise ValueError(f"{path}: insufficient valid observation window")
 first,last=samples[0],samples[-1]
 duration=last["elapsed"]-first["elapsed"]
 if duration<10:raise ValueError(f"{path}: <10s usable")
 if any(r.get("windowOccluded",False) for r in samples):
  raise ValueError(f"{path}: window was occluded")
 for old,new in zip(samples,samples[1:]):
  if new["callbacks"]<=old["callbacks"]:
   raise ValueError(f"{path}: display link stalled at {new['elapsed']:.1f}s")
  if new["presented"]<old["presented"]:
   raise ValueError(f"{path}: presentation counter reset")
 if last["presented"]==first["presented"]:raise ValueError(f"{path}: no fresh frames")
 return {
   "seconds":round(duration,2),
   "freshFPS":round((last["presented"]-first["presented"])/duration,2),
   "callbackHz":round((last["callbacks"]-first["callbacks"])/duration,2),
   "medianPlayoutMs":round(statistics.median(r["playoutDelayMs"] for r in samples),2),
   "finalSourceToPresentP95Ms":round(last["sourceToPresentP95Ms"],2),
   "finalSourceToPresentP99Ms":round(last["sourceToPresentP99Ms"],2),
   "finalGapP99Ms":round(last["gapP99Ms"],2),
   "superseded":last["superseded"]-first["superseded"],
   "ingressDrops":last["ingressDrops"]-first["ingressDrops"],
   "gpuErrors":last["gpuErrors"],
   "interpolationErrors":last["interpolationErrors"],
   "audioDropped":last["audioDropped"],
   "controllerReadyP90Ms":round(last.get("latencyReadyP90Ms",-1),2),
   "controllerPressureMs":round(last.get("latencyPressureSafetyMs",-1),2)
 }
if __name__=="__main__":
 for path in sys.argv[1:]:
  try: print(Path(path).name,json.dumps(evaluate(path),sort_keys=True))
  except Exception as error:
   print(Path(path).name,"INVALID:",error)
   sys.exit(1)
