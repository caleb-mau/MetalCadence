#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
NS_ASSUME_NONNULL_BEGIN
/// Returns the index of the earliest due frame within the lateness limit, or -1 if no frame is due.
FOUNDATION_EXPORT NSInteger MCSelectDueFrame(const double *pts,
                                             NSUInteger count,
                                             double target,
                                             double lateLimit);
/// Workload-dependent frame selection. Interactive mode discards older
/// already-due frames to minimize stale visuals when a backlog develops.
typedef NS_ENUM(NSInteger, MCFrameSelectionMode) {
    MCFrameSelectionSmooth = 0,
    MCFrameSelectionInteractive = 1
};
FOUNDATION_EXPORT NSInteger MCSelectDueFrameWithMode(const double *pts,
                                                     NSUInteger count,
                                                     double target,
                                                     double lateLimit,
                                                     MCFrameSelectionMode mode);
@interface MCFrame : NSObject
@property (nonatomic, readonly) int64_t identifier;
@property (nonatomic, readonly) CFTimeInterval pts;
@property (nonatomic, readonly) CFTimeInterval ready;
@property (nonatomic, readonly) CFTimeInterval sourceTime;
@property (nonatomic, readonly, strong) id payload;
- (instancetype)initWithID:(int64_t)identifier pts:(CFTimeInterval)pts payload:(id)payload;
- (instancetype)initWithID:(int64_t)identifier
                       pts:(CFTimeInterval)pts
                sourceTime:(CFTimeInterval)sourceTime
                   payload:(id)payload;
@end
/// Software drawable-presentation callback. Not a display photodiode measurement.
/// Invoked on Metal's presentation callback queue; never block or touch AppKit here.
typedef void (^MCFramePresentedBlock)(CFTimeInterval sourceTime,
                                      CFTimeInterval presentedTime,
                                      int64_t frameID);
typedef void (^MCEncodeBlock)(id<MTLCommandBuffer> commandBuffer,
                              id<CAMetalDrawable> drawable,
                              MCFrame *frame);
typedef struct {
    uint64_t superseded, reactiveSuperseded, overflow, callbackDeadlineMisses;
    NSUInteger queued, overdue;
    double callbackAgeMs;
} MCSchedulerPressure;

/// A bounded, timestamp-based Metal presentation engine. All timestamps are host-clock seconds
/// (CACurrentMediaTime). Start/stop on the main thread; submit from any producer thread. Encode
/// must be nonblocking.
@interface MCDisplayScheduler : NSObject <CAMetalDisplayLinkDelegate>
@property (atomic, copy, nullable) MCFramePresentedBlock onFreshFramePresented;
@property (nonatomic, readonly) NSUInteger capacity;
@property (nonatomic, readonly) NSUInteger maxInFlight;
@property (nonatomic) CFTimeInterval maxFrameLateness;
/// Maximum late-frame tolerance in display refresh intervals. Default 1.5.
/// Higher settings preserve more intermediate frames but may raise latency.
@property (nonatomic) double latenessRefreshAllowance;
/// Smooth preserves eligible intermediate frames; interactive favors recency.
@property (nonatomic) MCFrameSelectionMode selectionMode;
/// Effective queue depth, clamped to the construction-time capacity.
@property (nonatomic) NSUInteger maximumPendingFrames;
/// Experimental maximum deferred-selection interval in seconds (0 to .010).
/// 0 retains callback-time selection. Deferred selection runs off the UI thread
/// and never intentionally crosses the display link's submission deadline.
@property (nonatomic) double lateLatchDelaySeconds;
/// Optional high-QoS presentation run loop, independent of UI event handling.
/// Set before start; the default remains the main thread until validated.
@property (nonatomic) BOOL useDedicatedRenderThread;
/// Experimental: retain the previous drawable instead of encoding a duplicate
/// frame on every refresh. Requires explicit opt-in until display-transition
/// behavior is independently validated.
@property (nonatomic) BOOL skipHeldDraws;
/// When >1, redraw one of every N held refreshes rather than all of them.
/// Zero or one means draw every held refresh. skipHeldDraws overrides this.
@property (nonatomic) NSUInteger heldRefreshDrawEvery;
- (instancetype)initWithLayer:(CAMetalLayer *)layer
                       device:(id<MTLDevice>)device
                     capacity:(NSUInteger)capacity
                  maxInFlight:(NSUInteger)maxInFlight
                       encode:(MCEncodeBlock)encode;
- (void)startWithRefreshRate:(float)refreshRate;
- (void)stop;
- (BOOL)submit:(MCFrame *)frame;
/// Allocation-free pressure snapshot for producer-side scheduling. Overdue counts
/// only frames already past their scheduled presentation time, not future work.
- (MCSchedulerPressure)pressureCounters;
/// Lock-bounded pressure counters, without sorting historical latency samples.
- (NSDictionary<NSString *, NSNumber *> *)pressureSnapshot;
- (NSDictionary<NSString *, NSNumber *> *)metrics;
@end
NS_ASSUME_NONNULL_END

#import "MCWorkloadProfile.h"
#import "MCFrameBudgetController.h"
#import "MCLatencyController.h"
#import "MCVideoEngine.h"
