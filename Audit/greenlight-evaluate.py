#!/usr/bin/env python3
"""Check ScreenCaptureKit remote-play capture session health, not controller-to-photon."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("jsonl", type=Path)
parser.add_argument("--min-runtime", type=float, default=10.0)
args = parser.parse_args()
rows = [json.loads(line) for line in args.jsonl.read_text().splitlines() if line.strip()]
summary = next((r for r in reversed(rows) if r.get("kind") == "summary"), None)
if summary is None:
    raise SystemExit("No session summary. Close the lab normally first.")
runtime = float(summary.get("runtimeSeconds", 0))
count = int(summary.get("windowCaptureSamples", 0))
out = {
    "source": summary.get("sourceMode"),
    "runtime_seconds": round(runtime, 2),
    "sck_captured_frames": count,
    "capture_callback_fps": round(count / runtime, 2) if runtime else 0,
    "native_presented_fps": round(int(summary.get("leftPresented", 0)) / runtime, 2) if runtime else 0,
    "generated_presented_fps": round(int(summary.get("rightPresented", 0)) / runtime, 2) if runtime else 0,
    "generated_p99_gap_ms": summary.get("rightGapP99Ms"),
    "generated_p50_capture_to_present_ms": summary.get("rightSourceToPresentP50Ms"),
    "gpu_errors": summary.get("rightGPUErrorCount"),
    "interpolation_errors": summary.get("rightInterpolationErrors"),
    "nv12_format_mismatches": summary.get("windowCaptureFormatMismatches"),
    "sck_idle_frames": summary.get("windowCaptureIdle"),
}
print(json.dumps(out, indent=2))
if (summary.get("sourceMode") != "greenlight" or runtime < args.min_runtime
        or count < 30 or out["gpu_errors"] or out["interpolation_errors"]):
    raise SystemExit("Capture integrity check failed. Inspect above metrics.")
