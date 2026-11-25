#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, MCVideoPresentation) { MCVideoPresentationCompare, MCVideoPresentationEnhanced, MCVideoPresentationOriginal, MCVideoPresentationUpscalingOnly, MCVideoPresentationFrameGenerationOnly };
API_AVAILABLE(macos(26.0))
@interface MCVideoConfiguration : NSObject <NSCopying>
@property NSInteger inputWidth,inputHeight,outputWidth,outputHeight;
@property NSInteger multiplier; // 1, 2 or 4
@property BOOL adaptiveLatency, duplicateDetection, audioEnabled;
@property double playoutDelay,minimumDelay,maximumDelay;
@property MCVideoPresentation presentation;
@end
/// All incoming timestamps are in host-clock seconds (CACurrentMediaTime).
/// Start/stop and attach on main thread. Submission is thread safe, bounded and nonblocking except sampled deduplication.
/// Input must be immutable NV12 video-range until the engine releases it. The engine retains buffers as needed.
API_AVAILABLE(macos(26.0))
@interface MCVideoEngine : NSObject
@property(nonatomic,readonly,copy) MCVideoConfiguration *configuration;
@property(atomic) MCVideoPresentation presentation;
@property(atomic) BOOL muted;
@property(atomic,readonly) BOOL running;
@property(atomic,readonly) double currentPlayoutDelay;
-(nullable instancetype)initWithConfiguration:(MCVideoConfiguration*)configuration layer:(CAMetalLayer*)layer error:(NSError**)error;
-(BOOL)startWithRefreshRate:(float)refreshRate error:(NSError**)error;
-(void)stop;
-(void)updateRefreshRate:(float)refreshRate;
-(BOOL)submitVideo:(CVPixelBufferRef)buffer hostTime:(double)hostTime;
/// 48 kHz, interleaved stereo float PCM; copied before returning.
-(BOOL)submitAudio:(const float*)samples frameCount:(NSUInteger)count hostTime:(double)hostTime;
-(NSDictionary<NSString*,NSNumber*>*)metrics;
@end
/// AVFoundation capture adapter. Camera/microphone authorization and device selection belong to the caller.
API_AVAILABLE(macos(26.0))
@interface MCCaptureSource : NSObject
+(NSArray<AVCaptureDevice*>*)videoDevices;
-(instancetype)initWithEngine:(MCVideoEngine*)engine;
-(BOOL)startWithVideoDevice:(AVCaptureDevice*)video audioDevice:(nullable AVCaptureDevice*)audio error:(NSError**)error;
-(void)stop;
@end
NS_ASSUME_NONNULL_END
