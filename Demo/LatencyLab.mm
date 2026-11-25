#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "MetalCadence.h"
#import "MCWindowCapture.h"
#import "MCLocalClipSource.h"
#include <cmath>

static const int LabWidth = 1280;
static const int LabHeight = 720;

@class MCLatencyLab;
@interface MCLabWindow : NSWindow
@property (weak) MCLatencyLab *lab;
@end

@interface MCLabInputEvent : NSObject
@property NSUInteger index;
@property double pressedTime, sourcePTS, leftResponse, rightResponse;

@property double leftSourceToPresentation, rightSourceToPresentation;
@property BOOL written;
@end
@implementation MCLabInputEvent
@end

@interface MCLatencyLab : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property MCLabWindow *window;
@property NSView *leftSurface, *rightSurface;
@property CAMetalLayer *leftLayer, *rightLayer;
@property MCVideoEngine *leftEngine, *rightEngine;
@property NSTextField *heading, *subtitle, *leftTitle, *rightTitle, *leftNumbers, *rightNumbers;
@property NSTextField *status, *instructions, *footnote;
@property NSPopUpButton *quality, *buffer, *resolution;
@property NSButton *triggerButton, *guardSwitch, *sourceButton, *clipButton;
@property NSTimer *sourceTimer, *metricsTimer;
@property MCWindowCapture *windowCapture;
@property MCLocalClipSource *clipSource;
@property NSString *clipStatus;
@property (atomic) BOOL clipMode;
@property BOOL clipTest;
@property (atomic) BOOL captureMode;
@property NSString *captureStatus;
@property CVPixelBufferPoolRef sourcePool;
@property NSMutableArray<MCLabInputEvent *> *events;
@property NSString *logPath;
@property NSUInteger inputIndex, sourceFrames, tickCount;
@property BOOL flipped, selfTest;
@property double lastLeftTime, lastRightTime;
@property NSUInteger previousLeftFrames, previousRightFrames;
@property double lastReportAt, leftFPS, rightFPS, startedAt;

@property NSUInteger occludedReportSamples;
@property float refreshRate;
- (void)triggerAction;
- (void)resizeContent;
@end

@implementation MCLabWindow
- (void)keyDown:(NSEvent *)event {
    if (self.lab.selfTest)
        return;
    if (event.keyCode == 49 || event.keyCode == 123 || event.keyCode == 124 ||
        event.keyCode == 125 || event.keyCode == 126) {
        [self.lab triggerAction];
        return;
    }
    [super keyDown:event];
}
@end

static NSTextField *LabLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *v = [NSTextField labelWithString:text];
    v.font = [NSFont systemFontOfSize:size weight:weight];
    v.textColor = color;
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    return v;
}

static void LabAttach(NSView *surface, CAMetalLayer *layer, CGFloat scale) {
    layer.frame = surface.bounds;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(MAX(1, surface.bounds.size.width * scale),
                                    MAX(1, surface.bounds.size.height * scale));
}

static void LabFill(CVPixelBufferRef frame, NSUInteger tick, BOOL flipped) {
    CVPixelBufferLockBaseAddress(frame, 0);
    uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, 0);
    uint8_t *uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, 1);
    const size_t ys = CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
    const size_t us = CVPixelBufferGetBytesPerRowOfPlane(frame, 1);
    for (int row = 0; row < LabHeight; row++) {
        uint8_t *line = y + row * ys;
        memset(line, (row % 80 < 2) ? 51 : 32, LabWidth);
        for (int x = 0; x < LabWidth; x += 80)
            line[x] = 57;
    }
    for (int row = 0; row < LabHeight / 2; row++)
        memset(uv + row * us, 128, LabWidth);

    // Thin sweeping cursor makes temporal interpolation easy to judge.
    int sweepingX = (int)((tick * 26) % (LabWidth + 100)) - 50;
    for (int row = 75; row < LabHeight - 75; row++) {
        uint8_t *line = y + row * ys;
        for (int x = MAX(0, sweepingX); x < MIN(LabWidth, sweepingX + 13); x++)
            line[x] = 214;
    }

    // Hard jump on an input event. Both engines receive precisely this same frame.
    const int centerX = flipped ? 970 : 310;
    const int centerY = 350;
    const int radius = 96;
    for (int row = centerY - radius; row < centerY + radius; row++) {
        memset(y + row * ys + centerX - radius, 208, radius * 2);
    }
    // Chrominance of the target changes with each input event, increasing visibility.
    for (int row = (centerY - radius) / 2; row < (centerY + radius) / 2; row++) {
        uint8_t *line = uv + row * us;
        for (int x = (centerX - radius) / 2; x < (centerX + radius) / 2; x++) {
            line[x * 2] = flipped ? 92 : 210;
            line[x * 2 + 1] = flipped ? 240 : 65;
        }
    }
    CVPixelBufferUnlockBaseAddress(frame, 0);
}

