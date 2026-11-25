# Workloads and FPS goals

The engine treats the producer workload independently of the frame-generation algorithm.

| Class | Why selected | Example source |
| --- | --- | --- |
| Interactive game | Minimum boost above native FPS with latency priority | Xbox HDMI 1080p60 containing 30 unique frames |
| Real-time 3D | High-throughput source, but 3D is rendered upstream | Unity, Unreal, local GPU render targets |
| Remote desktop | Lowest latency over synthetic FPS | Desktop/video streaming |
| Video playback | Consistent pacing | MP4 video decoding |
| Live production | Stable buffering, underrun monitoring | Broadcast switcher |
| Offline rendering | Best-quality/throughput rather than input responsiveness | Noninteractive exports |

Policies: minimum boost, lowest latency, smooth pacing, maximum throughput, energy saver. An app can specify source/display FPS plus minimum/preferred fresh FPS. The plan currently selects a fixed 1x/2x/4x multiplier and buffer timing. It does **not** dynamically switch the VideoToolbox multiplier mid-session. In the SDK, CPU/GPU producer labels are descriptive metadata only. Apple VideoToolbox and MetalFX are still used for processing; no CPU frame generation is implemented.

## Reproducibility

- Frame replay: independently decoded 1920x1080 60fps movie, with 30fps source created by decimation or an unduplicated 60fps source
- Transport: bounded shared-memory virtual capture ring, timestamped 48kHz stereo PCM, seeded or randomized jitter and dropped packets
- Evaluation: fresh presented IDs distinct from held refreshes, CPU/GPU timings, source-to-presentation timing, sample P50/P95/P99, memory, frames dropped and thermal state
- Hardware: M5 MacBook Air GPU, with one 165Hz 1440p display and a separate rotated display available
- Limitations: no real USB capture card, no HDMI signal, no controller-to-photon measurement; software presentation callbacks do not establish photon timing
- CPU sampled FNV vs ARM NEON vs GPU reduction: measured on 1080p NV12 sample buffers in `Audit/run-hashbench.sh`. GPU hash readback was slower despite a fast kernel
- Visual quality test: `Audit/run-quality.sh` uses the actual 60fps reference frames from a recorded video, compares VideoToolbox's generated odd frame against held and pixel-blend candidates; PSNR is not a perceptual gaming metric

## Runtime degradation

For apps prioritizing a minimum playable FPS, `MCVideoConfiguration.adaptiveMultiplier = true` (only for preferred 4× mode) creates a second, independent 2× VideoToolbox frame processor and destination pool. A separate `MCFrameBudgetController` uses the nominal source FPS, not gaps enlarged by dropped packets, to decide whether 4× is too expensive. Persistent over-budget batches downshift to 2×, then require a cooldown before probing 4× again when the system's thermal state is nominal. This avoids memory growth and never changes the user's underlying source FPS.

Do not force 4× for 30fps console gameplay unless the visual benefit outweighs the additional presentation and input latency; 2× minimum boost is the conservative default. Some output targets may be unrealistic on an external display refreshing at 165Hz and are necessarily subject to refresh pacing.
