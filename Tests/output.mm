#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#import "MetalCadence.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static CVPixelBufferRef MakeNV12Frame(int value) {
    CVPixelBufferRef frame = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES
    };

    CVReturn status = CVPixelBufferCreate(NULL,
                                          1280,
                                          720,
                                          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          (__bridge CFDictionaryRef)attributes,
                                          &frame);
    assert(status == kCVReturnSuccess);

    CVPixelBufferLockBaseAddress(frame, 0);
    for (int plane = 0; plane < 2; plane++) {
        uint8_t *pixels = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(frame, plane);
        size_t height = CVPixelBufferGetHeightOfPlane(frame, plane);
        size_t width = CVPixelBufferGetWidthOfPlane(frame, plane) * (plane ? 2 : 1);

        for (size_t y = 0; y < height; y++) {
            memset(pixels + y * stride, plane ? 128 : value, width);
        }
    }
    CVPixelBufferUnlockBaseAddress(frame, 0);
    return frame;
}

static void
TestOutputFrameCount(NSInteger multiplier,
                     NSUInteger slots,
                     bool nativeResolution = false,
                     MCInterpolationBackend backend = MCInterpolationBackendVideoToolbox,
                     bool gameplayImmediate = false) {
    MCVideoConfiguration *configuration = [MCVideoConfiguration new];
    configuration.inputWidth = 1280;
    configuration.inputHeight = 720;
    configuration.outputWidth = nativeResolution ? 1280 : 1920;
    configuration.outputHeight = nativeResolution ? 720 : 1080;
    configuration.interpolationBackend = backend;
    configuration.multiplier = multiplier;
    configuration.gameplayImmediate = gameplayImmediate;
    configuration.maxConcurrentGPUBatches = slots;
    configuration.audioEnabled = NO;
    configuration.presentation = MCVideoPresentationCompare;

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    assert(layer.device != nil);

    NSError *error = nil;
    MCVideoEngine *engine = [[MCVideoEngine alloc] initWithConfiguration:configuration
                                                                   layer:layer
                                                                   error:&error];
    assert(engine != nil);
    assert([engine startWithRefreshRate:120 error:&error]);

    double origin = CACurrentMediaTime();
    const int inputCount = 14;
    for (int index = 0; index < inputCount; index++) {
        CVPixelBufferRef frame = MakeNV12Frame(25 + index * 6);
        assert([engine submitVideo:frame hostTime:origin + index / 30.0]);
        CVPixelBufferRelease(frame);
        [NSThread sleepForTimeInterval:1.0 / 30.0];
    }

    NSDictionary *metrics = nil;
    for (int attempt = 0; attempt < 250; attempt++) {
        metrics = [engine metrics];
        if ([metrics[@"processed"] integerValue] >= inputCount - 1) {
            break;
        }
        [NSThread sleepForTimeInterval:.010];
    }

    NSInteger processed = [metrics[@"processed"] integerValue];
    NSInteger scheduled = [metrics[@"scheduledFrames"] integerValue];
    NSInteger native = [metrics[@"nativeOutputBatches"] integerValue];

    NSInteger expected = (multiplier == 1 || gameplayImmediate) ? inputCount : inputCount - 1;

    if (processed != expected) {
        NSLog(@"Output source=%ldx expected=%ld processed=%ld scheduled=%ld metrics=%@",
              (long)multiplier,
              (long)expected,
              (long)processed,
              (long)scheduled,
              metrics);
    }
    assert([metrics[@"gameplayImmediate"] boolValue] == gameplayImmediate);
    assert(processed == expected);
    if (scheduled != processed * (gameplayImmediate ? 1 : multiplier)) {
        NSLog(@"Output count mismatch: multiplier=%ld processed=%ld scheduled=%ld "
               "incomplete=%@ rejected=%@ native=%@ pool=%@ scale=%@ vt=%@ gpu=%@",
              (long)multiplier,
              (long)processed,
              (long)scheduled,
              metrics[@"incompleteGeneratedBatches"],
              metrics[@"rejectedOutputFrames"],
              metrics[@"nativeOutputBatches"],
              metrics[@"destinationPoolFailures"],
              metrics[@"scaleFailures"],
              metrics[@"interpolationErrors"],
              metrics[@"gpuErrors"]);
    }
    assert(scheduled == processed * (gameplayImmediate ? 1 : multiplier));
    assert([metrics[@"outputFrameAttempts"] integerValue] == scheduled);
    assert([metrics[@"rejectedOutputFrames"] integerValue] == 0);
    assert([metrics[@"incompleteGeneratedBatches"] integerValue] == 0);
    assert([metrics[@"destinationPoolFailures"] integerValue] == 0);
    assert([metrics[@"scaleFailures"] integerValue] == 0);
    assert([metrics[@"interpolationErrors"] integerValue] == 0);
    assert([metrics[@"gpuErrors"] integerValue] == 0);
    assert(native == (multiplier == 1 || gameplayImmediate ? processed : 0));
    assert([metrics[@"nativeResolutionBypass"] boolValue] == nativeResolution);
    if (nativeResolution)
        assert([metrics[@"nativeTextureAllocations"] integerValue] == 0);

    printf("OUTPUT-INTEGRITY %ldx slots=%lu source=%d processed=%ld scheduled=%ld "
           "incomplete=0 rejected=0\n",
           (long)multiplier,
           (unsigned long)slots,
           inputCount,
           (long)processed,
           (long)scheduled);
    [engine stop];
}

