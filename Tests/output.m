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
        uint8_t *pixels = CVPixelBufferGetBaseAddressOfPlane(frame, plane);
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

static void TestOutputFrameCount(NSInteger multiplier) {
    MCVideoConfiguration *configuration = [MCVideoConfiguration new];
    configuration.inputWidth = 1280;
    configuration.inputHeight = 720;
    configuration.outputWidth = 1920;
    configuration.outputHeight = 1080;
    configuration.multiplier = multiplier;
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

    NSInteger expected = multiplier == 1 ? inputCount : inputCount - 1;

    if (processed != expected) {
        NSLog(@"Output source=%ldx expected=%ld processed=%ld scheduled=%ld metrics=%@",
              (long)multiplier,
              (long)expected,
              (long)processed,
              (long)scheduled,
              metrics);
    }
    assert(processed == expected);
    if (scheduled != processed * multiplier) {
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
    assert(scheduled == processed * multiplier);
    assert([metrics[@"outputFrameAttempts"] integerValue] == scheduled);
    assert([metrics[@"rejectedOutputFrames"] integerValue] == 0);
    assert([metrics[@"incompleteGeneratedBatches"] integerValue] == 0);
    assert([metrics[@"destinationPoolFailures"] integerValue] == 0);
    assert([metrics[@"scaleFailures"] integerValue] == 0);
    assert([metrics[@"interpolationErrors"] integerValue] == 0);
    assert([metrics[@"gpuErrors"] integerValue] == 0);
    assert(native == (multiplier == 1 ? processed : 0));

    printf("OUTPUT-INTEGRITY %ldx source=%d processed=%ld scheduled=%ld "
           "incomplete=0 rejected=0\n",
           (long)multiplier,
           inputCount,
           (long)processed,
           (long)scheduled);
    [engine stop];
}

int main(void) {
    @autoreleasepool {
        if (@available(macOS 26.0, *)) {
            TestOutputFrameCount(1);
            TestOutputFrameCount(2);
        } else {
            puts("Output test requires macOS 26 or later");
            return 2;
        }
    }
    return 0;
}
