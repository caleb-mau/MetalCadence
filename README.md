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

## Unified video SDK (macOS 26+)

MetalCadence now ships the higher-level `MCVideoEngine`, independently of FrameLab. The existing scheduler remains available on macOS 14+. The unified engine requires macOS 26+, a compatible Metal device, MetalFX spatial scaling, and VideoToolbox interpolation support for the selected format.

Add this repository as a Swift Package dependency and import `MetalCadence`. For example:

```swift
import MetalCadence
import QuartzCore
import Metal

let config = MCVideoConfiguration()
config.inputWidth = 1920
config.inputHeight = 1080
config.outputWidth = 2560
config.outputHeight = 1440
config.multiplier = 2
config.adaptiveLatency = true
config.audioEnabled = true
config.presentation = .compare

let layer = CAMetalLayer()
layer.device = MTLCreateSystemDefaultDevice()
let engine = try MCVideoEngine(configuration: config, layer: layer)
try engine.start(withRefreshRate: 120)
// Attach layer to your visible view. Submit timestamped NV12 video and PCM,
// or use MCCaptureSource with an authorized AVFoundation capture device.
// engine.metrics() returns a snapshot of the pipeline.
```

The public engine handles input validation, sampled duplicate detection, bounded latest-frame ingestion, VideoToolbox interpolation (1x bypass, 2x, 4x), MetalFX spatial upscaling, output texture pooling, display-linked scheduling, adaptive playout delay, audio scheduling and telemetry. The capture adapter discovers AVFoundation video devices and requests NV12 plus optional float stereo PCM. Physical capture device negotiation is not yet hardware-tested. The simulator is not a physical capture card.

Start, stop and display refresh changes are main-thread operations. Feed immutable IOSurface-backed video-range NV12 buffers and interleaved 48 kHz stereo float PCM. All timestamps must use the host clock (CACurrentMediaTime); the capture adapter converts session timestamps to that clock. The configuration is copied at construction. Change presentation or mute while running; rebuild the engine for resolution or multiplier changes.

Metrics distinguish fresh presentations from held refreshes. Source-to-present percentiles measure the input timestamp to the drawable presentation callback, not controller-to-photon latency. GPU utilization is system-wide and may be unavailable. Audio callbacks are not independent A/V synchronization measurements. The engine drops work when overloaded rather than allowing unlimited latency. Fourfold interpolation is experimental and not guaranteed to sustain 120 fresh FPS.

### Build and run

```sh
swift build
./test-sdk.sh
(cd Examples/SwiftConsumer && swift run Smoke)
./build-sdk-demo.sh
open FrameLabSDK.app
```

FrameLabSDK is a reference client using the public SDK and an independent virtual capture replay process. It logs JSON lines to `~/Library/Application Support/MetalCadence/sdk-metrics-<run-id>.jsonl`. The reference app defaults to auto-selected 2x for a 30 FPS gaming source, compare mode, and audible recorded stereo audio. Automated benchmark runs start muted. The older FrameLab remains available separately. No media is shipped in the repository.

## Workload-aware frame policy

Applications can describe *what they are producing* independently of interpolation settings:

```swift
let profile = MCWorkloadProfile.interactiveGame(withSourceFPS: 30, displayFPS: 120)
profile.kind = .interactiveGame
profile.policy = .minimumBoost
profile.producer = .externalCapture

let settings = MCVideoConfiguration.make(profile: profile)
settings.interpolationBackend = .videoToolbox
// Or .linearBlend, which is faster in some cases but can cause double images.
```

Supported workload categories are interactive game, real-time 3D source, remote desktop, video playback, live production and offline render. Policies are minimum boost (prioritize getting above native FPS), lowest latency, smooth pacing, maximum throughput and power saver. Each profile creates a fixed 1×/2×/4× processing configuration, delay limits and adaptive latency policy. The reference app's **Auto FPS** option uses that planner; explicitly setting 1×/2×/4× overrides only the multiplier. The producer kind describes the upstream data source and does **not** claim the SDK can interpolate on the CPU or render 3D games. The current interpolation backend uses Apple media/Metal hardware. The linear-blend option is mathematically simple and can look ghosted during motion.

The SDK uses a bounded four-unique-frame input queue so a capture burst does not silently overwrite the first frame of a pair. The processing pipeline has two independent MetalFX scratch/scaler slots and a separate GPU completion queue. When overloaded, it discards stale work rather than growing latency without bound. Display timing uses command-buffer-managed drawable presentation. The adaptive controller reserves margin based on the display refresh period and generated-frame spacing. Sampled CPU fingerprints are always verified with a full plane comparison, preventing hash collisions from causing incorrectly discarded frames. ARM64 uses optional NEON SIMD fingerprinting; the GPU hash experiment was slower due to readback synchronization.

