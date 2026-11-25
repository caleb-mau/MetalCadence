#import "MCWindowCapture.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>

@interface MCWindowCapture () <SCStreamOutput, SCStreamDelegate>
@property SCStream *stream;
@property (nonatomic, copy) MCWindowFrameHandler frameHandler;
@property (nonatomic, copy) MCWindowStatusHandler statusHandler;
@property (nonatomic, copy, readwrite) NSString *selectedWindowDescription;
@property dispatch_queue_t sampleQueue;
@property (atomic) BOOL running;
@property (atomic, readwrite) NSUInteger deliveredFrames;
@property (atomic, readwrite) NSUInteger incompleteFrames;
@property (atomic, readwrite) NSUInteger formatMismatches;
@property (atomic, readwrite) NSUInteger idleFrames;
@property (atomic, readwrite) NSUInteger rejectedFrames;
@property (atomic, readwrite) double lastFrameArrival;
@property NSUInteger expectedWidth, expectedHeight;
@property NSUInteger selectionGeneration;
@end

@implementation MCWindowCapture

- (instancetype)init {
    if ((self = [super init])) {
        _sampleQueue =
            dispatch_queue_create("com.metalcadence.greenlight.capture", DISPATCH_QUEUE_SERIAL);
        _selectedWindowDescription = @"Not connected";
    }
    return self;
}

- (void)report:(NSString *)message error:(NSError *)error {
    MCWindowStatusHandler callback = self.statusHandler;
    if (callback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(message, error);
        });
    }
    if (error)
        NSLog(@"MC_GREENLIGHT_CAPTURE %@ error=%@", message, error);
    else
        NSLog(@"MC_GREENLIGHT_CAPTURE %@", message);
}

