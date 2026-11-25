# Presentation Pipeline V2: engineering audit

**Date:** November 25, 2026
**Branch:** `feature/presentation-pipeline-v2`
**Target:** macOS Apple Silicon Objective-C++20 SDK, public Objective-C / Swift ABI preserved
**Status:** Experimental feature branch, not merged into the prior C++20 audit branch

## Purpose and current conclusion

The goal is consistent **fresh** output, reduced source-to-presentation
latency, stable display timing and unchanged visual/audio correctness.
This first phase delivers the instrumentation, independently configurable
scheduler behaviors and regression tests required to diagnose the pipeline.

**The requested performance target has not yet been met.** A matched 165 Hz
30→60 FPS replay began at 59.39 fresh FPS, 89.09 ms source-to-presentation P99
and 30.31 ms presentation-gap P99. The final default configuration measured
59.24 fresh FPS, 92.64 ms source-to-presentation P99 and 30.31 ms gap P99.

Those are short, independently launched, seed-matched tests, not sufficient
evidence of a statistically significant improvement or deterioration. The
original redraw and smooth frame-selection policies remain the defaults.

## Changes implemented

### 1. Workload-aware frame selection

`internal/MCDeadlineSelection.hpp` introduces a pure, deterministic C++20
selector with two strategies:

- **Smooth:** preserve the oldest completed eligible intermediate frame,
  subject to the existing refresh-dependent lateness tolerance
- **Interactive:** catch up to the freshest due frame when three or more
  frames become backlogged; do not discard the older of two normally due
  frames merely because the screen refreshed irregularly

An initial, too-aggressive interactive implementation reduced 30→60 fresh FPS
to approximately 56.2. The regression was reproduced and the unsafe choice
was removed as the default. `MCVideoConfiguration.preferFreshestFrame` is
opt-in, and the lowest-latency profile selects it explicitly. Ordinary
interactive-game minimum-boost configurations preserve smooth frame output.

Pending frame capacity is bounded to 12 in normal mode and 8 when
freshest-frame selection is requested. The adaptive buffer controller receives
only reactive backlog drops, not frame skips intentionally caused by a
low-latency selection policy.

### 2. Full presentation timeline

In addition to capture ingress, VideoToolbox processing, MetalFX work and
source-to-presentation delays already measured by the SDK, the scheduler
now exposes:

- Display callback gap P95/P99 and callback-to-target lead
- GPU-ready-to-selection P50/P95/P99
- CPU render-command encoding P50/P95
- Committed GPU command queue wait P95/P99
- Frame selection-to-presentation P95/P99
- Actual presentation time versus the requested target P95/P99
- Source-to-presentation and fresh presentation-gap P50/P95/P99
- Deliberate interactive skips, superseded frames, idle/held refreshes,
  callback deadline misses, no-drawable events and GPU errors

**All presentation timing sample windows are C++20 fixed-capacity (600
samples).** Recording on the display/presentation callbacks performs no
per-sample heap allocation, array shifts or percentile sorting. Metrics
snapshot the small rings under the existing lock, then calculate percentiles
outside the lock. The old Objective-C allocation-heavy presentation/gap
histograms have been migrated as well.

A prior metric defect only counted callback deadline misses when a draw was
submitted. The new counter records misses for *every* callback, including
intentionally skipped redraws. This prevents false zero-miss claims.

### 3. Optional dedicated display-link run loop

`CAMetalDisplayLink` can now be registered on an independent,
user-interactive-priority run loop. Registration, invalidation and teardown
occur on the worker's own thread. Startup, repeated stop/restart and
semaphore lifetime are explicitly handled. The main-thread run loop remains
the default.

Apple reference:
https://developer.apple.com/documentation/quartzcore/cametaldisplaylink

### 4. Optional redundant redraw reduction

The SDK can skip all held-frame draws, or redraw every second or third held
refresh. The display continues showing the preceding submitted frame without
requiring the SDK to encode identical pixels on every screen refresh.
These modes remain opt-in because full skip harmed fresh FPS and P99 pacing.

### 5. Configurable refresh-relative lateness

`presentationLatenessRefreshes` allows experiments beyond the original
1.5-refresh tolerance without changing the public frame-selection C
function's legacy behavior. The default remains 1.5 after the sweep failed
to demonstrate consistent improvements.

## Matched seeded results

All tests below use independent 1920×1080 recorded NV12 replay with 48 kHz
stereo PCM, seed 20261125 and software presentation timestamps. FPS excludes
held refreshes. No GPU, VideoToolbox or audio drops were reported in the
listed short-run tests.

### Original vs final default at actual 165 Hz

| Metric | Original C++20 | V2 default |
| --- | ---: | ---: |
| Fresh presented FPS | 59.39 | 59.24 |
| Source-to-presentation P99 | 89.09 ms | 92.64 ms |
| Fresh presentation gap P99 | 30.31 ms | 30.31 ms |
| GPU / VT / audio errors | 0 | 0 |

The V2 changes have **not yet improved the default P99 target**. The added
timing metrics explain the sources of delay more precisely. In the final run,
CPU encoding P95 was ~0.074 ms, GPU queue wait P95 ~0.478 ms, and display
callback-gap P99 ~21.34 ms. A significant share of the tail is above shader
execution, but neither correlation nor a single session proves the source of
each missed frame.