### Reproducible audit and validation

```sh
./test-sdk.sh
./Audit/run-quality.sh 240
./Audit/run-hashbench.sh
./build-sdk-demo.sh
./Audit/run-matrix.sh FrameLabSDK.app local 15 20261125
python3 Audit/summarize.py local
```

Replay tests require `replay.mp4` and `replay.f32` in the user's Application Support directory. The report in `Audit/STATUS.md` distinguishes checked items from unverified physical device tests. Tests confirm source-to-present **software** timestamps, not controller-to-photon latency or acoustic synchronization.

### Isolated capture sessions

Every reference application launch generates a unique run ID (or accepts `--run-id=your-test-id`). Video packets travel through `capture-<run-id>.ring` and telemetry is written to `sdk-metrics-<run-id>.jsonl` in Application Support. Benchmark scripts assign an independent namespace to each run, stop and verify old capture processes before launching a new one, and reject mixed-mode time series. This prevents one leftover app from overwriting another capture ring or interleaving performance logs. Older un-namespaced files should not be used for new before/after claims.

### Display-transition and 4× quality diagnostics

```bash
./Audit/run-quality4.sh 120
open -n FrameLabSDK.app --args --2x --benchmark --ui-stress --run-id=display-test
python3 Audit/audio-verify.py --run-id=display-test
```

The display diagnostic automatically enters/exits fullscreen, transfers the window to another detected screen and restores it. It requires an interactive desktop with a second display. These tests observe API presentation callbacks and command status only; they cannot prove zero optical tearing or black flashing. The quality4 probe checks phase 0.5 against a real 60fps reference frame; phases 0.25/0.75 lack 120fps ground truth.

### NV12 ranges and color processing

The engine accepts either video-range 8-bit NV12 (`420v`) or full-range 8-bit NV12 (`420f`). Full-range buffers are normalized using a bounded CoreVideo pixel-buffer pool before Apple's VideoToolbox interpolation, because this macOS VTFrameProcessor configuration rejects native 420f. The source buffer is retained separately for correct duplicate detection, including the exact-verification path. BT.601, BT.709 and BT.2020 YCbCr matrix attachments are preserved and used for the RGB conversion shader; inputs with no metadata default to BT.709. 10-bit P010 sources, HDR10/PQ/HLG transfer conversion, HDMI audio-clock recovery and physical UVC captures remain unimplemented/unverified.

Conversion-only benchmark at 1080p (M5): `./Audit/run-rangebench.sh` P50 0.615 ms, P95 0.640 ms over 150 samples. This is not an end-to-end latency measure.

The repository ships reproducible experiment summaries in `Audit/verified-results.json`; the companion `Audit/export-results.py` builds the file from isolated local JSONL runs. The source replay media is CC BY 3.0 and is not redistributed in this repository. This is an **experimental** SDK, not yet a production gaming client.

### Adaptive latency and developer source formatting

The experimental `MCLatencyController` tracks GPU-ready timing, refresh
intervals, output queue pressure and stereo PCM scheduling age. Its goal is to
preserve fresh frames while reducing unnecessary playout buffering, not to
guarantee 60 or 120 FPS. See
[`Audit/latency-controller.md`](Audit/latency-controller.md) for before/after
measurements, native-audio tradeoffs, unresolved hardware validation and
reproduction caveats.

Objective-C/C source is formatted consistently with the repository-wide
`.clang-format`. Run `./scripts/format.sh` after edits and
`./scripts/format.sh --check` before committing. SDK and demo builds run the
check automatically; pull requests have an independent formatting job. Removing
whitespace does not improve runtime performance.

## Objective-C++20 internals and GPU resource tuning

MetalCadence's implementation uses **Objective-C++20** (`.mm`) to combine
Foundation, CoreVideo, VideoToolbox, Metal and MetalFX with C++20 resource
management. The public headers remain regular Objective-C, so existing Swift
and Objective-C consumers retain the same API. `Package.swift` declares
`cxxLanguageStandard: .cxx20`; source and test builds use `clang++ -std=c++20`.
This is an architectural change, not a claim that C++ automatically generates
frames more quickly.

The output/native texture caches share one accounted GPU memory budget and
track active versus cached resources. For a consumer that needs custom limits:

