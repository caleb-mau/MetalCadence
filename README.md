# MetalCadence

A native Objective-C Metal presentation scheduler exposed as a Swift Package Manager library for macOS 14+. Designed for externally sourced video, frame interpolation, upscaling, and interactive streaming. The FrameLab demo requires macOS 26+ and supported Apple hardware.

## Architecture

Producer supplies completed textures or another retained payload with host-clock PTS values. The bounded timestamp queue selects a due frame for each CAMetalDisplayLink target. The client encodes the final render pass; MetalCadence commits and presents the drawable supplied by the operating system, without calling nextDrawable. It caps GPU work in flight and discards stale frames rather than allowing unbounded latency.

The package owns presentation only; capture, duplicate detection, interpolation, scaling, and audio are intentionally pluggable. Demo uses Apple's low-latency VideoToolbox interpolation and MetalFX spatial scaling. 30 simulated unique source frames produce up to 60 scheduled output frames. No console or capture device is required to run the demo. USB capture and audio are not implemented yet.

## Build

```sh
swift build
./test.sh
./build-demo.sh
open FrameLabCadence.app
```

For the original 1080p60 reference clip, the demo looks for ~/Library/Application Support/MetalCadence/test.nv12, produced by the original FrameLab benchmark. Without it, the procedural driving scene is available. No video assets are included in this repository.

## API

- MCFrame: frame ID, host-clock PTS, ready timestamp, retained payload.
- MCDisplayScheduler: start/stop on main thread, submit from producer threads, client-defined nonblocking encode callback.
- MCSelectDueFrame: chooses earliest due frame within lateness tolerance, otherwise most recent overdue frame.
- metrics: actual Metal drawable presented callbacks, submitted, skipped, overflow, deadline misses, GPU time, ready-to-present delay, PTS error, p95 presentation gap.

Use strictly increasing IDs and monotonic host-clock PTS. A fixed-refresh display may not evenly divide 60 FPS; 60 or 120 Hz is preferable to 165 Hz. Source clock in the demo uses absolute deadlines. Display rate is selected based on the current window screen. Latency menu adjusts simulated playout offset; does not measure end-to-end HDMI/input latency. GPU utilization is system-wide IOKit telemetry, not per-process. CPU is normalized to one core.

## Status

Experimental, pre-release. API and lifecycle not production hardened. Demo is not a complete gaming or capture client. See ~/Library/Application Support/MetalCadence/metrics.jsonl locally for measurements. The package builds and policy tests run via test.sh. No independent latency or display photodiode measurements yet.

## References

- https://developer.apple.com/documentation/quartzcore/cametaldisplaylink
- https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link
- https://developer.apple.com/documentation/metal/mtldrawable

Implementation is original; Apple documentation informed API use.

## Live capture simulator (experimental)

The default demo uses a separate VirtualCapture process. It decodes an externally rendered 1920x1080 60 fps video and emits a 60 Hz NV12 capture-like stream containing 30 unique source frames per second. Timing jitter and occasional dropped delivery slots are randomized. The client consumes a bounded shared-memory ring, detects repeated images using sampled pixel hashes, and schedules 48 kHz stereo PCM from the replay soundtrack against the same host clock. The optional --3d launch argument instead runs an independent GPU-rendered 3D stress scene on the same computer; this deliberately adds load that a real console would handle itself.

To supply replay footage, put a 1080p60 MP4 at ~/Library/Application Support/MetalCadence/replay.mp4. The current local sample is Big Buck Bunny (Blender Foundation, CC BY 3.0); no footage is included in the repository. Extract the matching soundtrack using `ffmpeg -i replay.mp4 -vn -ac 2 -ar 48000 -c:a pcm_f32le -f f32le replay.f32` in the same directory. Missing PCM produces silence, not a tone. A game capture recorded at 60 Hz with 30 unique frames requires an appropriate replay adapter rather than blindly decimating the input.

Compare is the default visual mode. 2x interpolates 30 -> 60; 4x uses Apple's three quarter-phase outputs for 30 -> 120. Adaptive playout delay accounts for lookahead, transport timing, processing, and safety margin. Output textures are pooled. On empty display refreshes the scheduler retains and redraws the last image; the fresh-frame count excludes these repeats. Audio render callbacks indicate consumption, not measured acoustic/video synchronization. No physical USB bus, HDMI link, USB enumeration, real AVFoundation capture device or actual controller latency has been validated. The simulator is not an installed Core Media I/O extension.

Metrics record fresh presentation counts, P95/P99 gaps, capture packets, duplicate hashes, dropped source slots, ring overruns, texture allocation/reuse, audio rendering callbacks, system-wide GPU utilization, per-process CPU and memory and OS thermal state. Display mode tool changes refresh only when explicitly invoked, for the current login session. 4x is experimental and 2x is the recommended mode.
