# Objective-C++20 migration and GPU efficiency audit

**Date:** November 25, 2026
**Branch:** `feature/objective-cpp20`
**Target:** Apple Silicon macOS SDK with a stable Objective-C/Swift public API
**Status:** Experimental, validated on an Apple M5 MacBook Air; not yet production qualified

## Design decisions

The migration uses **Objective-C++ for internal implementation**, not because the language intrinsically makes shaders or interpolation run faster. Public headers remain standard Objective-C, compatible with Swift. The Swift Package declares `cxxLanguageStandard: .cxx20`; the macOS demo, tests, diagnostics, and capture app build as `.mm` with `clang++ -std=c++20`.

Internal changes deliberately remain small in scope:

1. `internal/MCTexturePool.hpp` uses C++20 RAII ownership with ARC-retained Metal textures, `std::mutex`, `std::vector` for the reusable stack, and an `unordered_map` to track outstanding resources. It ignores foreign/double returns.
2. A shared `TextureBudget` caps the **accounted** active plus cached output/native private textures. It does **not** cap all GPU allocations made by VideoToolbox, MetalFX, CoreVideo, drawables or the driver.
3. The SDK exposes `gpuTextureBudgetMiB` (default 512), `maxCachedTexturesPerPool` (default 12), `preallocatedTexturesPerPool` (default 0, lazy) and `maxConcurrentGPUBatches` (default 2, allowed 1 to 4). The values survive configuration copies and remain usable from Swift.
4. A `std::bitset<4>` replaces the old Objective-C index set for GPU slot availability. Each concurrently active slot owns a separate MetalFX scaler and scratch texture. Existing async command-buffer completion and payload ownership are retained. Production processing **does not call** `waitUntilCompleted`.
5. The SDK's immutable compute/render pipeline states are cached by Metal-device identity and render pixel format. Bundled applications load precompiled Metal libraries; direct SwiftPM library use retains a generated source fallback. Initial pipeline compilation remains a cold-start cost.
6. The authoritative `Shaders/Production.metal`, `Diagnostic.metal` and `LegacyDemo.metal` files are separate, readable and compiled at build time. Generated headers are checked against these sources; generated files must not be edited manually. The production SDK never uses diagnostic kernels.
7. Frame generation, VideoToolbox interpolation phases, source timestamp handling, NV12 color conversions, audio processing and presentation selection remain functionally unchanged except for resource scheduling and telemetry. A new presentation/source-to-display P50 complements existing P95/P99.

**Not implemented:** custom motion estimation, custom optical flow, temporal upscaling, universal Metal heap allocation, GPU shader fusion, HDR10/P010 transfer processing or a new CPU frame-generation backend. Those require independent benchmarks and visual correctness tests.

## Verified baseline versus migrated SDK

Both runs used independent 1920×1080 recorded NV12 replay through the virtual capture process, the same fixed transport seed 20261125, one visible SDK window on the **165 Hz LG display**, a 30 FPS unique source, 2× VideoToolbox generation and 1440p output. Measurement windows are short (~17 seconds after startup) and subject to normal OS scheduling.

| Metric | Original Objective-C | Objective-C++20 |
| --- | ---: | ---: |
| Fresh FPS, excluding held refreshes | 59.33 | 59.18 |
| Processing P95 | 22.43 ms | 22.48 ms |
| Source-to-presentation P99 | 94.39 ms | 92.70 ms |
| Presentation gap P99 | 30.31 ms | 36.37 ms |
| Process footprint | 549.6 MiB | 451.3 MiB |
| Output texture allocations | 10 | 6 |
| Output texture reuse operations | 1,360 | 1,360 |
| Audio / Metal / VideoToolbox errors | 0 | 0 |

The measured **throughput is effectively unchanged**. The after run reported fewer output texture allocations and a lower process memory footprint, but a **worse presentation-gap P99**. A 1.69 ms difference in source-to-present P99 is not robust evidence of a latency improvement without repeated matched runs. Do not market this as a frame-generation speedup.

## Texture cache capacity experiment

Six isolated ~8–9-second steady-state runs used **60 Hz** window presentation, a 30 FPS source and 2× interpolation. Their latency numbers are therefore **not directly comparable** with the preceding 165 Hz baseline. All runs reported zero GPU, VideoToolbox or audio errors.

| Preallocated per pool | Fresh FPS | Peak accounted pool memory | Output allocations |
| --- | ---: | ---: | ---: |
| 0 (lazy) | 59.65 | 181.8 MiB | 8 |
| 8 | 59.44 | 181.8 MiB | 8 |
| 12 | 59.61 | 272.6 MiB | 12 |
| 16 | 59.44 | 363.5 MiB | 16 |
| 24 | 59.43 | 545.2 MiB | 24 |
| 32 | 59.50 | 727.0 MiB | 32 |

Lazy allocation reached about 99% lifetime reuse after warmup. Larger prewarmed pools did not increase fresh FPS and reserved considerably more accounted GPU resources. **Decision:** prewarm 0, cache capacity 12, 512 MiB accounted pool budget by default. Cache capacity does not force preallocation.

## Mode and in-flight slot matrix

All cases used the independent virtual capture and **165 Hz display**:

