#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "internal/MCTexturePool.hpp"

#include <cassert>
#include <cstdio>
#include <memory>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device != nil);

        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:1280
                                                              height:720
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

        MTLSizeAndAlign sizing = [device heapTextureSizeAndAlignWithDescriptor:descriptor];
        assert(sizing.size > 0);
        auto budget = std::make_shared<metalcadence::TextureBudget>(sizing.size * 2);

        {
            metalcadence::TexturePool pool(device, descriptor, budget, 1);
            id<MTLTexture> first = pool.acquire();
            id<MTLTexture> second = pool.acquire();
            assert(first != nil && second != nil && first != second);
            assert(pool.acquire() == nil);
            assert(pool.allocations() == 2 && pool.denied() == 1);

            pool.release(first);
            pool.release(first); // Duplicate returns must never double-account.
            assert(pool.cachedCount() == 1);

            id<MTLTexture> reused = pool.acquire();
            assert(reused == first && pool.reuses() == 1);
            pool.release(second);
            pool.release(reused);
            assert(pool.cachedCount() == 1);
            assert(pool.evictions() == 1);
            assert(budget->activeBytes == 0);
            assert(budget->cachedBytes == sizing.size);
        }

        assert(budget->activeBytes == 0);
        assert(budget->cachedBytes == 0);
        std::puts("C++20 GPU pool: budget denial, reuse, duplicate return, eviction and "
                  "destruction passed");
    }
    return 0;
}
