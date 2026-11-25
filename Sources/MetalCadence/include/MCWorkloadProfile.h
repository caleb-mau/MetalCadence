#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Describes the producer workload. This does not imply MetalCadence renders 3D scenes.
typedef NS_ENUM(NSInteger, MCWorkloadKind) {
    MCWorkloadKindInteractiveGame,
    MCWorkloadKindRealtime3D,
    MCWorkloadKindRemoteDesktop,
    MCWorkloadKindVideoPlayback,
    MCWorkloadKindLiveProduction,
    MCWorkloadKindOfflineRender
};
/// Chooses latency / smoothness / throughput tradeoffs, not a guaranteed FPS.
typedef NS_ENUM(NSInteger, MCFramePolicy) {
    MCFramePolicyMinimumBoost,
    MCFramePolicyLowestLatency,
    MCFramePolicySmooth,
    MCFramePolicyMaximumThroughput,
    MCFramePolicyEnergySaver
};
/// A descriptive property of the upstream producer, not a CPU interpolation backend.
typedef NS_ENUM(NSInteger, MCProducerKind) {
    MCProducerKindExternalCapture,
    MCProducerKindGPURenderer,
    MCProducerKindCPURenderer,
    MCProducerKindHybrid
};
@interface MCWorkloadProfile : NSObject <NSCopying>
@property MCWorkloadKind kind;
@property MCFramePolicy policy;
@property MCProducerKind producer;
@property double sourceFPS;
@property double displayFPS;
@property double minimumFreshFPS;
@property double preferredFreshFPS;
+ (instancetype)interactiveGameWithSourceFPS:(double)sourceFPS displayFPS:(double)displayFPS;
@end
/// A deterministic, side-effect free planning result. Native 1×, 2× or 4× interpolation
/// is selected at engine initialization; there is no automatic mid-session reconfiguration.
@interface MCWorkloadPlan : NSObject
@property (nonatomic, readonly) NSInteger multiplier;
@property (nonatomic, readonly) double targetFreshFPS, minimumFreshFPS;
@property (nonatomic, readonly) double minimumDelay, initialDelay, maximumDelay;
@property (nonatomic, readonly) BOOL adaptiveLatency;
- (instancetype)initWithProfile:(MCWorkloadProfile *)profile;
@end
NS_ASSUME_NONNULL_END
