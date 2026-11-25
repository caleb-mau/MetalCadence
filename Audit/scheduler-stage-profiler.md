# Presentation scheduler stage profiler

Separates CPU execution, intended frame timing, GPU queueing, and software
display presentation. Does NOT infer controller-to-photon or GPU pixels.

Stages recorded in bounded allocation-free sample windows:

- schedulerCallbackLockWait and schedulerSubmitLockWait: thread waits for lock.
- schedulerDrawableLookup: CAMetalDisplayLinkUpdate.drawable lookup, currently
  while lock is held.
- schedulerSelection: sorted queue deadline search.
- schedulerCallbackLockHeld: time callback holds scheduler lock.
- schedulerSubmitMutation: producer inserts/evicts frame from sorted queue.
- schedulerCommandBuffer: Metal command buffer allocation.
- encodeCost: CPU encode callback.
- schedulerHandlerSetup: callback registrations.
- schedulerPresentCommit: presentDrawable + commit submission.
- schedulerCallbackTotal: full drawn callback before asynchronous GPU/display.
- sourceToReady, readyToSelect, selectToPresent, scheduledWait, gpuQueueWait:
  separate processing/deadline/GPU and presentation waiting metrics.

These are individual P95 distributions, not the same-frame segments. Do NOT
sum percentiles or interpret planned scheduledWait as actual elapsed waiting.

Run the existing SDK 60 Hz visible-window replay benchmark and analyze JSONL:

    ./build-sdk-demo.sh
    open -n FrameLabSDK.app --args --benchmark --2x --refresh-hz=60 --seed=20261125 --run-id=profile-A
    python3 Tools/analyze-scheduler.py "$HOME/Library/Application Support/MetalCadence/sdk-metrics-profile-A.jsonl"

Compare at least five alternating baseline/candidate trials after optimizing a
specific measured bottleneck. Skip occluded or wrong-refresh runs.
