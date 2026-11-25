# MetalCadence engineering audit | 2026-11-25

**Scope:** macOS Apple Silicon Objective-C SDK, Swift Package consumption, display-link scheduling, VideoToolbox/MetalFX processing, stereo audio and independent virtual capture replay. Audit branch: `audit/pacing-pipeline`.

## What has been reproduced and fixed

**P0 presentation timing:** Changed from standalone `[cb commit]; [drawable present];` to `[cb presentDrawable:drawable]; [cb commit];` using drawables supplied by `CAMetalDisplayLink`. Refresh-dependent late-frame selection replaces a fixed 25 ms window. Presentation and GPU error telemetry is collected. Window movement/fullscreen transitions and screen tear-free optical confirmation remain unverified.

**P1 processing:** Removed `[cb waitUntilCompleted]` from the media producer, replacing it with at most two GPU processing batches in flight, two independent MetalFX scratch/scaler objects, retained CVPixelBuffer and CVMetalTexture references until GPU completion, and a separate completion queue. An early implementation had a single-slot latest-frame mailbox that could overwrite the first source frame before interpolation. A four-frame bounded ingress queue fixes the bug, including a regression that submits two unique frames without yielding between calls.

**P1 duplicate detection:** Matching sampled fingerprints always trigger exact NV12 plane verification before dropping a frame. ARM NEON SIMD hash and FNV are selectable; GPU hashing was evaluated but not integrated because readback synchronization was slower. An unsampled single-pixel mutation is explicitly tested.

**P1 adaptive timing:** Replaced the inadequate 0.75-refresh safety margin with a workload-aware deadline margin based on display refresh and generated output phase spacing. Latency may increase slightly to avoid dropping finished frames. The engine exposes profile-specific latency, pacing and output rate policies.

**P1 visual comparison:** Modes are genuine original native-size texture, MetalFX upscale-only, native-sized generated frames, and combined upscale+generation. Original and upscale-only modes skip VideoToolbox frame generation. Fresh-output counters exclude held presentation refreshes, and the raw-source mode regression asserts one new output per source.

**P2 4x:** Maintains the validated Apple VT 4x setup (two destination interpolated frames, phases 0.25/0.50/0.75). Optional runtime fallback creates an independent 2x VT session and destination pool, uses measured batch budget and a cooldown/re-probe policy. Profile/controller logic has deterministic unit tests. Real-world fallback effectiveness has not been established by the short screening results alone.

**P2 audio:** Removed synthetic sine-tone playback; test audio is decoded stereo 48 kHz floating PCM from the original replay movie. An independent packet verifier confirmed byte-for-byte equality across 20 virtual-capture packets. Audio scheduling drift, discontinuities, dropped buffers and queued audio lead are instrumented. This does NOT establish speaker-to-screen synchronization or capture-card feedback behavior.

## Before/after seeded 1080p replay

Identical random seed (20261125), same display setting and target, with source frame rate preserved. These are short screening runs; source frame jitter and OS resource load still vary across launches.

| Input → expected target | Before deadline safety | After safety update | Overdue superseded before → after |
|---|---:|---:|---:|
| 30 → 30 | 30.0 FPS | 30.0 FPS | 0 → 0 |
| 30 → 60 | 53.7 | 59.9 | 64 → 2 |
| 30 → 120 | 87.4 | 114.1 | 322 → 63 |
| 60 → 60 | 59.1 | 59.1 | 1 → 2 |
| 60 → 120 | 65.9 | 103.4 | 636 → 165 |

Later bounded-mailbox/NEON run: 29.99, 59.79, 110.80, 59.00 and 106.10 FPS in corresponding modes, all with zero reported GPU/VT processing errors. The first purported linear-blend matrix (59.98, 111.66 and 104.53 FPS) is **INVALID** as a comparison of algorithms. A defect in MCVideoConfiguration.copyWithZone silently reset the requested interpolation backend to VideoToolbox. The configuration copier was fixed and explicit copy regression tests were added. Blend is opt-in because motion ghosting can be substantial; correct backend-specific benchmark results must be collected again.

## Quality and duplicate classifier

