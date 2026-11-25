#!/usr/bin/env python3
"""Export verified Presentation Pipeline V2 experiments from isolated JSONL.

The original replay movie is not redistributed. Passes/failures are derived
from actual Mac display-link callbacks and GPU/video/audio SDK counters.
"""
from collections import defaultdict
from pathlib import Path
import json
import statistics

root = Path(__file__).resolve().parent.parent
support = Path.home() / "Library/Application Support/MetalCadence"
traces = support / "audit/presentation-v2"


def load(path: Path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line]
    if len(rows) < 8:
        raise ValueError(f"Insufficient benchmark samples: {path}")
    for previous, current in zip(rows, rows[1:]):
        if (current["elapsed"] <= previous["elapsed"]
                or current["presented"] < previous["presented"]
                or current["callbacks"] < previous["callbacks"]):
            raise ValueError(f"Non-monotonic or mixed benchmark: {path}")
    return rows


def summarize(path: Path):
    rows = load(path)
    observed = [row for row in rows
                if 5 <= row["elapsed"] <= rows[-1]["elapsed"] - 1]
    if len(observed) < 6:
        raise ValueError(f"No stable measurement interval: {path}")
    if any(row.get("windowOccluded", False) for row in observed):
        raise ValueError(f"Occluded benchmark window: {path}")
    if any(b["callbacks"] <= a["callbacks"]
           for a, b in zip(observed, observed[1:])):
        raise ValueError(f"Display-link callback interruption: {path}")

    first, final = observed[0], observed[-1]
    seconds = final["elapsed"] - first["elapsed"]
    keys = (
        "windowRefreshHz", "requestedCallbackHz", "observedCallbackHz",
        "dedicatedRenderThread", "selectionMode", "maximumPendingFrames",
        "latenessRefreshAllowance", "skipHeldDraws",
        "heldRefreshDrawEvery", "redundantDrawsSkipped",
        "sourceToPresentP50Ms", "sourceToPresentP95Ms", "sourceToPresentP99Ms",
        "gapP50Ms", "gapP95Ms", "gapP99Ms",
        "callbackGapP95Ms", "callbackGapP99Ms",
        "readyToSelectP95Ms", "readyToSelectP99Ms",
        "selectToPresentP99Ms", "encodeCostP95Ms",
        "gpuQueueWaitP95Ms", "presentationTargetErrorP99Ms",
        "superseded", "interactiveSuperseded", "overflow",
        "callbackDeadlineMisses", "displayRefreshPresentations",
        "cpuPercentOneCore", "gpuCommandWorkPercent",
        "memoryMiB", "audioDropped", "gpuErrors",
        "interpolationErrors", "thermalState"
    )
    result = {key: final.get(key) for key in keys}
    result["freshFPS"] = round(
        (final["presented"] - first["presented"]) / seconds, 3)
    result["sampleWindowSeconds"] = round(seconds, 3)
    result["medianPlayoutDelayMs"] = round(
        statistics.median(row["playoutDelayMs"] for row in observed), 2)
    return result


data = {
    "provenance": {
        "date": "2026-11-25",
        "host": "M5 MacBook Air",
        "replay": "Independent Big Buck Bunny 1080p60 NV12, real recorded stereo PCM",
        "uniqueSourceFPS": [30, 60],
        "seed": 20261125,
        "measurement": "Capture-source host PTS to Metal drawable presentedTime",
        "opticalInputToPhotonMeasured": False,
        "notes": [
            "Different physical refresh rates cannot be compared as matched pacing tests.",
            "Requested display-link callback rate is not necessarily granted by macOS.",
            "Short-run percentiles are not evidence of sustained 4x throughput."
        ]
    },
    "baseline": {},
    "mainVsDedicated": {},
    "heldRedrawModes": {},
    "latenessSweep": {},
    "refreshMatrix": {},
    "final": {}
}

for spec in ("30-2", "60-1", "30-4"):
    data["baseline"][spec] = summarize(traces / f"{spec}-before.jsonl")

for placement in ("main", "dedicated"):
    path = traces / f"{placement}-30-2-20261125-165.jsonl"
    data["mainVsDedicated"][placement] = summarize(path)

for mode in ("draw", "every2", "every3", "skip"):
    data["heldRedrawModes"][mode] = summarize(
        traces / f"{mode}-20261125.jsonl")

for value in ("1.5", "2.0", "2.5", "3.0"):
    path = support / f"sdk-metrics-pv2-late-{value.replace('.', '_')}-20261125.jsonl"
    data["latenessSweep"][value] = summarize(path)

for name in (
    "pv2-refresh-60-slowest-20261125",
    "pv2-refresh-120-fastest-20261125",
    "pv2-refresh-165-fastest-20261125"
):
    data["refreshMatrix"][name] = summarize(
        support / f"sdk-metrics-{name}.jsonl")

data["final"] = summarize(
    support / "sdk-metrics-pv2-final-cpp-ring-165.jsonl")

# Screen/fullscreen stress intentionally changes display and timing windows.
stress = load(support / "sdk-metrics-pv2-ui-dedicated.jsonl")
phases = defaultdict(list)
for record in stress:
    phases[record.get("uiPhase", "unknown")].append(record)
data["uiStress"] = {
    phase: {
        "samples": len(rows),
        "screenHz": rows[-1]["windowRefreshHz"],
        "freshRollingFPS": round(rows[-1]["rollingFPS"], 2),
        "gpuErrors": rows[-1]["gpuErrors"],
        "interpolationErrors": rows[-1]["interpolationErrors"],
        "audioDropped": rows[-1]["audioDropped"],
        "noDrawable": rows[-1]["noDrawable"]
    }
    for phase, rows in phases.items()
}

destination = root / "Audit/verified-presentation-v2.json"
destination.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n")
print("Exported", destination.relative_to(root), "with",
      len(data["baseline"]), "baseline modes,",
      len(data["heldRedrawModes"]), "held-redraw policies,",
      len(data["refreshMatrix"]), "refresh experiments,",
      len(data["uiStress"]), "UI phases")
