# GTA V visual QA: original 720p vs MetalFX 1440p + VideoToolbox 2x

## What visual inspection caught that timing tests missed

Observed the actual Mac GUI using native computer screenshots with the
20-second, 720p30 GTA V Creative Commons sample. The original benchmark
had reported 57-59 enhanced presents/sec with no GPU/interpolation errors.

**FAIL, original UI:** original video was drawn at the lower-left window
origin and the enhanced right-hand panel was empty/black in the screenshot.
Cause: Demo/LatencyLab.mm manually set both independent backing
CAMetalLayer.frame to surface.bounds, whose origin is (0,0); this bypassed
the NSView's parent-space placement. Draw submissions still completed, so
GPU and FPS metrics could not detect that users saw the wrong content.

**FIX:** use MCLabMetalSurfaceView overriding makeBackingLayer to supply a
CAMetalLayer, and let AppKit own the surface frame during initial layout,
resize and screen changes. LabAttach manages only Retina contentsScale and
drawableSize. Both source 720p and enhanced 1440p preview panels now
appear in their proper columns. Actual screenshots showed a moving GTA V
character, buildings, HUD and a post-death scene in both panels.

## Screenshot regression

Audit/visual-output-qa.py captures only the MetalCadence window and checks
nonzero visual contrast in the source and enhanced video regions.
Mac results (grayscale standard deviation; black region ~0):

- Five original/enhanced samples: left 44.9-79.6, right 44.8-83.2.
- Three maximized-window samples: left 64.4-76.2, right 65.9-78.7.
- Three restored-window samples: left 46.1-62.2, right 44.8-60.3.
- No input or enhancement GPU errors in the native SDK suite.

Source footage has a genuine dark fade from 8.83s to 9.80s (confirmed with
ffmpeg blackdetect), so the screenshot validator samples several times
rather than failing on a single legitimate black input frame.

## What is *not* established

- A correctly populated screenshot does not prove every interpolated
  in-between frame has correct motion, clean edges or zero ghosting.
- The current native window recorder managed ~28 recorded frames/sec,
  despite requesting 60; it misses many intermediate generated frames.
- Both previews are only ~620 pixels wide on the current window. Even though
  the GPU enhanced texture is 2560x1440, the downsampled comparison panels
  cannot prove native-resolution sharpness improvement.
- 720p30 sample was made by taking 30 frames/sec from a public GTA V 720p60
  clip, not from the user's own Xbox One S. Actual controller, remote-play
  encoding/decoding, and network delay are excluded.
- The live enhanced pipeline still has ~105-110ms software
  source-to-presentation latency. This is material for interactive gaming.

## Next fidelity test design

The original 720p60 GTA V recording is also available in the user's local
Movies/MetalCadence GTA Tests folder. Use its odd original frames as
*ground truth* for the interpolated frames synthesized from even 720p30
source frames, while matching source timestamps and excluding overlays
that are expected to legitimately change. Independently capture the
actual 2560x1440 generated GPU frames for 1:1 details and artifact review.
Analyze motion around the player, abrupt camera changes, vehicle edges,
HUD/minimap text, occlusion and black scene transitions. Compare with
no framegen and lower-buffer gaming mode. Do not claim that metric FPS is
the same as experienced smoothness or input responsiveness.