### Main thread versus dedicated run loop at 165 Hz

| Metric | Main | Dedicated |
| --- | ---: | ---: |
| Fresh FPS | 59.06 | 59.14 |
| Source-to-presentation P99 | 93.30 ms | 95.64 ms |
| Presentation-gap P99 | 30.31 ms | 30.31 ms |
| Callback-gap P99 | 9.90 ms | 9.30 ms |

The high-priority thread is functional, not a demonstrated latency win.
It remains opt-in. The fullscreen/secondary-monitor exercise reported zero
GPU, VideoToolbox and audio errors, and no missing drawables during five
window/fullscreen/display phases.

### Redundant held-frame redraw sweep at actual 165 Hz

| Policy | Fresh FPS | Source-to-present P99 | Gap P99 | Skipped draws |
| --- | ---: | ---: | ---: | ---: |
| Redraw all (default) | 59.57 | 94.19 ms | 30.31 ms | 0 |
| Every second | 59.09 | 87.87 ms | 30.31 ms | 716 |
| Every third | 58.09 | 88.55 ms | 42.43 ms | 1,012 |
| Skip all | 57.42 | 92.06 ms | 42.43 ms | 1,443 |

Skipping all draws regularized callbacks but visibly worsened fresh-frame
timing metrics. The every-second option is a plausible future optimization
but needs repeated seeds and independent optical continuity checks.

### Lateness tolerance sweep (actual 165 Hz)

| Tolerance | Fresh FPS | Source-to-present P99 | Gap P99 |
| --- | ---: | ---: | ---: |
| 1.5 refreshes | 59.33 | 93.83 ms | 30.31 ms |
| 2.0 refreshes | 59.18 | 94.16 ms | 36.37 ms |
| 2.5 refreshes | 58.98 | 100.12 ms | 30.31 ms |
| 3.0 refreshes | 59.47 | 92.79 ms | 36.37 ms |

No robust improvement: leave 1.5 as the default.

### Physical/requested display refresh coverage

| Physical monitor | Requested callbacks | Observed callbacks | Source → output | Fresh FPS | Gap P99 | Source-to-present P99 |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| 60 Hz | 60 Hz | ~60 Hz | 30 → 60 | 59.70 | 16.67 ms | 132.97 ms |
| 165 Hz | 120 Hz | ~162 Hz | 30 → 120 | 118.55 | 18.19 ms | 104.99 ms |
| 165 Hz | 165 Hz | ~160 Hz | 30 → 60 | 59.63 | 30.31 ms | 93.72 ms |

**Important:** macOS did not grant a separate 120 Hz callback rate on the
165 Hz display in this session. The 120 Hz experiment is a *requested* link
rate and 120 fresh-FPS goal, not a physical 120 Hz monitor-mode validation.
The actual 60 Hz monitor had a lower gap P99 but substantially higher
source-to-presentation latency. Do not compare these as if the physical
refresh conditions were equivalent.

## Public configuration and compatibility

The public API remains Objective-C and Swift-importable, with additive
properties on `MCVideoConfiguration`:

```objc
MCVideoConfiguration *config = [MCVideoConfiguration new];
config.preferFreshestFrame = NO;          // Smooth by default
config.dedicatedPresentationThread = NO;  // Main run loop by default
config.skipRedundantPresentations = NO;   // Draw held frames by default
config.heldRefreshDrawEvery = 1;          // Partial redraw opt-in at 2+
config.presentationLatenessRefreshes = 1.5;
```

The `MCDisplayScheduler` additionally exposes the selection enum and
bounded queue options for custom render-loop integrations. Existing
`MCSelectDueFrame` behavior is preserved; the additive
`MCSelectDueFrameWithMode` supports interactive selection.

## How to reproduce

```bash
./scripts/format.sh --check
./test-sdk.sh
(cd Examples/SwiftConsumer && swift run Smoke)
./build-sdk-demo.sh

# Matched 165 Hz callback-placement comparison
./Audit/run-presentation-v2.sh 20 20261125 30 2 165

# Compare duplicate redraw frequency
./Audit/run-held-redraw-sweep.sh 17 20261125

# Validate and regenerate aggregate evidence from local JSONL
python3 Audit/export-presentation-v2.py
```

The independent replay media is not committed. Raw per-run metrics live in
`~/Library/Application Support/MetalCadence/`. Aggregate,
machine-readable results are in `verified-presentation-v2.json`.

## Remaining problems

- P99 presentation gap remains ~30 ms in matched 165 Hz 30→60 tests;
  the desired ≤25 ms target is **not achieved**
- P99 source-to-presentation remains above the proposed <80 ms target
  in default 30→60 playback
- Input/controller-to-photon, visual tearing and black-frame detection
  need independent physical measurement
- Native physical 120 Hz mode was not validated; a requested callback rate
  is not sufficient evidence
- Real capture-card clock drift, discontinuities and long-duration A/V
  continuity still need testing
- Repeated randomized seeds and longer thermal runs are needed to establish
  any significant improvement from partial redraw modes
- Higher quality frame extrapolation and new shader algorithms were
  deliberately **not** included in this scheduler-focused change

**Release recommendation:** Retain original smooth/main-thread/redraw-all
defaults, merge only after independent review and sustained evidence.
The experimental options and instrumentation are useful for finding the
underlying presentation bottleneck; they are not a finished latency fix.
