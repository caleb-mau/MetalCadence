# GTA V footage: live MetalFX + VideoToolbox test

Goal: decode real GTA V 1280x720/30fps footage to NV12 and use BOTH
MetalFX 2560x1440 spatial upscale AND VideoToolbox 2x framegen in real time.

Source: GTA 5 Gameplay - Free To Use, NoCopyrightGameplays,
Creative Commons Attribution license: https://www.youtube.com/watch?v=teBrvdnBVRk
Segment 01:00-01:20 was downloaded at 1280x720/60fps, then sampled at
30fps to simulate an Xbox One S 30fps stream. Input: 600 H.264 video frames,
1280x720 30fps, about 4Mbps. This is not direct Xbox footage.

AVFoundation decoder requests 8-bit NV12 CVPixelBuffers (420v video range).
Original left engine: 1280x720; right enhanced engine: MetalFX 2560x1440,
VideoToolbox 2x, target 60fps. GAME RESPONSE mode must be OFF since that
low-latency mode deliberately disables interpolated output.

Install sample at ~/Movies/MetalCadence GTA Tests/GTA-V-720p30.mp4
Build with ./build-latency-lab.sh
Open with:
  open -n MetalCadenceLatencyLab.app --args --source=clip --output=1440 --clip-path="$HOME/Movies/MetalCadence GTA Tests/GTA-V-720p30.mp4"
Add --clip-test --run-id=gta-combined-A for automatic 14sec test.

Expected summary: sourceMode=clip, decoded>300, output=2560x1440,
rightMultiplier=2, gameplayImmediate=false, generated presentations
approaching 60fps, no GPU/VT errors, visible window.
JSONL logs under ~/Library/Application Support/MetalCadence.

Video only, without audio feedback loops. This measures additional Mac
ingress-to-presentation delay, not Xbox controller-to-photon latency.


## First verified 14.02s M5 run

Actual 1280x720 GTA V footage decoded to 420v NV12, 419 decoded frames,
418 submitted source frames, 812 enhanced presented, 414 original presented.
Right output 2560x1440, 2x VideoToolbox, game-response mode OFF.
Effective new output 57.91 presented frames/sec. Median GPU processing
4.91ms, whole processing P95 15.54ms, source->presentation P50 105.19ms,
P99 122.55ms, output gap P99 33.33ms. Zero GPU/VT or decoder format errors,
and window was not occluded. This is a genuine live simultaneous pipeline
rather than offline re-encoding. We should continue reducing occasional
missed display refreshes and buffer-induced latency.


To validate looping, run the GTA clip test with
--clip-test-seconds=28. The source clip is 20 seconds long, so the
summary should report clipLoops>=1 and at least 760 decoded frames.
This is useful for catching AVAssetReader end-of-file and resource leaks.

## Sustained 28.02-second M5 run, including loop

The actual GTA V 720p30 sample was played beyond its 20-second duration,
forcing an AVAssetReader restart:

- 839 successfully decoded NV12 frames, 839 source frames submitted
- 1 source loop, 0 rejected source frames
- 835 720p original frames presented
- 1,647 1440p enhanced frames presented, 58.77 FPS
- MetalFX spatial scale AND VideoToolbox 2x frame generation simultaneously
- Processing P95 16.17ms, Metal GPU time median 5.40ms
- Source-to-presentation P50 109.87ms, P99 110.86ms
- Presentation gap P99 16.667ms
- Zero GPU and VideoToolbox errors, no occlusion

This is evidence of real-time throughput, not proof of satisfactory
controller-to-photon delay or artifact-free fast camera panning.
