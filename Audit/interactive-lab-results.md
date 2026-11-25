# Interactive source-to-presentation comparison

M5 MacBook Air, macOS 27, Xcode 27, active 60 Hz display, November 25 2026.
This is an interactive synthetic source. No HDMI capture, console, external
controller or photodiode is involved. The left/right engines receive exactly
the same host-clock NV12 source buffers, at nominal 30 unique FPS.

## What is being measured

For each Space/arrow/synthetic action, the source changes at the next 30 Hz
producer tick. The software timing hook records the actual Metal drawable's
presentedTime for the first fresh output whose source timestamp is at least
the changed source frame's timestamp. Values therefore include event-to-source
sampling and software presentation but exclude physical panel scanout. When a
generated intermediary begins showing the new scene earlier than the first
fully changed native frame, this hook does not mark the earlier blending.

## First controlled runs

| Mode | Source frames | Original fresh presents | Generated fresh presents | Extra event-to-present median | Right presentation-gap P99 | Errors |
|---|---:|---:|---:|---:|---:|---|
| Adaptive (default) | 396 | 393 | 772 | 50 ms | 33.33 ms | 0 GPU/VT |
| Fixed 55 ms | 394 | 390 | 390 | 33.33 ms | 50.00 ms | 0 GPU/VT |

Each row used six programmatically scheduled actions and a window visible on
the same 60 Hz display. Short runs are not confidence intervals or proof of
controller-to-photon latency.

**Do not ship 55 ms as an FPS improvement.** It reduces the measured event
delay while silently dropping about half the generated frames. GPU processing
P95 was approximately 9 ms. This points to source lookahead, scheduling
phase and deadline selection rather than a saturated GPU. Testing a two-frame
overdue queue policy and refresh alignment is the next step.

The app supports interactive keypresses, changing 60/120 generation, fixed
and adaptive playout modes, independent 30 FPS reference rendering, and event
JSONL logs.
