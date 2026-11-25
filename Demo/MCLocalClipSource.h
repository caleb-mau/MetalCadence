#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Delivers decoded local 720p30 frames at a wall-clock 30 Hz pace.
// Video only: source audio is intentionally not forwarded to the render lab.
NS_ASSUME_NONNULL_BEGIN
typedef void (^MCLocalClipFrame)(CVPixelBufferRef frame, double hostArrival);
typedef void (^MCLocalClipStatus)(NSString *message, NSError *_Nullable error);

@interface MCLocalClipSource : NSObject
@property (atomic, readonly) NSUInteger frames;
@property (atomic, readonly) NSUInteger loops;
@property (atomic, readonly) NSUInteger rejectedFrames;
@property (atomic, readonly) BOOL running;
- (void)startURL:(NSURL *)url
         onFrame:(MCLocalClipFrame)onFrame
        onStatus:(MCLocalClipStatus)onStatus;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
