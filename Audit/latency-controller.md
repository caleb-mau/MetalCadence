# Adaptive Latency Controller: 2026-11-25 Experimental Audit

This document records implementation changes and measurements on the M5 Mac
under the independent NV12 virtual capture replay, not physical HDMI or
controller-to-photon testing.

## Implementation

- Added the reusable `MCLatencyController` Objective-C class to the public
  Swift Package.
- A bounded 96-sample window estimates source-to-GPU-ready P50/P90/P95 and
  selects a policy-dependent readiness percentile.
- Presentation margin follows observed refresh interval, generated-frame
  phase spacing, superseded frames, overflow and queue pressure.
- Buffer increases are capped and relatively fast. Decreases are gradual.
- Workload policies distinguish minimum boost, lowest latency, smooth pacing,
  maximum throughput and energy saver.
- Audio feedback now measures PCM scheduling age and reports P95/P99, late
  deadlines, backpressure and invalid future timestamps independently.
- Smooth playback may allocate extra playout to audio continuity. Interactive
  minimum-boost and lowest-latency profiles bound the *additional* latency
  imposed by audio recovery to 12 ms and 6 ms above the video goal,
  respectively. This is not a guarantee of zero audio underruns.
- The SDK telemetry reports attempted output frames, scheduler rejections,
  native-only batches, incomplete interpolated batches, pixel-buffer-pool
  allocation failures and scaling failures.
- The virtual capture benchmark uses isolated run IDs, reports window occlusion
  and display-link callback age, and rejects stalled display callback series.
  A present/visible macOS window is essential to valid display-linked FPS tests.

## Valid same-seed short comparison

Source: recorded 1080p NV12 and stereo 48 kHz PCM, 20261125 random seed.

| Metric | Previous scheduler | Predictive scheduler |
| --- | ---: | ---: |
| 30 -> 60 fresh FPS | 59.25 | 59.31 |
| 30 -> 60 median playout | 74.33 ms | 70.60 ms |
| 30 -> 60 source-to-present P99 | 95.17 ms | 91.57 ms |
| 30 -> 60 presentation gap P99 | 36.37 ms | 30.31 ms |
| 30 -> 60 audio drops | 0 | 0 |
| Native 60 FPS | 59.47 | 59.47 |
| Native 60 audio drops | 1 | 7 |

The video-only 30 -> 60 improvement was modest, approximately 3.6 ms P99.
Native 60 audio exposed an unacceptably small audio scheduling margin.

## Audio feedback experiments

The first audio-aware p95 floor still dropped nine PCM packets in 30 seconds.
A p99-based floor and recovery feedback reduced this to three drops in a
28-second native-60 run, but a longer 43-second replay still dropped four
packets. These late PCM events were associated with brief timestamp-age bursts:
one run observed a P99 scheduling-age spike of about 46 ms and adaptive video
buffering near 76 ms. Simply increasing the buffer can sacrifice game input
responsiveness without guaranteeing perfect audio.

The policy-specific cap was added to constrain those spikes. In the latest
isolated 31-second runs:

| Source and target | Fresh FPS | Audio drops | Median playout | Source-to-present P99 |
| --- | ---: | ---: | ---: | ---: |
| 60 -> 60 native | 58.41 | 0 | 31.82 ms | 79.18 ms |
| 30 -> 60 generated | 58.31 | 0 | 93.20 ms | 97.95 ms |

These results are a **tradeoff**, not a universal improvement. In particular,
native 60 presentation-gap P99 increased to 48.50 ms in that run. macOS
scheduling and capture jitter remain non-deterministic even with a fixed
transport seed. The experimental controller should not become the default for
all gaming applications without repeatable, better results.

## Frame-output integrity and format support

- The real 1280x720 input regression passed exactly 14/14 original output
  frames in native mode and 26 output frames from 13 interpolated pairs in
  2x mode. No incomplete batches, scale failures, VideoToolbox failures or
  scheduler frame submission rejections occurred in the verified test.
- A synthetic 640x360 NV12 input passed native mode but VideoToolbox rejected
  2x interpolation with `VTFrameProcessorErrorDomain -19740` and underlying
  `-50` on this M5. It was not evidence of a general missing-output defect.
  The public error telemetry distinguishes this from GPU or scheduling issues.
- The SDK should grow explicit per-resolution capability validation or a
  caller-selected fallback backend. Silently changing image quality is not a
  validated solution.

## Formatting and enforcement

A repository-wide `.clang-format` uses readable Objective-C blocks, explicit
braces and a 100-column preferred line width. Run:

```bash
./scripts/format.sh
./scripts/format.sh --check
./test-sdk.sh
```

Formatting is checked before the SDK/demo builds and test scripts run, and by
`.github/workflows/objc-format.yml` on pull requests. This is purely a
source-maintainability measure with no claimed runtime performance gain.

## Still open

- Hardware capture-device input timestamps and physical audio-clock recovery
- Actual controller-to-photon latency, black flashes or tearing measurement
- More representative game footage, HUD and camera-motion perceptual scoring
- A/V continuity recovery that conceals rare late PCM bursts without a large
  game-rendering buffer penalty
- Repeated benchmark runs at actual 60/120/165 Hz display modes and sustained
  thermal testing
- Capability negotiation, HDR/P010 and multi-platform CPU/GPU processing
