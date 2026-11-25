# Live video MetalFX upscaling and frame generation

The main live engine already supports 720p input to 1080p/1440p MetalFX
spatial scaling while generating intermediate frames at 2x or 4x.
The local clip adapter provides an actual decoded 720p30 MP4 input so
this combination can be viewed and benchmarked in real time.

## Setup

Build the native UI:

    ./build-latency-lab.sh

Open the app and press "Play 720p video". The source defaults to
~/Movies/MetalCadence GTA Tests/GTA-V-720p30.mp4 (if present), otherwise
~/Movies/MetalCadence Upscale Tests/source-720p.mp4 and, when missing,
a local file chooser will accept a 720p30 MP4.

Left: original 1280x720, 1x frames.
Right: 2560x1440 (MetalFX spatial), VideoToolbox 2x or 4x frames.

For repeatable testing of a local 720p30 clip:

    open -n MetalCadenceLatencyLab.app --args --source=clip         --output=1440 --clip-test         --clip-path="/absolute/path/source-720p.mp4"         --run-id=realvideo-test

The app closes after 14 seconds and writes a JSONL to
~/Library/Application Support/MetalCadence/latency-lab-realvideo-test.jsonl

Evaluate:

    python3 Audit/realtime-clip-evaluate.py         ~/Library/Application\ Support/MetalCadence/latency-lab-realvideo-test.jsonl

This tests actual VideoToolbox-decoded 720p motion and real GPU spatial
upscaling in the MetalCadence renderer, unlike the offline exporter.
The live comparison window scales both presentations down to the panel
bounds; the enhanced engine still renders a 2560x1440 texture.

## Limits

- Test video is video-only, with no audio loopback.
- Source timestamps are the local decoder-to-engine submission times,
  not original camera exposure or Xbox game frame times.
- 120 FPS mode needs a 120 Hz or faster active monitor for 120 distinct
  on-screen frames.
- CPU decode time, GPU time, source-to-present latency, frame pacing,
  and post-processing memory should be evaluated separately.
- The adapter has now completed the first full M5 gameplay-video runtime test.
  Source->presentation includes intentional interpolation lookahead and
  macOS scheduling, not Xbox controller-to-photon latency.
