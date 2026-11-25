# Scheduler efficiency follow-up

Existing hardware evidence: the final presentation V2 30-to-60 replay on a 165 Hz display had 22.24 ms P95 ready-to-selection, 24.24 ms P99 selection-to-presentation, 0.48 ms P95 GPU queue wait, and 0.074 ms P95 CPU encoding. These are stage percentiles, not additive measurements. There is no new Apple Silicon runtime result in this change.

Changes:
- Selection reads the bounded sorted timestamp queue directly rather than copying its timestamps on every display callback.
- Producer completion reads typed pressure and latency estimates instead of allocating Objective-C telemetry dictionaries. The old public dictionary interfaces remain.
- Future queued work does not count toward queue-depth pressure. Reactive supersession and overflow counters still apply; a future A/B should evaluate their influence separately.
- Scheduler metrics capture primitive counters under the lock and box them after unlocking. Timing rings remain bounded.
- Added per-frame source-to-ready, ready-to-present and scheduled-wait percentiles. For generated frames source time is the nominal interpolated source timestamp, not a physical HDMI or controller event.

Validation: portable scheduler selection and timing-window tests, generated shader verification, and whitespace checks on Linux. Native build, A/V correctness, display transitions, and M5 latency comparison remain required.

Next hardware benchmark: same seed/clip, 30 unique FPS, 2x, 1080p input and 1440p output, at 60/120/165 Hz, then physical 1440p capture. Run at least five alternating baseline/candidate trials per mode, report fresh FPS, P50/P95/P99 source-to-present, ready-to-present, scheduled wait, late frames, audio drops, thermal state, GPU errors, and CPU/GPU time. Do not infer improvements from the portable tests.
