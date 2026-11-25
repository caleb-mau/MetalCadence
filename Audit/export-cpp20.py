#!/usr/bin/env python3
"""Export reproducible C++20 video/GPU benchmark summaries from isolated logs.

Run this on a machine that already executed run-cpp20-pools.sh and
run-cpp20-cadence.sh. Raw replay video and huge JSONL logs are not committed.
"""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parent.parent
support = Path.home() / "Library/Application Support/MetalCadence"
out = root / "Audit/verified-cpp20-results.json"


def read(path: Path):
    values = [json.loads(line) for line in path.read_text().splitlines() if line]
    if len(values) < 8:
        raise ValueError(f"Insufficient data: {path}")
    for a, b in zip(values, values[1:]):
        if b["elapsed"] <= a["elapsed"] or b["presented"] < a["presented"]:
            raise ValueError(f"Overlapping or reset sessions: {path}")
    return values


def sample(path: Path):
    rows = read(path)
    observed = [r for r in rows if 5 <= r["elapsed"] <= rows[-1]["elapsed"] - 1]
    if len(observed) < 5 or any(r.get("windowOccluded", True) for r in observed):
        raise ValueError(f"Window occluded or invalid interval: {path}")
    if any(b["callbacks"] <= a["callbacks"] for a, b in zip(observed, observed[1:])):
        raise ValueError(f"Display-link callback stopped: {path}")
    first, last = observed[0], observed[-1]
    seconds = last["elapsed"] - first["elapsed"]
    return {
        "windowHz": last["windowRefreshHz"],
        "seconds": round(seconds, 2),
        "freshFPS": round((last["presented"] - first["presented"]) / seconds, 2),
        "processingP95Ms": round(last["processingP95Ms"], 2),
        "sourceToPresentP99Ms": round(last["sourceToPresentP99Ms"], 2),
        "presentationGapP99Ms": round(last["gapP99Ms"], 2),
        "processMemoryMiB": round(last["memoryMiB"], 1),
        "gpuPoolPeakMiB": round(last.get("textureBudgetPeakMiB", 0), 1),
        "textureAllocations": last["textureAllocations"],
        "textureReuses": last["textureReuses"],
        "gpuCommandWorkPercent": round(last.get("gpuCommandWorkPercent", 0), 1),
        "gpuErrors": last["gpuErrors"],
        "interpolationErrors": last["interpolationErrors"],
        "audioDropped": last["audioDropped"],
    }


data = {
    "hardware": "Apple M5 MacBook Air with external 165Hz and 60Hz displays",
    "source": "Independent timestamped 1920x1080 recorded-video replay, seeded jitter/drop transport",
    "seed": 20261125,
    "latencyDefinition": "Capture PTS to Metal drawable presentation callback (software only)",
    "controllerToPhotonMeasured": False,
    "sourcesReproducible": True,
    "modes": {},
    "poolSizes": {},
    "comparisonAt165Hz": {},
    "heapAllocationProbe": [],
}

for name in ("30-1-2", "30-2-2", "30-4-2", "60-1-2", "60-2-2",
             "30-2-1", "30-2-3"):
    data["modes"][name] = sample(support / f"audit/cpp20-cadence/{name}.jsonl")

for size in (0, 8, 12, 16, 24, 32):
    data["poolSizes"][str(size)] = sample(
        support / f"audit/cpp20-pools/{size}.jsonl"
    )

for name, path in (
    ("before", support / "sdk-metrics-cpp20-before-30-2.jsonl"),
    ("after", support / "sdk-metrics-cpp20-after-165.jsonl"),
):
    rows = read(path)
    observed = [r for r in rows if 7 <= r["elapsed"] <= 24]
    first, last = observed[0], observed[-1]
    assert last["windowRefreshHz"] == 165
    data["comparisonAt165Hz"][name] = {
        "freshFPS": round(
            (last["presented"] - first["presented"]) /
            (last["elapsed"] - first["elapsed"]), 2
        ),
        "processingP95Ms": round(last["processingP95Ms"], 2),
        "sourceToPresentP99Ms": round(last["sourceToPresentP99Ms"], 2),
        "presentationGapP99Ms": round(last["gapP99Ms"], 2),
        "processMemoryMiB": round(last["memoryMiB"], 1),
        "textureAllocations": last["textureAllocations"],
        "textureReuses": last["textureReuses"],
        "audioDropped": last["audioDropped"],
        "gpuErrors": last["gpuErrors"],
        "interpolationErrors": last["interpolationErrors"],
    }

heap_file = Path("/tmp/metalcadence-heap-result.log")
if heap_file.exists():
    for line in heap_file.read_text().splitlines():
        if not line.startswith("HEAP_EXPERIMENT "):
            continue
        pairs = re.findall(r"(\w+)=([^\s]+)", line)
        data["heapAllocationProbe"].append(dict(pairs))

out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
print("Exported", out.relative_to(root), "modes", len(data["modes"]),
      "pools", len(data["poolSizes"]), "heap cases", len(data["heapAllocationProbe"]))
