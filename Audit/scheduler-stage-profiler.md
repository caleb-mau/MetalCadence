# Presentation scheduler stage profiler

Separates CPU execution, intended frame timing, GPU queueing, and software
display presentation. Does NOT infer controller-to-photon or GPU pixels.

Stages recorded in bounded allocation-free sample windows:

- schedulerCallbackLockWait and schedulerSubmitLockWait: thread waits for lock.
- schedulerDrawableLookup: CAMetalDisplayLinkUpdate.drawable lookup, currently
  while lock is held.
- schedulerSelection: sorted queue deadline search.
- schedulerCallbackLockHeld: time callback holds scheduler lock.
- schedulerSubmitMutation: producer inserts/evicts frame from sorted queue.
- schedulerCommandBuffer: Metal command buffer allocation.
- encodeCost: CPU encode callback.
- schedulerHandlerSetup: callback registrations.
- schedulerPresentCommit: presentDrawable + commit submission.
- schedulerCallbackTotal: full drawn callback before asynchronous GPU/display.
- sourceToReady, readyToSelect, selectToPresent, scheduledWait, gpuQueueWait:
  separate processing/deadline/GPU and presentation waiting metrics.

These are individual P95 distributions, not the same-frame segments. Do NOT
sum percentiles or interpret planned scheduledWait as actual elapsed waiting.

Run the existing SDK 60 Hz visible-window replay benchmark and analyze JSONL:

    ./build-sdk-demo.sh
    open -n FrameLabSDK.app --args --benchmark --2x --refresh-hz=60 --seed=20261125 --run-id=profile-A
    python3 Tools/analyze-scheduler.py "$HOME/Library/Application Support/MetalCadence/sdk-metrics-profile-A.jsonl"

Compare at least five alternating baseline/candidate trials after optimizing a
specific measured bottleneck. Skip occluded or wrong-refresh runs.

## First native measured result, M5, 60 Hz (2026-11-25)

One seeded 1080p60 input / 30 unique fps / 1440p 2x replay:
- 59.08 fresh fps, 0.4358 ms drawn callback P95
- Encode 0.2481 ms, command creation 0.0446 ms, commit 0.0722 ms
- Lock-held 0.0155 ms, selection 0.0072 ms, drawable lookup 0.0008 ms P95
- Source-to-ready 64.34 ms, ready-to-select 44.045 ms, selected-to-present
  50.025 ms, GPU queue wait 0.839 ms P95
- Source-to-present P50 132.66 ms; no GPU/VT errors, 0 deadline misses.
- Latency controller repeatedly saturated pressure safety near 48 ms and
  playout delay at 125 ms; total queue overflow 0, 60 Hz display. Single
  supersessions despite a healthy GPU appeared to add safety headroom.

This is evidence that additional CPU scheduling micro-optimizations cannot
solve the dominant delay. Next experiment: conservative pressure classification
of benign single supersessions vs genuine multi-frame backlog/overflow. The
new controller policy must pass both 60 Hz frame integrity and latency metrics.


## Display submission deadline follow-up

The first benchmark showed targetPresentationTimestamp was 49.9 ms in
the future (roughly three 60 Hz periods), independent of CAMetalLayer drawable
queue depth (two vs three tested). The next metrics measure
targetTimestamp minus callback-entry time and targetTimestamp minus
command-commit completion time, including their 5th-percentile remaining
slack. These allow us to assess whether *late-latching* (selecting a newer
frame closer to submission) can reduce unnecessary ready-to-selection waiting
without violating the display-link deadline. Never interpret target timestamps
as guaranteed hardware scanout or controller-to-photon time.

### Measured M5 60 Hz deadline slack, 2026-11-25

Seeded 1080p/30 unique fps to 1440p/2x replay, fresh 59.14 FPS:
- callback-to-target-present P50: 49.877 ms
- callback-to-required-submit-deadline P05: 16.345 ms; P50: 16.543 ms
- remaining submission slack after GPU command commit P05: 15.999 ms;
  P50: 16.359 ms
- CPU draw callback P95: 0.323 ms; source-to-present P50: 125.36 ms
- 0 GPU errors, 0 interpolation errors, 0 deadline misses.

The hardware API requires presentation submission before targetTimestamp,
not before targetPresentationTimestamp. A safe experimental late-latch delay
of ~8 ms leaves about 8 ms submission margin in this specific 60Hz test.
This does NOT guarantee the same deadline slack at 120/165 Hz or under
thermal, fullscreen, external display, or UI contention.