Recorded 60 fps reference: Big Buck Bunny, 1920×1080, 240 consecutive midpoint pairs (separate source even frames and held-out true odd frames). Median luma PSNR: VT generated 42.67 dB, original held 44.39 dB, mathematical blend 50.86 dB. VT exceeded held on 128/240 midpoint frames and exceeded blend on 83/240. PSNR is sensitive to blur and must NOT be treated as perceptual gaming quality or a GTA VI quality guarantee. No pairs exceeded the test's coarse >10% large-error-pixel threshold.

Duplicate detection benchmark on same M5, 120 input comparisons:

| Classifier | CPU-side P50 | CPU-side P95 |
|---|---:|---:|
| CPU FNV sampled + verify | 0.025 ms | 0.084 ms |
| ARM NEON sampled + verify | 0.004 ms | 0.065 ms |
| Exact CPU compare | 0.001 ms | 0.061 ms |
| Metal GPU reduction + readback + verify | 0.517 ms | 0.929 ms |

The GPU kernel itself was 0.027 ms median; waiting for the result dominated. These are synthetic NV12 samples with a deliberately modified unsampled pixel, not exhaustive hardware/device cases. Zero final duplicate decision errors in this sample, with full verification defeating hash collisions.

## Sustained performance and outstanding defects

Fixed 4x at 30 fps source, 201 seconds: mean 94.28 fresh FPS after 20 s; lowest 5% one-second FPS samples <=26.97; slowest one-second sample ~20 FPS; processing P95 50.65 ms, source-to-presentation P99 228.49 ms, presentation-gap P99 60.62 ms, memory 607.6→616.6 MiB, no GPU or interpolation errors. macOS thermal states included nominal (0) and fair (1), not serious/critical, so attributing slowdown solely to thermal throttling would be unfounded. Short-lived near-120 FPS performance is NOT sustained gaming performance.

Adaptive 4x→2x fallback is opt-in and has deterministic overload/cooldown tests. The first 335-second purported adaptive run was **INVALID** as an adaptive test: configuration copying discarded adaptiveMultiplier, so it stayed in fixed 4x. A second attempt's metrics were corrupted by interleaved JSON from two surviving app instances. Both defects were confirmed and fixed: the SDK preserves the property, per-run metrics and capture rings now have unique IDs, and test launch verifies adaptiveMultiplierEnabled = true. The controller now uses the nominal configured source cadence, rather than erroneously using skipped-frame PTS gaps as a forgiving benchmark threshold. The fallback policy is gated to persistent over-budget batches, with cooldown to avoid rapid 2x/4x oscillations. Compare genuinely isolated sustained runs before concluding it improves worst-case FPS. Game-oriented profiles default to a 2x target rather than 4x.

System-wide `IOAccelerator` GPU utilization sometimes reports zero even when Metal command buffers report nonzero execution time. This counter cannot be used alone to judge GPU use. The SDK separately records actual Metal command execution and GPU queue gaps as a workload proxy; neither equals whole-GPU hardware utilization.

## Work still open

- Real HDMI/USB UVC capture with negotiated NV12 and PCM, including capture jitter and hardware timestamp conversion
- Optical tearing, black-frame and fullscreen/external-monitor testing with independent display measurement
- High-motion game footage with HUD/text/reflections and user-perceived artifacts
- Hardware audio output versus visible frame timing and AVAudioEngine device/clock drift
- Repeated random seeds, long 2x gameplay-oriented endurance, serious thermal conditions
- GPU reduction without synchronous readback, if a nonblocking design can beat CPU SIMD
- Graceful dynamic resolution/quality scaling beyond current 4x→2x fallback

## Reproduce

```bash
swift build
./test-sdk.sh
(cd Examples/SwiftConsumer && swift run Smoke)
./Audit/run-quality.sh 240
./Audit/run-hashbench.sh
./build-sdk-demo.sh
./Audit/run-matrix.sh FrameLabSDK.app audit 15 20261125
python3 Audit/summarize.py audit
./Audit/run-stress.sh FrameLabSDK.app 10
```

The replay source is **not** bundled in GitHub. Supply `~/Library/Application Support/MetalCadence/replay.mp4` (1080p60), and its stereo 48 kHz `replay.f32`. The independently launched replay simulator adds delivery jitter and occasional drops; `--seed=0` selects randomized timing while nonzero seeds reproduce the pseudo-random drop/jitter sequence. End-to-end GPU/input processing latency and drawable presentation are SOFTWARE timestamps, never controller-to-photon measurements.

