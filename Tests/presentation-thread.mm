#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#import "MetalCadence.h"

#include <cassert>
#include <cstdio>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device != nil);

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;

        MCDisplayScheduler *scheduler = [[MCDisplayScheduler alloc]
            initWithLayer:layer
                   device:device
                 capacity:8
              maxInFlight:2
                   encode:^(
                       id<MTLCommandBuffer> command, id<CAMetalDrawable> drawable, MCFrame *frame) {
                       // Exercise display-link lifetime with no real frames.
                       (void)command;
                       (void)drawable;
                       (void)frame;
                   }];

        scheduler.useDedicatedRenderThread = YES;
        for (int i = 0; i < 4; i++) {
            [scheduler startWithRefreshRate:i % 2 ? 120 : 165];
            [NSThread sleepForTimeInterval:.12];
            NSDictionary *metrics = [scheduler metrics];
            assert([metrics[@"dedicatedRenderThread"] boolValue]);
            [scheduler stop];
        }

        scheduler.useDedicatedRenderThread = NO;
        [scheduler startWithRefreshRate:60];
        [NSThread sleepForTimeInterval:.10];
        [scheduler stop];
        std::puts("Presentation thread: repeated dedicated/main lifecycle passed");
    }
    return 0;
}