@implementation MCLatencyLab
- (void)writeEvent:(MCLabInputEvent *)event {
    if (event.written || event.leftResponse <= 0 || event.rightResponse <= 0)
        return;
    event.written = YES;
    NSDictionary *entry = @{
        @"event" : @(event.index),
        @"referenceInputToPresentationMs" : @(event.leftResponse),
        @"enhancedInputToPresentationMs" : @(event.rightResponse),
        @"extraGeneratedDelayMs" : @(event.rightResponse - event.leftResponse),
        @"inputToSourceMs" : @((event.sourcePTS - event.pressedTime) * 1000),
        @"leftSourceToPresentationMs" : @(event.leftSourceToPresentation),
        @"rightSourceToPresentationMs" : @(event.rightSourceToPresentation),
        @"enhancedMultiplier" : @(self.quality.indexOfSelectedItem == 1 ? 4 : 2),
        @"bufferMode" : self.buffer.titleOfSelectedItem ?: @"unknown",
        @"displayHz" : @(self.refreshRate)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    if (f) {
        [f seekToEndOfFile];
        [f writeData:data];
        [f writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [f closeFile];
    }
    NSLog(@"MC_LATENCY_EVENT %@", entry);
}
- (void)didPresentSource:(double)sourcePTS time:(double)actual isEnhanced:(BOOL)enhanced {
    // This callback comes from a Metal completion queue, not AppKit.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (MCLabInputEvent *event in self.events) {
            if (event.sourcePTS <= 0 || sourcePTS + .000001 < event.sourcePTS)
                continue;
            if ((enhanced ? event.rightResponse : event.leftResponse) > 0)
                continue;
            double latency = MAX(0, actual - event.pressedTime) * 1000;
            if (enhanced) {
                event.rightResponse = latency;
                event.rightSourceToPresentation = MAX(0, actual - event.sourcePTS) * 1000;
                self.lastRightTime = latency;
            } else {
                event.leftResponse = latency;
                event.leftSourceToPresentation = MAX(0, actual - event.sourcePTS) * 1000;
                self.lastLeftTime = latency;
            }
            [self writeEvent:event];
        }
    });
}
- (MCVideoConfiguration *)configurationForEnhanced:(BOOL)enhanced {
    MCVideoConfiguration *c = [MCVideoConfiguration new];
    c.inputWidth = LabWidth;
    c.inputHeight = LabHeight;
    // Only the enhanced path is spatially upscaled. The left side is always
    // a genuine 1280x720 reference, even when MetalFX outputs 2560x1440.
    NSInteger size = self.resolution.indexOfSelectedItem;
    c.outputWidth = enhanced ? (size == 2 ? 2560 : size == 1 ? 1920 : LabWidth) : LabWidth;
    c.outputHeight = enhanced ? (size == 2 ? 1440 : size == 1 ? 1080 : LabHeight) : LabHeight;
    c.audioEnabled = NO;
    c.duplicateDetection = self.captureMode;
    c.suppressAbruptInterpolation = enhanced && self.guardSwitch.state == NSControlStateValueOn;
    c.presentation = MCVideoPresentationEnhanced;
    c.maxConcurrentGPUBatches = 2;
    c.gpuTextureBudgetMiB = enhanced && size == 2 ? 512 : 256;
    c.multiplier = enhanced ? (self.quality.indexOfSelectedItem == 1 ? 4 : 2) : 1;
    c.skipRedundantPresentations = NO;
    c.adaptiveMultiplier = enhanced && c.multiplier == 4;
    if (!enhanced) {
        // Deliberately bypass unnecessary buffering on the reference path.
        c.playoutDelay = 0;
        c.minimumDelay = 0;
        c.maximumDelay = 0;
        c.adaptiveLatency = NO;
        return c;
    }

    switch (self.buffer.indexOfSelectedItem) {
    case 1: // Fast adaptive, accepts more occasional frame skips.
        c.playoutDelay = .030;
        c.minimumDelay = .006;
        c.maximumDelay = .090;
        c.preferFreshestFrame = NO;
        break;
    case 2: // Fixed low buffer for experimental comparisons.
        c.playoutDelay = c.minimumDelay = c.maximumDelay = .055;
        c.adaptiveLatency = NO;
        break;
    case 3:
        c.playoutDelay = c.minimumDelay = c.maximumDelay = .085;
        c.adaptiveLatency = NO;
        break;
    case 4:
        c.playoutDelay = c.minimumDelay = c.maximumDelay = .125;
        c.adaptiveLatency = NO;
        break;
    default:
        c.playoutDelay = .045;
        c.minimumDelay = .012;
        c.maximumDelay = .125;
        c.adaptiveLatency = YES;
        break;
    }
    return c;
}
- (BOOL)startEngine:(BOOL)enhanced {
    CAMetalLayer *layer = enhanced ? self.rightLayer : self.leftLayer;
    NSError *error = nil;
    MCVideoConfiguration *c = [self configurationForEnhanced:enhanced];
    MCVideoEngine *engine = [[MCVideoEngine alloc] initWithConfiguration:c
                                                                   layer:layer
                                                                   error:&error];
    if (!engine || ![engine startWithRefreshRate:self.refreshRate error:&error]) {
        self.status.stringValue = [NSString
            stringWithFormat:@"Engine failed: %@", error.localizedDescription ?: @"unknown"];
        NSLog(@"MC_LATENCY_ENGINE_ERROR %@", error);
        return NO;
    }
    __weak MCLatencyLab *weakSelf = self;
    engine.onFreshFramePresented = ^(double source, double presented, int64_t frameID) {
        (void)frameID;
        [weakSelf didPresentSource:source time:presented isEnhanced:enhanced];
    };
    if (enhanced)
        self.rightEngine = engine;
    else
        self.leftEngine = engine;
    return YES;
}
- (void)reconfigure:(id)sender {
    [self.rightEngine stop];
    self.rightEngine.onFreshFramePresented = nil;
    self.rightEngine = nil;
    self.lastRightTime = 0;
    self.previousRightFrames = 0;
    for (MCLabInputEvent *event in self.events)
        event.rightResponse = 0;
    [self startEngine:YES];
}
- (void)sourceTick:(NSTimer *)timer {
    (void)timer;
    if (self.captureMode || self.clipMode)
        return;
    if (!self.leftEngine.running || !self.rightEngine.running)
        return;
    CVPixelBufferRef frame = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, self.sourcePool, &frame) != kCVReturnSuccess)
        return;
    const double samplePTS = CACurrentMediaTime();
    for (MCLabInputEvent *event in self.events) {
        if (!event.sourcePTS)
            event.sourcePTS = samplePTS;
    }
    LabFill(frame, self.tickCount++, self.flipped);
    [self.leftEngine submitVideo:frame hostTime:samplePTS];
    [self.rightEngine submitVideo:frame hostTime:samplePTS];
    self.sourceFrames++;
    CVPixelBufferRelease(frame);
}
- (void)triggerAction {
    MCLabInputEvent *event = [MCLabInputEvent new];
    event.index = ++self.inputIndex;
    event.pressedTime = CACurrentMediaTime();
    [self.events addObject:event];
    if (self.events.count > 50)
        [self.events removeObjectAtIndex:0];
    self.flipped = !self.flipped;
}
- (void)restartForCaptureMode {
    [self.leftEngine stop];
    [self.rightEngine stop];
    self.leftEngine.onFreshFramePresented = nil;
    self.rightEngine.onFreshFramePresented = nil;
    self.leftEngine = nil;
    self.rightEngine = nil;
    self.previousLeftFrames = 0;
    self.previousRightFrames = 0;
    self.lastReportAt = 0;
    [self startEngine:NO];
    [self startEngine:YES];
}
- (NSURL *)selectedClipURL {
    NSString *path = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Movies/MetalCadence Upscale Tests/source-720p.mp4"];
    for (NSString *arg in NSProcessInfo.processInfo.arguments) {
        if ([arg hasPrefix:@"--clip-path="])
            path = [arg substringFromIndex:12];
    }
    return [NSURL fileURLWithPath:path];
}
- (void)toggleClip:(id)sender {
    (void)sender;
    if (self.clipMode) {
        self.clipMode = NO;
        [self.clipSource stop];
        self.clipStatus = @"Synthetic source";
        self.clipButton.title = @"Play 720p video";
        [self restartForCaptureMode];
        return;
    }
    if (self.captureMode) {
        self.captureMode = NO;
        [self.windowCapture stop];
        self.sourceButton.title = @"Connect Greenlight";
    }
    NSURL *url = [self selectedClipURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        if (self.clipTest) {
            self.status.stringValue =
                [NSString stringWithFormat:@"Test video missing: %@", url.path];
            return;
        }
        NSOpenPanel *picker = [NSOpenPanel openPanel];
        picker.allowedContentTypes = @[ [UTType typeWithFilenameExtension:@"mp4"] ];
        picker.allowsMultipleSelection = NO;
        picker.message = @"Choose a 1280 × 720, 30 FPS video to upscale live.";
        if ([picker runModal] != NSModalResponseOK)
            return;
        url = picker.URL;
    }
    if (self.resolution.indexOfSelectedItem == 0)
        [self.resolution selectItemAtIndex:2];
    self.clipMode = YES;
    self.clipStatus = @"Decoding local 720p video…";
    self.clipButton.title = @"Use synthetic";
    [self restartForCaptureMode];
    __weak MCLatencyLab *weakSelf = self;
    [self.clipSource startURL:url
        onFrame:^(CVPixelBufferRef buffer, double arrival) {
            MCLatencyLab *lab = weakSelf;
            if (!lab || !lab.clipMode)
                return;
            BOOL source = [lab.leftEngine submitVideo:buffer hostTime:arrival];
            BOOL enhanced = [lab.rightEngine submitVideo:buffer hostTime:arrival];
            if (source || enhanced)
                lab.sourceFrames++;
        }
        onStatus:^(NSString *message, NSError *error) {
            MCLatencyLab *lab = weakSelf;
            if (!lab)
                return;
            lab.clipStatus =
                error ? [NSString stringWithFormat:@"%@: %@", message, error.localizedDescription]
                      : message;
        }];
}
- (void)toggleGreenlight:(id)sender {
    (void)sender;
    if (self.clipMode) {
        self.clipMode = NO;
        [self.clipSource stop];
        self.clipButton.title = @"Play 720p video";
    }
    if (self.captureMode) {
        self.captureMode = NO;
        [self.windowCapture stop];
        self.captureStatus = @"Synthetic source";
        self.clipSource = [MCLocalClipSource new];
        self.clipStatus = @"Synthetic source";
        self.clipTest = [NSProcessInfo.processInfo.arguments containsObject:@"--clip-test"];
        self.sourceButton.title = @"Connect Greenlight";
        [self restartForCaptureMode];
        return;
    }
    self.captureMode = YES;
    self.captureStatus = @"Connecting to Greenlight…";
    self.sourceButton.title = @"Use synthetic";
    [self restartForCaptureMode];
    NSString *bundleID = @"com.unknownskl.greenlight";
    NSString *windowTitle = @"";
    for (NSString *arg in NSProcessInfo.processInfo.arguments) {
        if ([arg hasPrefix:@"--window-bundle="])
            bundleID = [arg substringFromIndex:16];
        else if ([arg hasPrefix:@"--window-title="])
            windowTitle = [arg substringFromIndex:15];
    }
    __weak MCLatencyLab *weakSelf = self;
    [self.windowCapture startWithBundleIdentifier:bundleID
        titleContains:windowTitle
        frameWidth:LabWidth
        frameHeight:LabHeight
        onFrame:^(CVPixelBufferRef frame, double arrival) {
            MCLatencyLab *lab = weakSelf;
            if (!lab || !lab.captureMode)
                return;
            BOOL raw = [lab.leftEngine submitVideo:frame hostTime:arrival];
            BOOL generated = [lab.rightEngine submitVideo:frame hostTime:arrival];
            if (raw || generated)
                lab.sourceFrames++;
        }
        onStatus:^(NSString *message, NSError *error) {
            MCLatencyLab *lab = weakSelf;
            if (!lab || !lab.captureMode)
                return;
            lab.captureStatus =
                error ? [NSString stringWithFormat:@"%@: %@", message, error.localizedDescription]
                      : message;
        }];
}
- (void)triggerButtonPressed:(id)sender {
    (void)sender;
    if (!self.selfTest)
        [self triggerAction];
}
- (void)report:(NSTimer *)timer {
    (void)timer;
    if ((self.window.occlusionState & NSWindowOcclusionStateVisible) == 0)
        self.occludedReportSamples++;
    NSDictionary *left = [self.leftEngine metrics], *right = [self.rightEngine metrics];
    double now = CACurrentMediaTime();
    double elapsed = self.lastReportAt > 0 ? now - self.lastReportAt : 0;
    if (elapsed > .001) {
        NSUInteger leftTotal = [left[@"presented"] unsignedIntegerValue];
        NSUInteger rightTotal = [right[@"presented"] unsignedIntegerValue];
        self.leftFPS = (double)(leftTotal - MIN(leftTotal, self.previousLeftFrames)) / elapsed;
        self.rightFPS = (double)(rightTotal - MIN(rightTotal, self.previousRightFrames)) / elapsed;
        self.previousLeftFrames = leftTotal;
        self.previousRightFrames = rightTotal;
    }
    self.lastReportAt = now;

    if (self.clipMode) {
        self.instructions.stringValue =
            [NSString stringWithFormat:
                          @"Real-time 720p30 playback: %@ · %lu decoded · %lu loops · %lu rejects",
                          self.clipStatus ?: @"Initializing",
                          (unsigned long)self.clipSource.frames,
                          (unsigned long)self.clipSource.loops,
                          (unsigned long)self.clipSource.rejectedFrames];
    } else if (self.captureMode) {
        self.instructions.stringValue = [NSString
            stringWithFormat:@"Greenlight: %@ · %lu captured · %lu idle · %lu format mismatches. "
                             @"Control GTA V in Greenlight.",
                             self.captureStatus ?: @"Connecting",
                             (unsigned long)self.windowCapture.deliveredFrames,
                             (unsigned long)self.windowCapture.idleFrames,
                             (unsigned long)self.windowCapture.formatMismatches];
    } else {
        self.instructions.stringValue = @"SPACE / arrow keys = abrupt target movement. "
                                        @"The moving scanning bar reveals motion smoothness.";
    }
    self.leftNumbers.stringValue =
        [NSString stringWithFormat:@"%.1f fresh fps    •    source → present P50 %.0f ms"
                                   @"    •    buffer %.0f ms",
                                   self.leftFPS,
                                   [left[@"sourceToPresentP50Ms"] doubleValue],
                                   [left[@"playoutDelayMs"] doubleValue]];
    self.rightNumbers.stringValue =
        [NSString stringWithFormat:@"%.1f fresh fps · processing P95 %.1f ms · GPU %.1f ms "
                                   @"· memory %.0f MiB",
                                   self.rightFPS,
                                   [right[@"processingP95Ms"] doubleValue],
                                   [right[@"scaleGPUMedianMs"] doubleValue],
                                   [right[@"memoryMiB"] doubleValue]];
    NSString *reference =
        self.lastLeftTime > 0 ? [NSString stringWithFormat:@"%.0f", self.lastLeftTime] : @"—";
    NSString *enhanced =
        self.lastRightTime > 0 ? [NSString stringWithFormat:@"%.0f", self.lastRightTime] : @"—";
    NSString *difference =
        self.lastRightTime > 0 && self.lastLeftTime > 0
            ? [NSString stringWithFormat:@"%.0f", self.lastRightTime - self.lastLeftTime]
            : @"—";
    self.status.stringValue =
        self.clipMode || self.captureMode
            ? [NSString stringWithFormat:@"Live source: original %.1f FPS  |  enhanced %.1f FPS"
                                          "  |  MetalFX %@",
                                         self.leftFPS,
                                         self.rightFPS,
                                         self.resolution.titleOfSelectedItem]
            : [NSString stringWithFormat:@"Last input → displayed source frame:  ORIGINAL %@ ms    "
                                         @"|    GENERATED %@ ms"
                                         @"    |    EXTRA DELAY %@ ms",
                                         reference,
                                         enhanced,
                                         difference];

    self.leftTitle.stringValue = self.clipMode      ? @"REAL 720p VIDEO  •  ORIGINAL"
                                 : self.captureMode ? @"GREENLIGHT / ORIGINAL STREAM"
                                                    : @"30 FPS  •  ORIGINAL / DIRECT";
    NSString *resolution = @[ @"720p", @"1080p", @"1440p" ][self.resolution.indexOfSelectedItem];
    self.rightTitle.stringValue =
        [NSString stringWithFormat:@"%@ · %@ FPS  •  %@ / VIDEO TOOLBOX",
                                   resolution,
                                   self.quality.indexOfSelectedItem == 1 ? @"120" : @"60",
                                   self.resolution.indexOfSelectedItem > 0 ? @"MetalFX + framegen"
                                                                           : @"framegen"];
    self.footnote.stringValue = [NSString
        stringWithFormat:@"Software drawable-present only; excludes Xbox network/decode latency. "
                         @"Display %.0f Hz. "
                         @"Both engines share the identical 30 FPS source. %@",
                         self.refreshRate,
                         self.refreshRate < 120 && self.quality.indexOfSelectedItem == 1
                             ? @"120 FPS cannot be displayed on this screen."
                             : @"P50 is a rolling frame metric, not controller-to-photon."];
}
- (void)resizeContent {
    if (!self.window)
        return;
    const NSRect b = self.window.contentView.bounds;
    const CGFloat w = b.size.width, h = b.size.height;
    self.heading.frame = NSMakeRect(22, h - 52, w - 40, 34);
    self.subtitle.frame = NSMakeRect(24, h - 78, w - 45, 20);
    CGFloat half = (w - 52) * .5;
    self.leftTitle.frame = NSMakeRect(22, h - 125, half, 22);
    self.rightTitle.frame = NSMakeRect(30 + half, h - 125, half, 22);
    CGFloat surfaceY = 248;
    CGFloat surfaceHeight = MAX(270, h - surfaceY - 132);
    self.leftSurface.frame = NSMakeRect(20, surfaceY, half, surfaceHeight);
    self.rightSurface.frame = NSMakeRect(32 + half, surfaceY, half, surfaceHeight);
    CGFloat scale = self.window.screen.backingScaleFactor ?: 1;
    LabAttach(self.leftSurface, self.leftLayer, scale);
    LabAttach(self.rightSurface, self.rightLayer, scale);
    self.leftNumbers.frame = NSMakeRect(22, 204, half, 27);
    self.rightNumbers.frame = NSMakeRect(32 + half, 204, half, 27);
    self.status.frame = NSMakeRect(22, 169, w - 42, 26);
    self.instructions.frame = NSMakeRect(24, 140, w - 48, 20);
    self.quality.frame = NSMakeRect(24, 89, 190, 30);
    self.buffer.frame = NSMakeRect(227, 89, 205, 30);
    self.triggerButton.frame = NSMakeRect(447, 85, 180, 38);
    self.guardSwitch.frame = NSMakeRect(635, 87, 222, 35);
    self.resolution.frame = NSMakeRect(856, 87, 165, 35);
    self.sourceButton.frame = NSMakeRect(1025, 85, 180, 38);
    self.clipButton.frame = NSMakeRect(1025, 43, 175, 36);
    self.footnote.frame = NSMakeRect(24, 23, w - 315, 30);
}
- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    [self resizeContent];
}
- (void)windowDidChangeScreen:(NSNotification *)notification {
    (void)notification;
    float rate = MAX(30, self.window.screen.maximumFramesPerSecond ?: 60);
    if (rate != self.refreshRate) {
        self.refreshRate = rate;
        [self.leftEngine updateRefreshRate:rate];
        [self.rightEngine updateRefreshRate:rate];
    }
    [self resizeContent];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.events = [NSMutableArray array];
    self.windowCapture = [MCWindowCapture new];
    self.captureStatus = @"Synthetic source";
    self.refreshRate = MAX(30, NSScreen.mainScreen.maximumFramesPerSecond ?: 60);
    self.selfTest = [NSProcessInfo.processInfo.arguments containsObject:@"--self-test"];
    NSString *dir = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/MetalCadence"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *runID = NSUUID.UUID.UUIDString;
    for (NSString *arg in NSProcessInfo.processInfo.arguments) {
        if ([arg hasPrefix:@"--run-id="]) {
            NSString *candidate = [arg substringFromIndex:9];
            NSCharacterSet *allowed = [NSCharacterSet
                characterSetWithCharactersInString:
                    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
            if (candidate.length && candidate.length < 80 &&
                [candidate rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound)
                runID = candidate;
        }
    }
    self.logPath = [dir
        stringByAppendingPathComponent:[NSString stringWithFormat:@"latency-lab-%@.jsonl", runID]];
    [@"" writeToFile:self.logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"MC_LATENCY_LOG %@", self.logPath);

    self.window = [[MCLabWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1300, 795)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"MetalCadence · Interactive Latency Lab";
    if (self.selfTest) {
        self.window.level = NSFloatingWindowLevel;
        self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    }
    self.window.minSize = NSMakeSize(1230, 660);
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.delegate = self;
    self.window.lab = self;
    [self.window center];
    NSView *root = self.window.contentView;
    root.wantsLayer = YES;
    root.layer.backgroundColor = [NSColor colorWithRed:.065 green:.075 blue:.095 alpha:1].CGColor;

    self.heading = LabLabel(
        @"METALCADENCE  /  INTERACTIVE LATENCY LAB", 24, NSFontWeightSemibold, NSColor.whiteColor);
    self.subtitle =
        LabLabel(@"One 30 FPS controllable source. Left is minimally buffered. Right is actual "
                 @"VideoToolbox-generated output.",
                 13,
                 NSFontWeightRegular,
                 NSColor.secondaryLabelColor);
    self.leftTitle =
        LabLabel(@"30 FPS  •  ORIGINAL / DIRECT", 15, NSFontWeightSemibold, NSColor.whiteColor);
    self.rightTitle = LabLabel(
        @"60 FPS  •  GENERATED / VIDEO TOOLBOX", 15, NSFontWeightSemibold, NSColor.whiteColor);
    self.leftNumbers = LabLabel(
        @"Waiting for original frames...", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    self.rightNumbers = LabLabel(
        @"Waiting for generated frames...", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    self.status = LabLabel(@"Press SPACE or click SWAP to measure response.",
                           18,
                           NSFontWeightSemibold,
                           NSColor.whiteColor);
    self.instructions =
        LabLabel(@"SPACE / arrow keys = abrupt target movement. The moving scanning bar "
                 @"reveals motion smoothness.",
                 12,
                 NSFontWeightRegular,
                 NSColor.secondaryLabelColor);
    self.footnote = LabLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    for (NSView *view in @[
             self.heading,
             self.subtitle,
             self.leftTitle,
             self.rightTitle,
             self.leftNumbers,
             self.rightNumbers,
             self.status,
             self.instructions,
             self.footnote
         ])
        [root addSubview:view];

    self.leftSurface = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 350)];
    self.rightSurface = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 350)];
    self.leftLayer = [CAMetalLayer layer];
    self.rightLayer = [CAMetalLayer layer];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    for (CAMetalLayer *layer in @[ self.leftLayer, self.rightLayer ]) {
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.backgroundColor = NSColor.blackColor.CGColor;
        layer.cornerRadius = 9;
        layer.masksToBounds = YES;
        layer.maximumDrawableCount = 3;
    }
    self.leftSurface.layer = self.leftLayer;
    self.leftSurface.wantsLayer = YES;
    self.rightSurface.layer = self.rightLayer;
    self.rightSurface.wantsLayer = YES;
    [root addSubview:self.leftSurface];
    [root addSubview:self.rightSurface];

    self.quality = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.quality addItemsWithTitles:@[ @"2× · 60 generated FPS", @"4× · 120 generated FPS" ]];
    self.quality.target = self;
    self.quality.action = @selector(reconfigure:);
    [root addSubview:self.quality];
    self.buffer = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.buffer addItemsWithTitles:@[
        @"Adaptive (default)",
        @"Fast adaptive (lower buffer)",
        @"Fixed 55 ms (experimental)",
        @"Fixed 85 ms",
        @"Fixed 125 ms"
    ]];
    self.buffer.target = self;
    self.buffer.action = @selector(reconfigure:);
    [root addSubview:self.buffer];
    self.resolution = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.resolution
        addItemsWithTitles:@[ @"720p · no upscale", @"1080p · MetalFX", @"1440p · MetalFX" ]];
    self.resolution.target = self;
    self.resolution.action = @selector(reconfigure:);
    [root addSubview:self.resolution];

    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if ([argument isEqualToString:@"--right-mode=fast"])
            [self.buffer selectItemAtIndex:1];
        else if ([argument isEqualToString:@"--right-mode=fixed55"])
            [self.buffer selectItemAtIndex:2];
        else if ([argument isEqualToString:@"--right-mode=fixed85"])
            [self.buffer selectItemAtIndex:3];
        else if ([argument isEqualToString:@"--right-mode=fixed125"])
            [self.buffer selectItemAtIndex:4];
        else if ([argument isEqualToString:@"--factor=4"])
            [self.quality selectItemAtIndex:1];
        else if ([argument isEqualToString:@"--output=1080"])
            [self.resolution selectItemAtIndex:1];
        else if ([argument isEqualToString:@"--output=1440"])
            [self.resolution selectItemAtIndex:2];
    }
    self.triggerButton = [NSButton buttonWithTitle:@"SWAP TARGET  ·  SPACE"
                                            target:self
                                            action:@selector(triggerButtonPressed:)];
    self.triggerButton.bezelStyle = NSBezelStyleRounded;
    self.triggerButton.keyEquivalent = @" ";
    self.guardSwitch = [NSButton checkboxWithTitle:@"Protect abrupt jumps"
                                            target:self
                                            action:@selector(reconfigure:)];
    self.guardSwitch.state =
        [NSProcessInfo.processInfo.arguments containsObject:@"--no-scene-guard"]
            ? NSControlStateValueOff
            : NSControlStateValueOn;
    self.guardSwitch.enabled = !self.selfTest;
    [root addSubview:self.guardSwitch];
    self.triggerButton.enabled = !self.selfTest;
    self.buffer.enabled = !self.selfTest;
    self.quality.enabled = !self.selfTest;
    self.resolution.enabled = !self.selfTest;
    [root addSubview:self.triggerButton];
    self.sourceButton = [NSButton buttonWithTitle:@"Connect Greenlight"
                                           target:self
                                           action:@selector(toggleGreenlight:)];
    self.sourceButton.bezelStyle = NSBezelStyleRounded;
    self.sourceButton.enabled = !self.selfTest;
    [root addSubview:self.sourceButton];
    self.clipButton = [NSButton buttonWithTitle:@"Play 720p video"
                                         target:self
                                         action:@selector(toggleClip:)];
    self.clipButton.bezelStyle = NSBezelStyleRounded;
    self.clipButton.enabled = !self.selfTest && !self.clipTest;
    [root addSubview:self.clipButton];
    [self.window makeKeyAndOrderFront:nil];
    [self resizeContent];

    NSDictionary *attrs = @{
        (id)kCVPixelBufferWidthKey : @(LabWidth),
        (id)kCVPixelBufferHeightKey : @(LabHeight),
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES
    };
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_sourcePool) !=
        kCVReturnSuccess) {
        self.status.stringValue = @"Cannot create shared input pool";
        return;
    }
    if (![self startEngine:NO] || ![self startEngine:YES])
        return;
    self.startedAt = CACurrentMediaTime();
    self.sourceTimer = [NSTimer timerWithTimeInterval:1. / 30
                                               target:self
                                             selector:@selector(sourceTick:)
                                             userInfo:nil
                                              repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.sourceTimer forMode:NSRunLoopCommonModes];
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:.8
                                                         target:self
                                                       selector:@selector(report:)
                                                       userInfo:nil
                                                        repeats:YES];
    [NSApp activateIgnoringOtherApps:YES];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--source=greenlight"] &&
        !self.selfTest)
        [self toggleGreenlight:nil];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--source=clip"] && !self.selfTest)
        [self toggleClip:nil];
    if (self.clipTest) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
    }

    if (self.selfTest) {
        for (NSInteger index = 0; index < 6; ++index) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.6 + index * 1.6) * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    [self triggerAction];
                    if (index == 5) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                                       dispatch_get_main_queue(),
                                       ^{
                                           [NSApp terminate:nil];
                                       });
                    }
                });
        }
    }
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    NSDictionary *left = [self.leftEngine metrics];
    NSDictionary *right = [self.rightEngine metrics];
    NSDictionary *summary = @{
        @"kind" : @"summary",
        @"launchArguments" : NSProcessInfo.processInfo.arguments,
        @"rightMultiplier" : @(self.quality.indexOfSelectedItem == 1 ? 4 : 2),
        @"rightOutputWidth" : @(self.resolution.indexOfSelectedItem == 2   ? 2560
                                : self.resolution.indexOfSelectedItem == 1 ? 1920
                                                                           : 1280),
        @"rightOutputHeight" : @(self.resolution.indexOfSelectedItem == 2   ? 1440
                                 : self.resolution.indexOfSelectedItem == 1 ? 1080
                                                                            : 720),
        @"rightGPUMedianMs" : right[@"scaleGPUMedianMs"] ?: @0,
        @"rightMemoryMiB" : right[@"memoryMiB"] ?: @0,
        @"runtimeSeconds" : @(MAX(.001, CACurrentMediaTime() - self.startedAt)),
        @"windowOccluded" : @((self.window.occlusionState & NSWindowOcclusionStateVisible) == 0),
        @"occludedReportSamples" : @(self.occludedReportSamples),
        @"appActive" : @(NSApp.isActive),
        @"leftDisplayCallbacks" : left[@"callbacks"] ?: @0,
        @"rightDisplayCallbacks" : right[@"callbacks"] ?: @0,
        @"rightHeldRefreshes" : right[@"heldRefreshes"] ?: @0,
        @"inputEvents" : @(self.inputIndex),
        @"sourceMode" : self.clipMode ? @"clip"
        : self.captureMode            ? @"greenlight"
                                      : @"synthetic",
        @"clipFramesDecoded" : @(self.clipSource.frames),
        @"clipLoops" : @(self.clipSource.loops),
        @"clipRejectedFrames" : @(self.clipSource.rejectedFrames),
        @"windowCaptureSamples" : @(self.windowCapture.deliveredFrames),
        @"windowCaptureIdle" : @(self.windowCapture.idleFrames),
        @"windowCaptureFormatMismatches" : @(self.windowCapture.formatMismatches),
        @"windowCaptureFailures" : @(self.windowCapture.incompleteFrames),
        @"sourceFrames" : @(self.sourceFrames),
        @"displayHz" : @(self.refreshRate),
        @"bufferMode" : self.buffer.titleOfSelectedItem ?: @"unknown",
        @"leftPresented" : left[@"presented"] ?: @0,
        @"rightPresented" : right[@"presented"] ?: @0,
        @"leftSourceToPresentP50Ms" : left[@"sourceToPresentP50Ms"] ?: @0,
        @"rightSourceToPresentP50Ms" : right[@"sourceToPresentP50Ms"] ?: @0,
        @"leftSourceToPresentP99Ms" : left[@"sourceToPresentP99Ms"] ?: @0,
        @"rightSourceToPresentP99Ms" : right[@"sourceToPresentP99Ms"] ?: @0,
        @"rightGapP99Ms" : right[@"gapP99Ms"] ?: @0,
        @"rightSuperseded" : right[@"superseded"] ?: @0,
        @"rightOverflow" : right[@"overflow"] ?: @0,
        @"rightProcessingP95Ms" : right[@"processingP95Ms"] ?: @0,
        @"rightPlayoutDelayMs" : right[@"playoutDelayMs"] ?: @0,
        @"guardEnabled" : @(self.guardSwitch.state == NSControlStateValueOn),
        @"rightAbruptHolds" : right[@"abruptHoldBatches"] ?: @0,
        @"rightGPUErrorCount" : right[@"gpuErrors"] ?: @0,
        @"rightInterpolationErrors" : right[@"interpolationErrors"] ?: @0
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:summary options:0 error:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    if (file) {
        [file seekToEndOfFile];
        [file writeData:data];
        uint8_t newline = 10;
        [file writeData:[NSData dataWithBytes:&newline length:1]];
        [file closeFile];
    }
    [self.sourceTimer invalidate];
    [self.metricsTimer invalidate];
    self.captureMode = NO;
    [self.windowCapture stop];
    self.clipMode = NO;
    [self.clipSource stop];
    self.leftEngine.onFreshFramePresented = nil;
    self.rightEngine.onFreshFramePresented = nil;
    [self.leftEngine stop];
    [self.rightEngine stop];
    if (_sourcePool) {
        CVPixelBufferPoolRelease(_sourcePool);
        _sourcePool = NULL;
    }
    NSLog(
        @"MC_LATENCY_TEST_COMPLETE %@ (events=%lu)", self.logPath, (unsigned long)self.inputIndex);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        static MCLatencyLab *lab;
        lab = [MCLatencyLab new];
        application.delegate = lab;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
