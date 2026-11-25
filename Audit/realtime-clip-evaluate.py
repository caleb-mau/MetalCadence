#!/usr/bin/env python3
"""Validate a live 720p30 -> MetalFX 1440p + framegen lab session."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("jsonl", type=Path)
parser.add_argument("--minimum-output-fps", type=float, default=55)
args = parser.parse_args()
records = [json.loads(line) for line in args.jsonl.read_text().splitlines() if line.strip()]
summary = next((row for row in reversed(records) if row.get("kind") == "summary"), None)
if not summary:
    raise SystemExit("No final summary. Exit the lab normally to record results.")
duration = max(float(summary.get("runtimeSeconds", 0)), 0.001)
decoded = int(summary.get("clipFramesDecoded", 0))
presented = int(summary.get("rightPresented", 0))
values = {
    "mode": summary.get("sourceMode"),
    "multiplier": summary.get("rightMultiplier"),
    "gameplay_immediate": summary.get("rightGameplayImmediate"),
    "window_occluded": summary.get("windowOccluded"),
    "output": [summary.get("rightOutputWidth"), summary.get("rightOutputHeight")],
    "duration_seconds": round(duration, 2),
    "source_decoded_fps": round(decoded / duration, 2),
    "generated_presented_fps": round(presented / duration, 2),
    "source_loops": summary.get("clipLoops"),
    "source_rejected_frames": summary.get("clipRejectedFrames"),
    "gpu_command_p50_ms": summary.get("rightGPUMedianMs"),
    "processing_p95_ms": summary.get("rightProcessingP95Ms"),
    "source_to_presentation_p50_ms": summary.get("rightSourceToPresentP50Ms"),
    "presentation_gap_p99_ms": summary.get("rightGapP99Ms"),
    "gpu_errors": summary.get("rightGPUErrorCount"),
    "interpolation_errors": summary.get("rightInterpolationErrors"),
}
print(json.dumps(values, indent=2))
assert values["mode"] == "clip", "Expected real video clip input"
assert values["output"] == [2560, 1440], "Expected MetalFX 1440p output"
assert values["multiplier"] == 2, "Expected VideoToolbox 2x generation"
assert not values["gameplay_immediate"], "Gameplay mode deliberately disables framegen"
assert not values["window_occluded"], "Video window was not visible"
assert duration >= 10, "Not enough playback for a stable demo"
assert 27 < decoded / duration < 33, "Not a stable 30 FPS decoded input"
assert presented / duration >= args.minimum_output_fps, "Generated output misses target"
assert presented >= decoded * 1.75, "Not enough generated frames relative to decoded source"
assert values["gpu_errors"] == 0 and values["interpolation_errors"] == 0
print("PASS: live 720p MP4 -> MetalFX 1440p + frame generation session")
