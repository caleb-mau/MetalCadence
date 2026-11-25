#!/usr/bin/env python3
"""Rank scheduler execution separately from deliberate frame waiting."""
import argparse
import json
from pathlib import Path

CPU = [
    ("whole drawn callback", "schedulerCallbackTotalP95Ms"),
    ("drawable acquisition under lock", "schedulerDrawableLookupP95Ms"),
    ("frame selection algorithm", "schedulerSelectionP95Ms"),
    ("callback lock held", "schedulerCallbackLockHeldP95Ms"),
    ("callback lock wait", "schedulerCallbackLockWaitP95Ms"),
    ("producer lock wait", "schedulerSubmitLockWaitP95Ms"),
    ("producer queue mutation", "schedulerSubmitMutationP95Ms"),
    ("Metal command buffer creation", "schedulerCommandBufferP95Ms"),
    ("CPU Metal encoding", "encodeCostP95Ms"),
    ("completion/presentation handler setup", "schedulerHandlerSetupP95Ms"),
    ("drawable present + command commit", "schedulerPresentCommitP95Ms"),
]
WAIT = [
    ("source timestamp -> ready", "sourceToReadyP95Ms"),
    ("planned ready -> PTS (NOT elapsed wait)", "scheduledWaitP95Ms"),
    ("ready -> callback selection", "readyToSelectP95Ms"),
    ("selected -> drawable presented", "selectToPresentP95Ms"),
    ("GPU command queue wait", "gpuQueueWaitP95Ms"),
]
OTHER = ["sourceToPresentP50Ms", "sourceToPresentP99Ms", "gapP99Ms",
         "processingP95Ms", "schedulerCallbackTotalP99Ms",
         "schedulerDrawableLookupP99Ms", "schedulerCallbackLockWaitP99Ms"]
COUNTERS = ["callbacks", "presented", "busyRefreshes", "noDrawable", "superseded",
            "callbackDeadlineMisses", "schedulerDrawnSamples",
            "schedulerCallbackSamples", "schedulerSubmitSamples", "gpuErrors",
            "interpolationErrors", "windowRefreshHz", "requestedCallbackHz",
            "observedCallbackHz", "activeMultiplier"]

def analyze(path, warmup):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    samples = [x for x in rows if isinstance(x, dict) and x.get("elapsed", 0) >= warmup]
    if not samples:
        raise ValueError(f"No warmed-up telemetry rows in {path}")
    last, first = samples[-1], samples[0]
    elapsed = max(.001, float(last["elapsed"]) - float(first["elapsed"]))
    fresh = (float(last.get("presented", 0)) - float(first.get("presented", 0))) / elapsed
    callbacks = (float(last.get("callbacks", 0)) - float(first.get("callbacks", 0))) / elapsed
    print(f"\n{path.name} | {elapsed:.1f}s after warmup | fresh {fresh:.2f} fps | callbacks {callbacks:.2f} Hz")
    print("Scheduler CPU stages ranked by independent P95 (ms):")
    for label, key in sorted(CPU, key=lambda x: float(last.get(x[1], -1)), reverse=True):
        if key in last:
            print(f"  {float(last[key]):8.4f}  {label}")
    print("Scheduling/GPU waits (ms), NOT additive:")
    for label, key in sorted(WAIT, key=lambda x: float(last.get(x[1], -1)), reverse=True):
        if key in last:
            print(f"  {float(last[key]):8.3f}  {label}")
    print("Other percentiles:")
    for key in OTHER:
        if key in last:
            print(f"  {key}: {float(last[key]):.3f}")
    print("Counters:")
    for key in COUNTERS:
        if key in last:
            print(f"  {key}: {last[key]}")
    if last.get("windowOccluded"):
        print("WARNING: occluded window")
    if last.get("requestedCallbackHz") and last.get("windowRefreshHz"):
        if abs(float(last["requestedCallbackHz"]) - float(last["windowRefreshHz"])) > 2:
            print("WARNING: requested callback/display refresh mismatch")
    if float(last.get("schedulerDrawnSamples", 0)) < 30:
        print("WARNING: too few drawn scheduler callbacks for stable P95")
    print("Per-stage P95 values are independent histograms, NOT a single frame trace.")
    print("Software drawable presentation is NOT controller-to-photon latency.")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--warmup", type=float, default=5.0)
    args = parser.parse_args()
    for path in args.files:
        analyze(path, args.warmup)

if __name__ == "__main__":
    main()
