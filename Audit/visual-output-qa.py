#!/usr/bin/env python3
"""Screenshot-based black/overlapped preview regression for the native GTA lab.

Checks actual Mac window pixels; GPU counters and successful Metal commands
alone do NOT establish that the end user sees the image. Requires screen
recording permission and locally installed ffmpeg. Captures are temporary,
not uploaded or checked in. This cannot certify 60fps interpolation quality.
"""
import argparse
from pathlib import Path
import json
import statistics
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent

def run(*cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.PIPE).strip()

def sample_region(frame: Path, x0: float):
    info = json.loads(run("ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=width,height", "-of", "json", str(frame)))
    width = info["streams"][0]["width"]
    height = info["streams"][0]["height"]
    # Pick the center of the source/enhanced video view, avoiding headings
    # and HUD/controls. Works at typical and maximized window sizes.
    x = int(width * x0)
    y = int(height * .285)
    cw = int(width * .435)
    ch = int(height * .36)
    expression = f"crop={cw}:{ch}:{x}:{y},scale=240:140,format=gray"
    raw = subprocess.check_output(
        ["ffmpeg", "-v", "error", "-i", str(frame), "-vf", expression,
         "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-"])
    if len(raw) != 240 * 140:
        raise RuntimeError("Unexpected screenshot region size")
    return (statistics.pstdev(raw), statistics.mean(raw), raw)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="com.caleb.metalcadence.latencylab")
    parser.add_argument("--samples", type=int, default=4)
    parser.add_argument("--interval", type=float, default=1.7)
    parser.add_argument("--minimum-contrast", type=float, default=14.0)
    args = parser.parse_args()
    if not 1 <= args.samples <= 12 or not 0 <= args.interval <= 10:
        parser.error("Invalid sample count or interval")
    window_id = run("xcrun", "swift", str(HERE / "metal-window-id.swift"),
                    args.bundle_id).splitlines()[-1]
    found = False
    with tempfile.TemporaryDirectory(prefix="metal-visual-qa-") as tmp:
        for index in range(args.samples):
            if index:
                time.sleep(args.interval)
            path = Path(tmp) / f"frame-{index}.png"
            subprocess.run(["screencapture", "-x", "-l", window_id, str(path)],
                           check=True, capture_output=True)
            left = sample_region(path, .03)
            right = sample_region(path, .53)
            delta = statistics.mean(abs(a - b) for a, b in zip(left[2], right[2]))
            print(f"frame {index}: original contrast={left[0]:.1f}, "
                  f"enhanced contrast={right[0]:.1f}; "
                  f"left/right mean absolute pixel difference={delta:.1f}", flush=True)
            if left[0] >= args.minimum_contrast and right[0] >= args.minimum_contrast:
                found = True
    if not found:
        raise SystemExit("FAIL: original or enhanced preview black/overlapped "
                         "in every captured window sample")
    print("PASS: actual original and enhanced CAMetalLayer preview pixels visible")
    print("LIMIT: this test does not prove temporal smoothness, ghosting-free "
          "motion or full 60 Hz capture.")

if __name__ == "__main__":
    main()