| Source → target | GPU slots | Fresh FPS | Processing P95 | Source-to-present P99 | Presentation gap P99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 30 → 30 | 2 | 30.14 | 4.59 ms | 49.92 ms | 48.50 ms |
| 30 → 60 | 2 | 58.86 | 22.78 ms | 93.02 ms | 30.31 ms |
| 30 → 120 | 2 | 118.64 | 36.25 ms | 108.31 ms | 12.12 ms |
| 60 → 60 | 2 | 58.85 | 4.21 ms | 45.45 ms | 36.37 ms |
| 60 → 120 | 2 | 114.75 | 14.52 ms | 74.48 ms | 18.19 ms |
| 30 → 60 | 1 | 58.83 | 22.77 ms | 93.23 ms | 36.37 ms |
| 30 → 60 | 3 | 58.77 | 23.23 ms | 94.25 ms | 36.37 ms |

Zero GPU/VideoToolbox/audio errors were reported. The 4× number is a short-run result and **does not demonstrate sustained 120 FPS**; an earlier long-duration audit documented fixed-4× deterioration. Three slots did not meaningfully improve throughput or latency relative to two. **Decision:** maintain two in-flight slots by default, configurable within 1–4.

## Metal heap and shader experiments

A controlled allocator microbenchmark created private RGBA8 textures at 1080p and 1440p in batches of 8/16/24/32. Direct `newTextureWithDescriptor:` creation was already roughly 0.002–0.006 ms per allocation; `MTLHeap` allocations were roughly 0.0007–0.002 ms after heap creation (0.01–0.03 ms). This only measures **CPU allocation API time**, not rendering latency, GPU bandwidth, aliasing hazards or application throughput. Heap reservation can exceed 400 MiB in the 32-texture 1440p case. **Decision:** keep direct private-texture pools. Do not introduce heap allocation until a real workload shows a sustained benefit.

Ahead-of-time compiled production shaders and generated source fallbacks were tested on actual Metal hardware for BT.601, BT.709 and BT.2020 color coefficients, video/full NV12 range and neutral chroma. Outputs matched within one byte per sampled component. The shader implementation preserves color accuracy; no claimed performance advantage from stylistic formatting or removing redundant source text.

The app startup reports whether it loaded a precompiled library and whether its pipeline bundle was cached. Cold pipeline initialization still incurred a measurable startup cost. Warm reuse avoids rebuilding pipeline states in the same process, but a warm/cold startup distribution benchmark has not been completed.

## Final visual and CPU microbenchmark regressions

Recorded-video quality tests against 80 reference pairs completed in both
2× and 4× VideoToolbox modes, with no pair crossing the existing coarse
large-error threshold. The median luma PSNR was 46.36 dB for the generated
midpoint, 45.56 dB for the held frame and 49.42 dB for a mathematical blend.
The blend scoring higher on this clip does **not** establish better subjective
gaming quality. The 4× test has real reference frames only at phase 0.5,
not at phases 0.25 and 0.75.

C++20 compilation did not change the underlying SIMD duplicate detection
algorithm. On the M5, the 120-sample standalone benchmark measured sampled
NEON P50 0.005 ms, sampled FNV P50 0.029 ms, GPU reduction including
readback P50 0.519 ms, and GPU execution alone P50 0.027 ms. The GPU
readback synchronization dominates, so the existing CPU fingerprint plus
exact verification remains the default. A 150-sample full-range→video-range
1080p NV12 conversion measured P50 0.565 ms and P95 0.630 ms; this is
CPU-only preprocessing and not controller-to-screen latency.

## Validation

- Native Objective-C++ SDK tests, configuration copies, video pipeline integration and exact 1×/2× frame-count tests, including 1/2/3 in-flight slots
- C++20 resource tests for pool budget denial, valid reuse, double-return refusal, cache eviction and end-of-life budget cleanup
- External Swift Package consumer builds and runs using unchanged Objective-C-facing interfaces
- Actual Metal source-vs-precompiled library color output comparison
- Build-time `clang-format` enforcement over `.mm`, `.hpp`, `.h` and `.metal`; generated shader headers are checked for deterministic regeneration
- Both standalone diagnostic capture and normal SDK demo build with precompiled GPU shaders
- Software metrics: distinct fresh FPS, processing P50/P95/P99, source-to-present P50/P95/P99, gap P50/P95/P99, output allocation/reuse, tracked pool memory, CPU time, GPU command timestamps, drops and thermal state

Raw per-run JSONL logs are kept under Application Support, not committed. The [verified aggregate results](verified-cpp20-results.json) can be regenerated with:

```bash
./Audit/run-cpp20-pools.sh 16 20261125
./Audit/run-cpp20-cadence.sh 15 20261125
./Audit/run-metal-heaps.sh
python3 Audit/export-cpp20.py
```

## Known limitations and next bottlenecks

- Real USB/UVC HDMI capture, timing and stereo output recovery have not been validated against a physical capture card
- Source-to-drawable timestamps are software measurements; controller-to-photon and visible tearing/blackouts need independent measurement
- 4× and 60→120 throughput need repeated sustained thermal testing
- Shader threadgroup, fused passes and Metal heap aliasing need measured quality-correct comparisons before production integration
- Per-engine limits cover output/native textures only; full GPU working-set budgets require additional allocations and drivers to be accounted for
- P010/HDR color and native high-motion gaming reference material remain unimplemented/untested
- The observed P99 presentation regression relative to the original build must be investigated rather than obscured by process memory savings

**Conclusion:** Objective-C++20 is now a usable, better-structured foundation for future algorithms and resource policies. It is not an automatic FPS optimization. The tested cache-sizing and GPU-slot results justify conservative defaults instead of overallocating unified memory.
