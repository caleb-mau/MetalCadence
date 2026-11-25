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
