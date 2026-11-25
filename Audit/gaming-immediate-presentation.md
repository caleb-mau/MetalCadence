# Gaming-first immediate-presentation experiment

Goal: prioritize the first visible response to a newly decoded game frame.

Design:
- gameplayImmediate is opt-in, off by default.
- Each distinct source frame is NV12-converted and MetalFX-upscaled, then
  submitted directly for presentation without CAMetalDisplayLink lookahead.
- A bounded newest-wins queue retains at most one pending real source frame.
- VideoToolbox interpolation and future-frame dependence are disabled.
- Ordinary display-linked interpolation behavior is unchanged by default.
- The UI explicitly labels real-only 30 FPS rather than claiming 60 FPS.
- The engine still preserves GPU resource ownership until completion.

Acceptance: M5 native suite, synthetic real vs enhanced input response paired
test, source output count and 1440p upscale validation, zero GPU errors,
no false FPS claim. The Xbox's network and decoder latency are separate.


## First M5 validation (60Hz, 720p -> MetalFX 1440p)

- Six paired synthetic input events, same source timestamps for both sides.
- Source-to-presentation median: regular direct 720p 67.08ms;
  new gameplay 1440p 33.81ms.
- Input-to-presentation median: 80.27ms reference vs 55.71ms gaming.
- 394 source frames; gameplay presented 393 real frames.
- 33.33ms P99 gap expected from actual 30 FPS; no 2x interpolation.
- Zero GPU/interpolation errors. Normal 60FPS interpolation remains available
  when gaming mode is disabled.

The mode explicitly rejects audioEnabled=YES to avoid silent audio/video
desynchronization: Greenlight should remain responsible for audio.
