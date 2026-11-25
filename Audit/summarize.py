#!/usr/bin/env python3
"""Reject mixed mode, counter-reset and physically impossible benchmark sessions."""
import json, pathlib, statistics, sys
root = pathlib.Path.home() / "Library/Application Support/MetalCadence/audit"
for label in sys.argv[1:] or ["baseline","pacing","pipeline","completion"]:
 for path in sorted((root / label).glob("*.jsonl")):
  rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
  source, multiplier = map(int, path.stem.split("-"))
  if len(rows) < 5 or any(x["multiplier"] != multiplier for x in rows) or any(b["elapsed"] <= a["elapsed"] or b["presented"] < a["presented"] for a,b in zip(rows,rows[1:])):
   print(label,path.stem,"INVALID: mixed mode, reset or insufficient data")
   continue
  first = rows[3]; last = rows[-1]; duration = last["elapsed"]-first["elapsed"]; fps = (last["presented"]-first["presented"])/duration
  if fps > source*multiplier*1.1:
   print(label,path.stem,"INVALID: implausible fresh FPS",fps)
   continue
  result = {"seconds":round(duration,2),"fps":round(fps,2),"processingP50Ms":last.get("processingP50Ms"),"processingP95Ms":last.get("processingP95Ms"),"processingP99Ms":last.get("processingP99Ms"),"gapP95Ms":last.get("gapP95Ms"),"gapP99Ms":last.get("gapP99Ms"),"sourceToPresentP95Ms":last.get("sourceToPresentP95Ms"),"sourceToPresentP99Ms":last.get("sourceToPresentP99Ms"),"cpuMedian":statistics.median(x["cpuPercentOneCore"] for x in rows[4:]),"gpuMedian":statistics.median(x["systemGPUPercent"] for x in rows[4:]),"memoryMiB":last.get("memoryMiB"),"scaleGPUMedianMs":last.get("scaleGPUMedianMs"),"scaleGPUExecutionSeconds":last.get("scaleGPUExecutionSeconds"),"scaleGPUQueueGapSeconds":last.get("scaleGPUQueueGapSeconds"),"textureAllocations":last.get("textureAllocations"),"textureReuses":last.get("textureReuses"),"ingressDrops":last.get("ingressDrops"),"superseded":last.get("superseded"),"deadlineMisses":last.get("callbackDeadlineMisses"),"gpuErrors":last.get("gpuErrors"),"interpolationErrors":last.get("interpolationErrors"),"audioDropped":last.get("audioDropped"),"thermalState":last.get("thermalState"),"duplicateP95Ms":last.get("duplicateP95Ms"),"peakBatches":last.get("peakBatches")}
  print(label,path.stem,json.dumps(result,separators=(",",":")))