## Audit continuation and benchmark provenance

Found actual first-pair loss from the original one-slot intake mailbox, and fixed it with a bounded four-unique-frame queue. Confirmed regression with immediate successive source submissions. Added public workload profiles (interactive game, real-time 3D source, desktop streaming, video playback, live production, offline render), upstream CPU/GPU/HDMI metadata, and policy targets (above native, low latency, smooth, throughput, power saver). The plan chooses fixed 1/2/4x and buffers; dynamic fallback has its own tested budget-controller class.

The SDK engine copies all configuration fields including interpolationBackend, duplicateFingerprintMethod and adaptiveMultiplier. Test that properties survive both the config factory and engine initialization before trusting any backend-specific benchmark. Session-level results are stored in sdk-metrics-<run-id>.jsonl and each virtual device stream uses capture-<run-id>.ring; overlapping processes cannot cross-contaminate metrics. The benchmarking scripts terminate all old test apps and use unique IDs. Legacy sdk-metrics.jsonl is not safe to compare against isolated results.

A later isolated 30→60 run using the corrected configuration copier and SIMD hashing measured 59 FPS in its latest one-second interval after 14s (0 GPU/VT processing errors). This is a screening result, not a long gaming stress result.

## Long-duration fallback validation, corrected configuration

An isolated 200-second 30 FPS replay run with `--adaptive4` and seed 90210 verified `adaptiveMultiplierEnabled=true`, `activeMultiplier` changed from 4 to 2 at approximately t=110 s, and `fallbackTransitions=1`. The system thermal state remained fair (1), so the controller did not attempt recovery, avoiding oscillation.

Comparison over the **last 20 seconds (180–200 s)** against a 201-second fixed-4x recording with the same nominal seed and replay source:

| Measure | Fixed 4x | Adaptive 4x→2x |
|---|---:|---:|
| Mean actual fresh FPS | 27.0 | 59.5 |
| Minimum per-second fresh FPS | 20.0 | 55.9 |
| Source to drawable P99, ms | 228.5 | 94.7 |
| GPU/VT errors | 0/0 | 0/0 |

The adaptive policy sacrifices 4x peak throughput after sustained overload in exchange for consistent frame cadence and lower latency. This is not optical controller-to-photon measurement. The originally reported purported adaptive results that never left 4x were invalidated by the missing `copyWithZone` property and shared log contamination. The new sessions use independent capture rings and metrics log files.

## Corrected backend-specific verification

A later five-mode benchmark was rerun using the corrected configuration copier and uniquely named capture rings, so `MCVideoConfiguration.interpolationBackend` actually selects the intended algorithm.

| Input → output goal | VideoToolbox fresh FPS | Metal blend fresh FPS | VT processing P95 | Blend processing P95 |
| --- | ---: | ---: | ---: | ---: |
| 30 → 30 | 29.99 | 29.88 | 4.54 ms | 4.77 ms |
| 30 → 60 | 59.76 | 59.66 | 22.06 ms | 7.71 ms |
| 30 → 120 | 110.42 | 112.87 | 37.27 ms | 8.16 ms |
| 60 → 60 | 58.88 | 58.32 | 4.61 ms | 5.27 ms |
| 60 → 120 | 104.55 | 100.51 | 14.53 ms | 6.57 ms |

Linear blend is substantially cheaper but does not guarantee a higher presented FPS and can create ghosting around moving objects. The SDK defaults to motion-compensated VideoToolbox for interactive games and requires opt-in for blend.

The independent 4× VT quality probe (`./Audit/run-quality4.sh 120`) preserves Apple's `numberOfInterpolatedFrames=2` configuration and all three phases `[.25,.5,.75]`. Against the real recorded 60fps midpoint (phase .5 only), median generated luma PSNR was 46.99 dB, versus held frame 49.21 dB and pixel blend 56.41 dB, across 120 pairs. This clip has no 120fps truth for phases .25 and .75. Native 120fps gameplay/CGI ground truth and perceptual ghosting evaluation remain open.

## Automated display transition exercise

