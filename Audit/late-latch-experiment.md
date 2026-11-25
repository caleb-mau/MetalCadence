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