- (void)startWithBundleIdentifier:(NSString *)bundleIdentifier
                    titleContains:(NSString *)windowTitle
                       frameWidth:(NSUInteger)width
                      frameHeight:(NSUInteger)height
                          onFrame:(MCWindowFrameHandler)onFrame
                         onStatus:(MCWindowStatusHandler)onStatus {
    if (self.running || self.stream) {
        [self report:@"Stop the existing capture before selecting another window." error:nil];
        return;
    }
    self.frameHandler = onFrame;
    self.statusHandler = onStatus;
    self.expectedWidth = width;
    self.expectedHeight = height;
    self.deliveredFrames = 0;
    self.incompleteFrames = 0;
    self.idleFrames = 0;
    self.rejectedFrames = 0;
    self.formatMismatches = 0;
    self.lastFrameArrival = 0;
    NSUInteger generation = ++self.selectionGeneration;
    [self report:@"Searching visible windows. macOS may request Screen Recording permission."
           error:nil];
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:YES
                               onScreenWindowsOnly:YES
                                 completionHandler:^(SCShareableContent *content, NSError *error) {
                                     if (generation != self.selectionGeneration)
                                         return;
                                     if (error || !content) {
                                         [self report:@"Unable to enumerate windows. Check macOS "
                                                      @"Screen Recording permission."
                                                error:error];
                                         return;
                                     }
                                     SCWindow *choice = nil;
                                     CGFloat bestArea = 0;
                                     NSString *filter = bundleIdentifier.lowercaseString ?: @"";
                                     NSString *titleFilter = windowTitle.lowercaseString ?: @"";
                                     for (SCWindow *window in content.windows) {
                                         NSString *bundle =
                                             window.owningApplication.bundleIdentifier
                                                     .lowercaseString
                                                 ?: @"";
                                         NSString *owner = window.owningApplication.applicationName
                                                                   .lowercaseString
                                                               ?: @"";
                                         NSString *title = window.title.lowercaseString ?: @"";
                                         if (filter.length && ![bundle isEqualToString:filter] &&
                                             [owner rangeOfString:filter].location == NSNotFound)
                                             continue;
                                         if (titleFilter.length &&
                                             [title rangeOfString:titleFilter].location ==
                                                 NSNotFound)
                                             continue;
                                         CGFloat area =
                                             window.frame.size.width * window.frame.size.height;
                                         if (area > bestArea && window.frame.size.width >= 200 &&
                                             window.frame.size.height >= 150) {
                                             bestArea = area;
                                             choice = window;
                                         }
                                     }
                                     if (!choice) {
                                         [self
                                             report:[NSString
                                                        stringWithFormat:
                                                            @"No visible Greenlight window found "
                                                            @"for %@. Open Xbox Remote Play first, "
                                                            @"then select Connect again.",
                                                            bundleIdentifier]
                                              error:nil];
                                         return;
                                     }
                                     self.selectedWindowDescription = [NSString
                                         stringWithFormat:@"%@ · %@ (%u)",
                                                          choice.owningApplication.applicationName
                                                              ?: @"Window",
                                                          choice.title ?: @"Untitled",
                                                          (unsigned)choice.windowID];
                                     SCContentFilter *contentFilter = [[SCContentFilter alloc]
                                         initWithDesktopIndependentWindow:choice];
                                     SCStreamConfiguration *configuration =
                                         [SCStreamConfiguration new];
                                     configuration.width = self.expectedWidth;
                                     configuration.height = self.expectedHeight;
                                     configuration.minimumFrameInterval = CMTimeMake(1, 60);
                                     configuration.pixelFormat =
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
                                     configuration.queueDepth = 3;
                                     configuration.scalesToFit = YES;
                                     configuration.preservesAspectRatio = YES;
                                     configuration.showsCursor = NO;
                                     configuration.capturesAudio = NO;
                                     self.stream = [[SCStream alloc] initWithFilter:contentFilter
                                                                      configuration:configuration
                                                                           delegate:self];
                                     NSError *outputError = nil;
                                     if (![self.stream addStreamOutput:self
                                                                  type:SCStreamOutputTypeScreen
                                                    sampleHandlerQueue:self.sampleQueue
                                                                 error:&outputError]) {
                                         self.stream = nil;
                                         [self report:@"ScreenCaptureKit rejected video output."
                                                error:outputError];
                                         return;
                                     }
                                     [self.stream startCaptureWithCompletionHandler:^(
                                                      NSError *startError) {
                                         self.running = startError == nil;
                                         if (startError) {
                                             self.stream = nil;
                                             [self report:
                                                       @"Could not start Greenlight window capture."
                                                    error:startError];
                                         } else {
                                             [self report:[@"Capturing "
                                                              stringByAppendingString:
                                                                  self.selectedWindowDescription]
                                                    error:nil];
                                         }
                                     }];
                                 }];
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sample
                   ofType:(SCStreamOutputType)type {
    if (!self.running || stream != self.stream || type != SCStreamOutputTypeScreen)
        return;
    if (!CMSampleBufferIsValid(sample)) {
        self.incompleteFrames++;
        return;
    }
    CFArrayRef metadata = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (metadata && CFArrayGetCount(metadata) > 0) {
        NSDictionary *attachments = (__bridge NSDictionary *)CFArrayGetValueAtIndex(metadata, 0);
        NSNumber *status = attachments[SCStreamFrameInfoStatus];
        if (status && status.integerValue != SCFrameStatusComplete &&
            status.integerValue != SCFrameStatusStarted) {
            self.idleFrames++;
            return;
        }
    }
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
    if (!pixelBuffer) {
        self.incompleteFrames++;
        return;
    }
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) !=
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        CVPixelBufferGetWidth(pixelBuffer) != self.expectedWidth ||
        CVPixelBufferGetHeight(pixelBuffer) != self.expectedHeight) {
        self.formatMismatches++;
        if (self.formatMismatches == 1)
            [self report:@"Capture pixel format/dimensions differ from NV12 1280×720. "
                         @"Check ScreenCaptureKit configuration."
                   error:nil];
        return;
    }
    const double arrival = CACurrentMediaTime();
    self.lastFrameArrival = arrival;
    self.deliveredFrames++;
    MCWindowFrameHandler handler = self.frameHandler;
    if (handler)
        handler(pixelBuffer, arrival);
    else
        self.rejectedFrames++;
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (stream != self.stream)
        return;
    self.running = NO;
    [self report:@"Remote-play capture stopped." error:error];
}

- (void)stop {
    self.selectionGeneration++;
    self.running = NO;
    SCStream *stream = self.stream;
    self.stream = nil;
    self.frameHandler = nil;
    if (stream) {
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            if (error)
                NSLog(@"MC_GREENLIGHT_CAPTURE stop error=%@", error);
        }];
    }
}
@end
