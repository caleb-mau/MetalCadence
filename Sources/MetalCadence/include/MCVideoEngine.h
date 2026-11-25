#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@class MCWorkloadProfile;
typedef NS_ENUM(NSInteger, MCDuplicateFingerprintMethod) {
    MCDuplicateFingerprintFNV,
    MCDuplicateFingerprintNEON
};
typedef NS_ENUM(NSInteger, MCInterpolationBackend) {
    MCInterpolationBackendVideoToolbox,
    MCInterpolationBackendLinearBlend
};
typedef NS_ENUM(NSInteger, MCVideoPresentation) {
    MCVideoPresentationCompare,
    MCVideoPresentationEnhanced,
    MCVideoPresentationOriginal,
    MCVideoPresentationUpscalingOnly,
    MCVideoPresentationFrameGenerationOnly
};
API_AVAILABLE(macos(26.0))
@interface MCVideoConfiguration : NSObject <NSCopying>
@property NSInteger inputWidth, inputHeight, outputWidth, outputHeight;
@property NSInteger multiplier; // 1, 2 or 4
/// Output/intermediate GPU pool budget in MiB; MetalFX/VT allocations excluded.
@property NSUInteger gpuTextureBudgetMiB;
/// Number of currently unused textures retained by each of the two output pools.
@property NSUInteger maxCachedTexturesPerPool;
/// How many textures to allocate once at startup in each pool. Zero is lazy.
@property NSUInteger preallocatedTexturesPerPool;
/// 1–4 independent MetalFX scratch/scaler slots. Default 2.
@property NSUInteger maxConcurrentGPUBatches;
@property MCInterpolationBackend interpolationBackend;
@property BOOL adaptiveMultiplier; // Optional 4x -> 2x fallback when a batch cannot meet deadline.
@property MCDuplicateFingerprintMethod duplicateFingerprintMethod;
@property BOOL adaptiveLatency, duplicateDetection, audioEnabled;
/// Opt-in protection against large motion discontinuities and hard cuts.
/// Intermediate output frames hold the preceding real frame instead of using
/// optical flow. Preserves frame pacing but not new motion detail at the cut.
@property BOOL suppressAbruptInterpolation;
@property double playoutDelay, minimumDelay, maximumDelay;
@property MCVideoPresentation presentation;
/// Opt in to skipping older due frames when three or more are backlogged.
/// Defaults to smooth selection; lowest-latency profiles enable this.
@property BOOL preferFreshestFrame;
/// Opt-in high-priority display-link run loop, separate from AppKit main run loop.
@property BOOL dedicatedPresentationThread;
/// Opt-in deferred frame selection. 0 disables; permitted 0..10 milliseconds.
/// Only enable with verified display deadline slack and a visible active screen.
@property double lateLatchDelaySeconds;
/// Opt-in: skip redundant GPU redraws when the displayed frame is unchanged.
@property BOOL skipRedundantPresentations;
/// Optional partial held-frame redraw interval. 1 retains existing behavior.
@property NSUInteger heldRefreshDrawEvery;
/// Frame selection lateness window expressed in display refreshes.
@property double presentationLatenessRefreshes;
@property (nonatomic, copy, nullable) MCWorkloadProfile *profile;
+ (instancetype)configurationWithProfile:(MCWorkloadProfile *)profile NS_SWIFT_NAME(make(profile:));
@end
/// All incoming timestamps are in host-clock seconds (CACurrentMediaTime).
/// Start/stop and attach on main thread. Submission is thread safe, bounded and nonblocking except
/// sampled deduplication. Input must be immutable NV12 video-range until the engine releases it.
/// The engine retains buffers as needed.
API_AVAILABLE(macos(26.0))
@interface MCVideoEngine : NSObject
/// Optional low-cost test instrumentation. Called after a fresh drawable is presented.
/// Software drawable time, not measured physical photons.
@property (atomic, copy, nullable) MCFramePresentedBlock onFreshFramePresented;
@property (nonatomic, readonly, copy) MCVideoConfiguration *configuration;
@property (atomic) MCVideoPresentation presentation;
@property (atomic) BOOL muted;
@property (atomic, readonly) BOOL running;
@property (atomic, readonly) double currentPlayoutDelay;
- (nullable instancetype)initWithConfiguration:(MCVideoConfiguration *)configuration
                                         layer:(CAMetalLayer *)layer
                                         error:(NSError **)error;
- (BOOL)startWithRefreshRate:(float)refreshRate error:(NSError **)error;
- (void)stop;
- (void)updateRefreshRate:(float)refreshRate;
- (BOOL)submitVideo:(CVPixelBufferRef _Nullable)buffer hostTime:(double)hostTime;
/// 48 kHz, interleaved stereo float PCM; copied before returning.
- (BOOL)submitAudio:(const float *)samples frameCount:(NSUInteger)count hostTime:(double)hostTime;
- (NSDictionary<NSString *, NSNumber *> *)metrics;
@end
/// AVFoundation capture adapter. Camera/microphone authorization and device selection belong to the
/// caller.
API_AVAILABLE(macos(26.0))
@interface MCCaptureSource : NSObject
+ (NSArray<AVCaptureDevice *> *)videoDevices;
- (instancetype)initWithEngine:(MCVideoEngine *)engine;
- (BOOL)startWithVideoDevice:(AVCaptureDevice *)video
                 audioDevice:(nullable AVCaptureDevice *)audio
                       error:(NSError **)error;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
