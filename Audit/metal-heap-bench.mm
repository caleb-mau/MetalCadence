#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cstdio>
#include <numeric>
#include <vector>

static double Percentile(std::vector<double> values, double fraction) {
    std::sort(values.begin(), values.end());
    if (values.empty()) {
        return 0;
    }
    return values[static_cast<std::size_t>((values.size() - 1) * fraction)];
}

static void RunSize(id<MTLDevice> device, NSUInteger width, NSUInteger height, NSUInteger count) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

    MTLSizeAndAlign layout = [device heapTextureSizeAndAlignWithDescriptor:descriptor];
    std::vector<double> directTimes;
    std::vector<id<MTLTexture>> direct;
    direct.reserve(count);

    for (NSUInteger index = 0; index < count; ++index) {
        double started = CACurrentMediaTime();
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        directTimes.push_back((CACurrentMediaTime() - started) * 1000);
        if (!texture) {
            break;
        }
        direct.push_back(texture);
    }

    MTLHeapDescriptor *heapDescriptor = [MTLHeapDescriptor new];
    heapDescriptor.storageMode = MTLStorageModePrivate;
    heapDescriptor.size = ((layout.size + layout.align - 1) / layout.align) * layout.align * count;
    heapDescriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;

    double heapStart = CACurrentMediaTime();
    id<MTLHeap> heap = [device newHeapWithDescriptor:heapDescriptor];
    double heapCreateMs = (CACurrentMediaTime() - heapStart) * 1000;
    std::vector<double> heapTimes;
    std::vector<id<MTLTexture>> heapTextures;
    heapTextures.reserve(count);

    if (heap) {
        for (NSUInteger index = 0; index < count; ++index) {
            double started = CACurrentMediaTime();
            id<MTLTexture> texture = [heap newTextureWithDescriptor:descriptor];
            heapTimes.push_back((CACurrentMediaTime() - started) * 1000);
            if (!texture) {
                break;
            }
            heapTextures.push_back(texture);
        }
    }

    printf("HEAP_EXPERIMENT size=%lux%lu requested=%lu direct=%zu heap=%zu "
           "directAllocP50=%.4fms directAllocP95=%.4fms "
           "heapCreate=%.4fms heapAllocP50=%.4fms heapAllocP95=%.4fms "
           "heapReserveMiB=%.1f heapUsedMiB=%.1f\n",
           (unsigned long)width,
           (unsigned long)height,
           (unsigned long)count,
           direct.size(),
           heapTextures.size(),
           Percentile(directTimes, .5),
           Percentile(directTimes, .95),
           heapCreateMs,
           Percentile(heapTimes, .5),
           Percentile(heapTimes, .95),
           heapDescriptor.size / 1048576.0,
           heap ? heap.usedSize / 1048576.0 : 0);
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fputs("Metal device unavailable\n", stderr);
            return 1;
        }

        for (NSUInteger count : {8u, 16u, 24u, 32u}) {
            @autoreleasepool {
                RunSize(device, 1920, 1080, count);
            }
            @autoreleasepool {
                RunSize(device, 2560, 1440, count);
            }
        }
    }
    return 0;
}