static CVPixelBufferRef MakeTeleportFrame(bool right) {
    CVPixelBufferRef frame = MakeNV12Frame(32);
    CVPixelBufferLockBaseAddress(frame, 0);
    uint8_t *plane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, 0);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
    const int x = right ? 870 : 214;
    for (int row = 254; row < 446; row++)
        memset(plane + row * stride + x, 208, 192);
    CVPixelBufferUnlockBaseAddress(frame, 0);
    return frame;
}
static void TestAbruptGuard(bool nativeResolution, NSInteger multiplier = 2) {
    MCVideoConfiguration *c = [MCVideoConfiguration new];
    c.inputWidth = 1280;
    c.inputHeight = 720;
    c.outputWidth = nativeResolution ? 1280 : 1920;
    c.outputHeight = nativeResolution ? 720 : 1080;
    c.multiplier = multiplier;
    c.interpolationBackend =
        multiplier == 4 ? MCInterpolationBackendLinearBlend : MCInterpolationBackendVideoToolbox;
    c.suppressAbruptInterpolation = YES;
    c.duplicateDetection = NO;
    c.audioEnabled = NO;
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    NSError *error = nil;
    MCVideoEngine *engine = [[MCVideoEngine alloc] initWithConfiguration:c
                                                                   layer:layer
                                                                   error:&error];
    assert(engine != nil);
    assert([engine startWithRefreshRate:60 error:&error]);
    double origin = CACurrentMediaTime();
    const int inputCount = 12;
    for (int index = 0; index < inputCount; index++) {
        CVPixelBufferRef frame = MakeTeleportFrame((index % 2) != 0);
        assert([engine submitVideo:frame hostTime:origin + index / 30.]);
        CVPixelBufferRelease(frame);
        [NSThread sleepForTimeInterval:1. / 30];
    }
    NSDictionary *m = nil;
    for (int attempt = 0; attempt < 250; attempt++) {
        m = [engine metrics];
        if ([m[@"processed"] intValue] >= inputCount - 1)
            break;
        [NSThread sleepForTimeInterval:.01];
    }
    assert([m[@"processed"] intValue] == inputCount - 1);
    assert([m[@"scheduledFrames"] intValue] == multiplier * (inputCount - 1));
    assert([m[@"abruptHoldBatches"] intValue] == inputCount - 1);
    assert([m[@"interpolationErrors"] intValue] == 0);
    assert([m[@"gpuErrors"] intValue] == 0);
    assert([m[@"textureBudgetDenied"] intValue] == 0);
    [engine stop];
    printf("ABRUPT-GUARD native=%d factor=%ld pairs=%d held=%d errors=0\n",
           nativeResolution,
           (long)multiplier,
           inputCount - 1,
           inputCount - 1);
}

int main(void) {
    @autoreleasepool {
        if (@available(macOS 26.0, *)) {
            TestOutputFrameCount(1, 1);
            TestOutputFrameCount(2, 2);
            TestOutputFrameCount(2, 3);
            TestOutputFrameCount(1, 1, true);
            TestOutputFrameCount(2, 2, true);
            TestOutputFrameCount(2, 2, true, MCInterpolationBackendLinearBlend);
            TestOutputFrameCount(2, 2, true, MCInterpolationBackendVideoToolbox, true);
            TestOutputFrameCount(2, 2, false, MCInterpolationBackendVideoToolbox, true);
            MCVideoConfiguration *invalidGamingAudio = [MCVideoConfiguration new];
            invalidGamingAudio.gameplayImmediate = YES;
            invalidGamingAudio.audioEnabled = YES;
            assert([[MCVideoEngine alloc] initWithConfiguration:invalidGamingAudio
                                                          layer:[CAMetalLayer layer]
                                                          error:nil] == nil);
            TestAbruptGuard(false);
            TestAbruptGuard(true);
            TestAbruptGuard(true, 4);
        } else {
            puts("Output test requires macOS 26 or later");
            return 2;
        }
    }
    return 0;
}