An opt-in `--ui-stress` reference-app test automatically exercised five phases on the connected pair of LG screens: primary window, fullscreen enter, fullscreen exit, rotated secondary display, primary return. Over 24 seconds, neither Metal nor VideoToolbox reported an error, and there were no nil drawables. Fresh FPS recovered to ~59.2 on the secondary and ~59.3 on the primary after transitions. Fullscreen entry/exit temporarily lowered frame rates to ~48–51 FPS, and the cumulative display-link callback deadline misses rose to 63. This does not provide optical evidence of zero black frames, tearing or flicker, but confirms window/display changes do not deadlock the display scheduler in this test.

## Additional sustained and platform status

The isolated adaptive fallback run at t=110 s changed 4×→2× after persistent over-budget batches. At 180–200 s, adaptive produced mean 59.5 FPS (minimum per-second 55.9), compared with fixed 4× mean 27.0 (minimum 20.0); software source→presentation P99 was 94.7 versus 228.5 ms. The adaptive route trades early synthetic peak FPS for a higher sustained floor. Neither run had Metal/VT command errors. Hardware display light output and controller input were not measured.

The system-wide GPU utilization counter may report zero while actual GPU execution accumulates. The library separately exposes `gpuCommandWorkPercent` as a *command-buffer work proxy*, not total GPU utilization.

Session identity is mandatory for reproducible live tests. In addition to immutable input buffer ownership, `--run-id=<safe-id>` separates both the replay ring and JSONL log by name. Some early purported backend and fallback tests were invalid due to the pre-fix property-copy omission or cross-run log interference; do not reuse those numbers.

## Extended compatibility and final SDK release-candidate screening

Some UVC capture devices can output full-range (420f) NV12 rather than the limited-range (420v) NV12 accepted by the original SDK. Sending 420f directly to Apple's VTFrameProcessor returned `VTFrameProcessorErrorDomain -19740` with underlying error `-50` on this Mac. Merely allowing the pixel format would produce interpolation errors.

Implemented bounded input-pool normalization from 420f to 420v with exact Y and UV range mapping before VideoToolbox. The SDK stores the unmodified original buffer for sampled-hash plus exact duplicate verification, and retains normalized buffers through GPU completion. A full-range 2x GPU regression passes without VideoToolbox/Metal errors. SDK internal tests verify full-range black (Y=0) maps to limited-range Y=16, white (255) to 235, neutral UV=128 remains 128, and a BT.601 YCbCr attachment survives conversion. The Metal conversion shader selects BT.601, BT.709 or BT.2020 coefficients using the supplied CoreVideo color matrix attachment; the default is BT.709. Native P010/HDR10/PQ/HLG transfer handling is NOT implemented.

A 150-sample 1920x1080 full-range→video-range CPU normalization microbenchmark on the M5 recorded P50=0.615 ms, P95=0.640 ms and P99=0.667 ms. This is a CPU-only conversion microbenchmark and should not be conflated with GPU frame generation or real capture-card latency. The AVCaptureVideoDataOutput adapter selects limited-range NV12 if supported, otherwise full-range NV12. Real UVC hardware negotiation remains unverified.

The final 21-second live 30→60 SDK run (seed 20261125) after the color changes recorded rolling fresh FPS 60.0; last-12s mean 59.75 FPS (min 58.95), processing P95 22.65 ms, presentation gap P99 30.31 ms, source-to-presentation P99 93.80 ms, adaptive playout delay 77.45 ms, memory 458.19 MiB, application CPU 19.0% of one core, 6 scaled texture allocations and 1242 reuses, no GPU/VT processing errors, and no dropped audio buffers. System-wide IOKit GPU counter returned 0%; measured Metal command-buffer work was nonzero (11.86% of elapsed time). The latter metric is GPU command-busy time for this pipeline, NOT overall GPU utilization or input-to-photon latency. Both the full SDK Objective-C regression suite and an external SwiftPM consumer build passed.

Nine additional randomized/seeded replay runs (source30@2x/4x, source60@2x; random seed0 and seeds112358,314159) had zero GPU, VT, audio or ingress errors. Fresh FPS ranged 58.3–59.6 for 30→60, 111.0–116.6 for 30→120, and 103.3–106.4 for 60→120 across those short sessions. They do not replace longer endurance tests.

Full machine-readable **verified** aggregate metrics and provenance are in `Audit/verified-results.json`, generated from the original per-run JSONL logs by `Audit/export-results.py`. Raw copyrighted test footage and raw JSONL traces are not committed.
