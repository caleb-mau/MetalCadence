#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Video-only ScreenCaptureKit window adapter, intentionally independent of
// Xbox authentication or Greenlight's streaming implementation.
typedef void (^MCWindowFrameHandler)(CVPixelBufferRef buffer, double hostArrivalTime);
typedef void (^MCWindowStatusHandler)(NSString *message, NSError *_Nullable error);

@interface MCWindowCapture : NSObject
@property (atomic, readonly) NSUInteger deliveredFrames;
@property (atomic, readonly) NSUInteger incompleteFrames;
@property (atomic, readonly) NSUInteger formatMismatches;
@property (atomic, readonly) NSUInteger idleFrames;
@property (atomic, readonly) NSUInteger rejectedFrames;
@property (atomic, readonly) double lastFrameArrival;
@property (nonatomic, copy, readonly) NSString *selectedWindowDescription;
- (void)startWithBundleIdentifier:(NSString *)bundleIdentifier
                    titleContains:(NSString *)windowTitle
                       frameWidth:(NSUInteger)width
                      frameHeight:(NSUInteger)height
                          onFrame:(MCWindowFrameHandler)onFrame
                         onStatus:(MCWindowStatusHandler)onStatus;
- (void)stop;
@end
