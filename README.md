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
