# Greenlight Xbox Remote Play test: Xbox One S and GTA V

Build with ./build-latency-lab.sh, then open MetalCadenceLatencyLab.app.
The source toggle is **Connect Greenlight**.

1. At home, launch Greenlight and connect to Xbox One S Remote Play.
   Start GTA V and keep its game window visible. Xbox credentials remain
   exclusively in Greenlight.
2. Start MetalCadence Latency Lab. Click Connect Greenlight. If macOS asks
   for Screen & System Audio Recording permission, approve the app and
   reopen it if required by the OS.
3. Left shows Greenlight video through a minimally buffered native
   MetalCadence path. Right receives the exact same captured frames through
   VideoToolbox interpolation at selected 2x or 4x.
4. Move, drive, pan the camera quickly, drive at night, switch scenes,
   watch HUD/minimap movement and try explosions. Toggle Protect abrupt jumps.
   Compare quality, fresh FPS, frame pacing and drop/error counts.
5. Control the Xbox through Greenlight. The lab does NOT send controller inputs.
   Greenlight remains the audio player; ScreenCaptureKit audio capture is OFF
   to avoid echo or feedback loops.
6. For actual 120 Hz presentation, use a connected screen running at 120 Hz
   or higher. 120 generated frames on a 60 Hz display will be capped.
7. Close the lab to generate a JSONL summary under
   ~/Library/Application Support/MetalCadence/latency-lab-*.jsonl.
   Run python3 Audit/greenlight-evaluate.py <path-to-jsonl> to check health.

Explicit launch: open -n MetalCadenceLatencyLab.app --args --source=greenlight

Limits:
- This is a live rendered-window capture, not a direct Xbox decoder hook.
  ScreenCaptureKit receives output AFTER Greenlight's network and video decode,
  so capture-to-presentation measures only the extra Mac pipeline.
  It excludes controller-to-photon, Xbox encode and network latency.
- Captured NV12 1280x720 is requested at up to 60 Hz. The app currently
  chooses the largest visible Greenlight window using installed app bundle
  com.unknownskl.greenlight. Exact-hash duplicate detection will not
  necessarily identify compressed near-duplicate game frames. Verify the
  real unique-source rate, especially on a game locked to 30 FPS.
- Windows with account/login dialogs or menu bars may include overlays.
- ScreenCaptureKit permission, actual Xbox behavior, gameplay artifacts and
  sustained GPU thermals cannot be fully validated while away from the console.
- Telemetry JSONL records counters and timing, not pixels or credentials.
