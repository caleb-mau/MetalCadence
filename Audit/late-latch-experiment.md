# Experimental late-latched presentation, 60 Hz

Native M5 baseline on 2026-11-25:
- Display-link presentation target 49.877 ms ahead of callback
- targetTimestamp submission deadline 16.543 ms ahead
- 5th percentile deadline margin after normal commit 15.999 ms
- CPU callback P95 0.323 ms and GPU queue wait about 0.9 ms

This experiment delays frame **selection and draw submission**, not the display
presentation target. It retains the current update's drawable and schedules
the remaining CPU work on an interactive-QoS serial GCD queue. A requested
8ms delay is clipped to leave at least 6ms until targetTimestamp at the time
the callback fires. A late callback falls back to immediate draw. Delaying
selection may allow newly completed frames to be used instead of prematurely
committing an older frame 50ms before its target.

Run the exact seeded SDK benchmark with and without late latch:

    ./build-sdk-demo.sh
    open -n FrameLabSDK.app --args --benchmark --2x --refresh-hz=60 --seed=20261125 --run-id=no-latch
    open -n FrameLabSDK.app --args --benchmark --2x --refresh-hz=60 --seed=20261125 --run-id=latch8 --late-latch-ms=8

Run these sequentially, with the same visible display. Compare fresh FPS,
callbackDeadlineMisses, GPU/VT errors, frame gap P99, source-to-present P50/P99,
ready-to-select P95 and scheduled GPU/CPU work. Repeat alternating runs.

This experimental path MUST NOT become default without stable frame count,
no new deadline misses, and a confirmed reduction in user-visible source
delay. The 60Hz measured slack may not hold at 120Hz/165Hz, on an external
monitor, during occlusion or under thermal load.

## Native results, M5 Mac, 60Hz

All native SDK tests and two application builds passed. The opt-in mode runs
frame selection on a high-QoS serial queue; default 0ms remains unchanged.

Two paired 20s SDK replay comparisons, same seed and displayed 60Hz:

| Trial | 0ms source->present P50 | 8ms source->present P50 | 0ms fresh FPS | 8ms fresh FPS |
|---|---:|---:|---:|---:|
| A | 115.94ms | 118.67ms | 59.47 | 59.47 |
| B | 147.45ms | 130.31ms | 59.46 | 59.15 |

All four runs had a 16.667ms P99 output gap and zero GPU errors. The 8ms
request executed with about 8.3-8.5ms actual deferral, 7.6ms P05 remaining
submission slack, and zero deadline misses in those runs. Presentation
selection-to-display P95 decreased by roughly the deferral, as expected by
definition. The full source-to-display P50 did not improve consistently,
likely due to adaptive buffer and phase variation, so no claimed physical
latency gain is justified.

A native 1280x720 synthetic source to 2560x1440 MetalFX 2x interactive
lab with the option enabled produced 740 fresh frames from 378 source frames
over 12.62s, 16.667ms P99 gap, 0 GPU/interpolation errors, and about
7.95ms submission slack P05. Six input events completed successfully.

Safe status: an opt-in experiment, not production default, with further
A/B tests and physical Greenlight/Xbox gameplay required.
