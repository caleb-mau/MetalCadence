#import <Foundation/Foundation.h>
#import "MCWorkloadProfile.h"
NS_ASSUME_NONNULL_BEGIN
typedef struct {
    double readyPrediction;
    double deadlineSafety;
} MCLatencyEstimate;

/// Adaptive software playout controller for timestamped interactive video.
/// All input times are durations in seconds; never controller-to-photon measurements.
/// Its state is bounded and safe to inspect concurrently from a telemetry thread.
@interface MCLatencyController : NSObject
@property (nonatomic, readonly) double currentDelay;
- (instancetype)initWithMinimumDelay:(double)minimum
                        maximumDelay:(double)maximum
                        initialDelay:(double)initial
                              policy:(MCFramePolicy)policy;
/// Call once after the GPU has completed one source-frame batch. All cumulative
/// counters must be monotonically increasing during one controller session.
/// queuedFrames is the caller-provided pressure depth; the engine supplies overdue frames only.
- (double)observeReadyAge:(double)readyAge
            refreshPeriod:(double)refreshPeriod
           outputInterval:(double)outputInterval
             queuedFrames:(NSUInteger)queuedFrames
          totalSuperseded:(uint64_t)totalSuperseded
            totalOverflow:(uint64_t)totalOverflow;
/// Record source timestamp age when an audio buffer reaches the output scheduling
/// queue. The controller uses this feedback to maintain a safe A/V playout floor.
/// Negative, non-finite, and stale (> 200ms) samples are rejected.
- (void)observeAudioSchedulingAge:(double)sourceAge;

/// Signals a missed audio presentation deadline so future video and audio
/// scheduling reserve more headroom until the stream remains stable.
- (void)recordAudioDeadlineMiss;

/// Allocation-free estimate in seconds, for use on the completion queue.
- (MCLatencyEstimate)estimate;
/// Immediate read-only telemetry; no full pipeline synchronization required.
- (NSDictionary<NSString *, NSNumber *> *)metrics;
@end
NS_ASSUME_NONNULL_END
