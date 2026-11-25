#import "MCLocalClipSource.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

@interface MCLocalClipSource ()
@property dispatch_queue_t decodeQueue;
@property dispatch_source_t sourceTimer;
@property AVAssetReader *reader;
@property AVAssetReaderTrackOutput *output;
@property NSURL *url;
@property (nonatomic, copy) MCLocalClipFrame onFrame;
@property (nonatomic, copy) MCLocalClipStatus onStatus;
@property (atomic, readwrite) NSUInteger frames, loops, rejectedFrames;
@property (atomic, readwrite) BOOL running;
@property (atomic) NSUInteger generation;
@end

@implementation MCLocalClipSource
- (instancetype)init {
    if ((self = [super init]))
        _decodeQueue =
            dispatch_queue_create("com.metalcadence.local-clip.decode", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)report:(NSString *)message error:(NSError *)error {
    MCLocalClipStatus callback = self.onStatus;
    if (callback)
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(message, error);
        });
}
- (BOOL)openReader {
    NSError *error = nil;
    AVAsset *asset = [AVURLAsset URLAssetWithURL:self.url options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    CGSize size = track.naturalSize;
    float fps = track.nominalFrameRate;
#pragma clang diagnostic pop
    if (!track || llround(size.width) != 1280 || llround(size.height) != 720 ||
        fabs(fps - 30.0f) > 1.0f) {
        [self report:@"Video must be 1280×720 at approximately 30 FPS." error:nil];
        return NO;
    }
    self.reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!self.reader) {
        [self report:@"Cannot create video reader." error:error];
        return NO;
    }
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    self.output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                             outputSettings:settings];
    self.output.alwaysCopiesSampleData = NO;
    if (![self.reader canAddOutput:self.output]) {
        [self report:@"Video decoder output cannot be attached." error:nil];
        return NO;
    }
    [self.reader addOutput:self.output];
    if (![self.reader startReading]) {
        [self report:@"Cannot decode video." error:self.reader.error];
        return NO;
    }
    return YES;
}
- (void)tick:(NSUInteger)generation {
    if (!self.running || generation != self.generation)
        return;
    CMSampleBufferRef sample = [self.output copyNextSampleBuffer];
    if (!sample && self.reader.status == AVAssetReaderStatusCompleted) {
        self.loops++;
        self.output = nil;
        self.reader = nil;
        if (![self openReader]) {
            [self stop];
            return;
        }
        sample = [self.output copyNextSampleBuffer];
    }
    if (!sample) {
        self.rejectedFrames++;
        if (self.reader.status == AVAssetReaderStatusFailed) {
            [self report:@"Video decoder failed." error:self.reader.error];
            [self stop];
        }
        return;
    }
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    if (!pixel || CVPixelBufferGetWidth(pixel) != 1280 || CVPixelBufferGetHeight(pixel) != 720 ||
        CVPixelBufferGetPixelFormatType(pixel) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.rejectedFrames++;
        CFRelease(sample);
        return;
    }
    CVPixelBufferRetain(pixel);
    CFRelease(sample);
    self.frames++;
    MCLocalClipFrame callback = self.onFrame;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == self.generation && self.running && callback)
            callback(pixel, CACurrentMediaTime());
        CVPixelBufferRelease(pixel);
    });
}
- (void)startURL:(NSURL *)url
         onFrame:(MCLocalClipFrame)onFrame
        onStatus:(MCLocalClipStatus)onStatus {
    if (self.running)
        return;
    self.url = url;
    self.onFrame = onFrame;
    self.onStatus = onStatus;
    self.frames = 0;
    self.loops = 0;
    self.rejectedFrames = 0;
    self.running = YES;
    NSUInteger generation = ++self.generation;
    dispatch_async(self.decodeQueue, ^{
        if (!self.running || generation != self.generation)
            return;
        if (![self openReader]) {
            [self stop];
            return;
        }
        [self report:[NSString stringWithFormat:@"Playing %@ (30 FPS, looped)",
                                                self.url.lastPathComponent]
               error:nil];
        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.decodeQueue);
        self.sourceTimer = timer;
        dispatch_source_set_timer(
            timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, NSEC_PER_MSEC);
        __weak MCLocalClipSource *weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            [weakSelf tick:generation];
        });
        dispatch_resume(timer);
    });
}
- (void)stop {
    self.running = NO;
    ++self.generation;
    dispatch_async(self.decodeQueue, ^{
        if (self.sourceTimer) {
            dispatch_source_cancel(self.sourceTimer);
            self.sourceTimer = nil;
        }
        [self.reader cancelReading];
        self.output = nil;
        self.reader = nil;
    });
}
@end
