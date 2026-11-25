#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "internal/MCProductionShaderSource.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>

static uint8_t ConvertSample(id<MTLDevice> device,
                             id<MTLLibrary> library,
                             int fullRange,
                             int matrix,
                             uint8_t y,
                             uint8_t u,
                             uint8_t v) {
    NSError *error = nil;
    id<MTLFunction> function = [library newFunctionWithName:@"convert"];
    assert(function != nil);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function
                                                                                 error:&error];
    assert(pipeline != nil);

    MTLTextureDescriptor *yDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:4
                                                          height:4
                                                       mipmapped:NO];
    yDescriptor.storageMode = MTLStorageModeShared;
    yDescriptor.usage = MTLTextureUsageShaderRead;
    MTLTextureDescriptor *uvDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
                                                           width:2
                                                          height:2
                                                       mipmapped:NO];
    uvDescriptor.storageMode = MTLStorageModeShared;
    uvDescriptor.usage = MTLTextureUsageShaderRead;
    MTLTextureDescriptor *rgbDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:4
                                                          height:4
                                                       mipmapped:NO];
    rgbDescriptor.storageMode = MTLStorageModeShared;
    rgbDescriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;

    id<MTLTexture> yTexture = [device newTextureWithDescriptor:yDescriptor];
    id<MTLTexture> uvTexture = [device newTextureWithDescriptor:uvDescriptor];
    id<MTLTexture> rgbTexture = [device newTextureWithDescriptor:rgbDescriptor];
    assert(yTexture != nil && uvTexture != nil && rgbTexture != nil);

    uint8_t luma[16];
    std::fill(std::begin(luma), std::end(luma), y);
    uint8_t chroma[8] = {u, v, u, v, u, v, u, v};
    [yTexture replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:luma bytesPerRow:4];
    [uvTexture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                 mipmapLevel:0
                   withBytes:chroma
                 bytesPerRow:4];

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:yTexture atIndex:0];
    [encoder setTexture:uvTexture atIndex:1];
    [encoder setTexture:rgbTexture atIndex:2];
    [encoder setBytes:&fullRange length:sizeof(fullRange) atIndex:0];
    [encoder setBytes:&matrix length:sizeof(matrix) atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(4, 4, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
    [encoder endEncoding];
    [command commit];
    // This deterministic test may wait; the production SDK never does.
    [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted);

    uint8_t pixels[64] = {};
    [rgbTexture getBytes:pixels
             bytesPerRow:16
              fromRegion:MTLRegionMake2D(0, 0, 4, 4)
             mipmapLevel:0];
    assert(pixels[3] == 255);
    return pixels[0];
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device != nil);

        NSError *error = nil;
        NSString *shader = [NSString stringWithUTF8String:kMCProductionMetalSource];
        id<MTLLibrary> source = [device newLibraryWithSource:shader options:nil error:&error];
        assert(source != nil);

        NSURL *url = [NSURL fileURLWithPath:@"/tmp/MetalCadenceShaders/MetalCadence.metallib"];
        id<MTLLibrary> precompiled = [device newLibraryWithURL:url error:&error];
        assert(precompiled != nil);

        const uint8_t native = ConvertSample(device, source, 0, 0, 128, 128, 128);
        const uint8_t offline = ConvertSample(device, precompiled, 0, 0, 128, 128, 128);
        assert(std::abs((int)native - (int)offline) <= 1);
        assert(std::abs((int)native - 130) <= 2);

        const uint8_t full = ConvertSample(device, precompiled, 1, 0, 128, 128, 128);
        assert(std::abs((int)full - 128) <= 2);

        for (int matrix = 0; matrix <= 2; ++matrix) {
            const uint8_t generated = ConvertSample(device, source, 0, matrix, 128, 96, 160);
            const uint8_t compiled = ConvertSample(device, precompiled, 0, matrix, 128, 96, 160);
            assert(std::abs((int)generated - (int)compiled) <= 1);
        }

        std::puts("Shader color: bundled and source BT.601/709/2020 pipelines agree");
    }
    return 0;
}