```objc
MCVideoConfiguration *configuration = [MCVideoConfiguration new];
configuration.gpuTextureBudgetMiB = 512;
configuration.maxCachedTexturesPerPool = 12;
configuration.preallocatedTexturesPerPool = 0; // Lazy is the measured default.
configuration.maxConcurrentGPUBatches = 2;   // Separate scaler and scratch per slot.
```

`gpuTextureBudgetMiB` only covers the SDK's two pooled private texture
classes, not all memory held by MetalFX, VideoToolbox, system drawables or the
GPU driver. More preallocated textures or in-flight batches are not
automatically faster, and both consume unified memory.

The production rendering and NV12 conversion shaders live in
`Shaders/Production.metal`; independent diagnostic shaders live in
`Diagnostic.metal` and `LegacyDemo.metal`. Normal app builds compile
`.metallib` files ahead of time. The Swift Package retains deterministic
generated source fallbacks for applications that do not bundle a library.
After editing any `.metal` file, run `./scripts/format.sh` to format source
and regenerate matching fallback headers.

```bash
./scripts/format.sh --check
./test-sdk.sh
(cd Examples/SwiftConsumer && swift run Smoke)
./build-sdk-demo.sh
./Audit/run-shader-color.sh
./Audit/run-metal-heaps.sh
./Audit/run-cpp20-pools.sh 16 20261125
./Audit/run-cpp20-cadence.sh 15 20261125
python3 Audit/export-cpp20.py
```

**Evidence and limitations:** [Objective-C++20 engineering audit](Audit/cpp20-engineering-report.md)
and [machine-readable benchmarks](Audit/verified-cpp20-results.json).
The same-refresh baseline shows similar fresh FPS and processing latency,
a lower observed process footprint and fewer output allocations, but worse
presentation-gap P99. Software presentation timestamps are not
controller-to-photon latency. The SDK remains experimental.

### Presentation Pipeline V2 (experimental)

The C++20 presentation engine adds fixed-capacity, allocation-free timing
histograms for GPU-ready-to-display selection, CPU encode, GPU queue wait,
callback timing and presentation target errors. It also exposes optional
interactive newest-due selection, a dedicated high-priority display run loop,
partial held-frame redraw and refresh-dependent lateness controls.

By default the SDK preserves the previously validated smooth frame selection,
main-thread display link, held-frame redraw and 1.5-refresh lateness window.
Additional public `MCVideoConfiguration` properties are:

```objc
config.preferFreshestFrame = NO;
config.dedicatedPresentationThread = NO;
config.skipRedundantPresentations = NO;
config.heldRefreshDrawEvery = 1;
config.presentationLatenessRefreshes = 1.5;
```

The reference app accepts opt-in test flags `--freshest`,
`--dedicated-display`, `--skip-held`, `--held-redraw-every=2`,
`--late-refreshes=2.0`, `--refresh-hz=120` and
`--benchmark-screen=slowest` (for a physical low-refresh connected screen).
`--refresh-hz` requests a callback frequency but does not change the
monitor's physical refresh mode.

The [Presentation V2 audit](Audit/presentation-v2-report.md) records
before/after results, failed configurations, remaining hardware limitations
and reproducible commands. The [verified results](Audit/verified-presentation-v2.json)
are generated from isolated local sessions. The default P99 latency target
has **not** been met. Do not assume a requested 120 Hz rate was physically
delivered without checking the observed callback and monitor refresh metrics.


## Interactive latency lab (macOS 26+)

Run \`./build-latency-lab.sh && open MetalCadenceLatencyLab.app\`.
This is a controllable *synthetic* 30 FPS source. The left side is a separate
native 1×/30 FPS path with no configured playout buffer. The right side uses
actual VideoToolbox interpolation at 2×/60 FPS or 4×/120 FPS, with independently
selectable adaptive or fixed playout budgets. Both engines receive the same
timestamps and CVPixelBuffers. Press **Space**, an arrow key, or **Swap Target**
to create an abrupt scene change and observe the difference.

The numeric input-to-presentation response is measured from the Mac input
handler to the first fresh drawable presenting the source frame containing
that input. This is a **software** measurement, not controller-to-photon,
HDMI capture latency or LCD scanout. The 4× mode can only be observed at
120 unique presentations on a 120 Hz or faster active display. Scene-cut
artifacts and timing differences are intentionally visible.

Run \`open MetalCadenceLatencyLab.app --args --self-test\` for six automatically
triggered actions. JSON event pairs are written to
\`~/Library/Application Support/MetalCadence/latency-lab-*.jsonl\`.
