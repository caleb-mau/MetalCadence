#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <arm_neon.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
static CVPixelBufferRef create(void) {
    CVPixelBufferRef b = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    CVPixelBufferCreate(NULL,
                        1920,
                        1080,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)attrs,
                        &b);
    return b;
}
static void fill(CVPixelBufferRef b, int seed) {
    CVPixelBufferLockBaseAddress(b, 0);
    for (int p = 0; p < 2; p++) {
        uint8_t *data = CVPixelBufferGetBaseAddressOfPlane(b, p);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(b, p),
               width = CVPixelBufferGetWidthOfPlane(b, p) * (p ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(b, p);
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
                data[y * stride + x] = p ? 128 + (seed & 15) : 16 + ((x * 3 + y * 7 + seed) % 210);
    }
    CVPixelBufferUnlockBaseAddress(b, 0);
}
static void copy(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, 0);
    for (int p = 0; p < 2; p++) {
        uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(b, p);
        uint8_t *src = CVPixelBufferGetBaseAddressOfPlane(a, p);
        size_t ds = CVPixelBufferGetBytesPerRowOfPlane(b, p),
               ss = CVPixelBufferGetBytesPerRowOfPlane(a, p),
               width = CVPixelBufferGetWidthOfPlane(b, p) * (p ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(b, p);
        for (int y = 0; y < height; y++)
            memcpy(dst + y * ds, src + y * ss, width);
    }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, 0);
}
static BOOL equal(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    BOOL eq = YES;
    for (int p = 0; p < 2 && eq; p++) {
        uint8_t *aa = CVPixelBufferGetBaseAddressOfPlane(a, p),
                *bb = CVPixelBufferGetBaseAddressOfPlane(b, p);
        size_t as = CVPixelBufferGetBytesPerRowOfPlane(a, p),
               bs = CVPixelBufferGetBytesPerRowOfPlane(b, p),
               width = CVPixelBufferGetWidthOfPlane(a, p) * (p ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(a, p);
        for (int y = 0; y < height; y++)
            if (memcmp(aa + y * as, bb + y * bs, width)) {
                eq = NO;
                break;
            }
    }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    return eq;
}
static uint64_t fnv(CVPixelBufferRef b) {
    uint64_t h = 1469598103934665603ull;
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    for (int p = 0; p < 2; p++) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(b, p);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(b, p),
               width = CVPixelBufferGetWidthOfPlane(b, p) * (p ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(b, p);
        for (size_t y = 0; y < height; y += 16)
            for (size_t x = 0; x < width; x += 17) {
                h ^= base[y * stride + x];
                h *= 1099511628211ull;
            }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    return h;
}
static uint64_t neon(CVPixelBufferRef b) {
    uint8x16_t accum = vdupq_n_u8(0);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    for (int p = 0; p < 2; p++) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(b, p);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(b, p),
               width = CVPixelBufferGetWidthOfPlane(b, p) * (p ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(b, p);
        for (size_t y = 0; y < height; y += 16)
            for (size_t x = 0; x + 16 <= width; x += 128) {
                uint8x16_t a = vld1q_u8(base + y * stride + x);
                accum = veorq_u8(accum, vaddq_u8(a, vdupq_n_u8((uint8_t)(x / 128 + y / 16 + p))));
            }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    uint8_t bytes[16];
    vst1q_u8(bytes, accum);
    uint64_t h = 1469598103934665603ull;
    for (int i = 0; i < 16; i++) {
        h ^= bytes[i];
        h *= 1099511628211ull;
    }
    return h;
}
static double percentile(double *d, int n, double q) {
    double *a = malloc(n * sizeof(double));
    memcpy(a, d, n * sizeof(double));
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
            if (a[j] < a[i]) {
                double t = a[i];
                a[i] = a[j];
                a[j] = t;
            }
    double result = a[(int)((n - 1) * q)];
    free(a);
    return result;
}
static NSString *const shader =
    @"#include <metal_stdlib>\nusing namespace metal;\nkernel void "
    @"fingerprint(texture2d<float,access::read> y[[texture(0)]],texture2d<float,access::read> "
    @"uv[[texture(1)]],device atomic_uint *out[[buffer(0)]],uint2 "
    @"g[[thread_position_in_grid]]){uint2 "
    @"p=g*uint2(16,16);if(p.x>=y.get_width()||p.y>=y.get_height())return;uint "
    @"lumin=(uint)round(y.read(p).r*255.);uint2 chp=p/2;float2 ch=uv.read(chp).rg;uint "
    @"chroma=(uint)round(ch.x*255.)+((uint)round(ch.y*255.)<<8);uint "
    @"v=(lumin+chroma*31+g.x*131+g.y*7919)*2654435761u;atomic_fetch_xor_explicit(out,v,memory_"
    @"order_relaxed);}";
int main() {
    @autoreleasepool {
        CVPixelBufferRef a = create(), same = create(), delta = create(), different = create();
        fill(a, 2);
        copy(a, same);
        copy(a, delta);
        fill(different, 73);
        CVPixelBufferLockBaseAddress(delta, 0);
        uint8_t *p = CVPixelBufferGetBaseAddressOfPlane(delta, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(delta, 0);
        p[1 * stride + 1] ^= 3;
        CVPixelBufferUnlockBaseAddress(delta, 0);
        assert(equal(a, same));
        assert(!equal(a, delta));
        assert(!equal(a, different));
        assert(fnv(a) == fnv(same));
        assert(neon(a) == neon(same));
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *e = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:shader options:nil error:&e];
        assert(lib);
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fingerprint"]
                                                  error:&e];
        assert(pipeline);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        CVMetalTextureCacheRef cache = NULL;
        CVMetalTextureCacheCreate(NULL, NULL, device, NULL, &cache);
        const int n = 120;
        double fnvMs[n], neonMs[n], exactMs[n], gpuMs[n], gpuComputeMs[n];
        int errors[3] = {0};
        CVPixelBufferRef pairs[] = {same, delta, different};
        for (int i = 0; i < n; i++) {
            @autoreleasepool {
                CVPixelBufferRef b = pairs[i % 3];
                BOOL expected = equal(a, b);
                double start = CACurrentMediaTime();
                uint64_t ha = fnv(a), hb = fnv(b);
                BOOL result = ha == hb && equal(a, b);
                fnvMs[i] = (CACurrentMediaTime() - start) * 1000;
                if (result != expected)
                    errors[0]++;
                start = CACurrentMediaTime();
                ha = neon(a);
                hb = neon(b);
                result = ha == hb && equal(a, b);
                neonMs[i] = (CACurrentMediaTime() - start) * 1000;
                if (result != expected)
                    errors[1]++;
                start = CACurrentMediaTime();
                result = equal(a, b);
                exactMs[i] = (CACurrentMediaTime() - start) * 1000;
                start = CACurrentMediaTime();
                uint32_t gpuHash[2] = {0};
                double compute = 0;
                for (int j = 0; j < 2; j++) {
                    CVPixelBufferRef src = j ? b : a;
                    CVMetalTextureRef y = NULL, uv = NULL;
                    CVMetalTextureCacheCreateTextureFromImage(
                        NULL, cache, src, NULL, MTLPixelFormatR8Unorm, 1920, 1080, 0, &y);
                    CVMetalTextureCacheCreateTextureFromImage(
                        NULL, cache, src, NULL, MTLPixelFormatRG8Unorm, 960, 540, 1, &uv);
                    id<MTLBuffer> buf = [device newBufferWithLength:sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
                    *(uint32_t *)buf.contents = 0;
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                    [enc setComputePipelineState:pipeline];
                    [enc setTexture:CVMetalTextureGetTexture(y) atIndex:0];
                    [enc setTexture:CVMetalTextureGetTexture(uv) atIndex:1];
                    [enc setBuffer:buf offset:0 atIndex:0];
                    [enc dispatchThreads:MTLSizeMake(120, 68, 1)
                        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                    [enc endEncoding];
                    [cb commit];
                    [cb waitUntilCompleted];
                    compute += MAX(0, cb.GPUEndTime - cb.GPUStartTime) * 1000;
                    gpuHash[j] = *(uint32_t *)buf.contents;
                    if (y)
                        CFRelease(y);
                    if (uv)
                        CFRelease(uv);
                }
                result = gpuHash[0] == gpuHash[1] && equal(a, b);
                gpuMs[i] = (CACurrentMediaTime() - start) * 1000;
                gpuComputeMs[i] = compute;
                if (result != expected)
                    errors[2]++;
            }
        }
        printf("HASHBENCH samples=%d FNV_p50=%.3fms FNV_p95=%.3fms NEON_p50=%.3fms NEON_p95=%.3fms "
               "EXACT_p50=%.3fms EXACT_p95=%.3fms GPU_roundtrip_p50=%.3fms "
               "GPU_roundtrip_p95=%.3fms GPU_exec_p50=%.3fms errors=%d,%d,%d\n",
               n,
               percentile(fnvMs, n, .5),
               percentile(fnvMs, n, .95),
               percentile(neonMs, n, .5),
               percentile(neonMs, n, .95),
               percentile(exactMs, n, .5),
               percentile(exactMs, n, .95),
               percentile(gpuMs, n, .5),
               percentile(gpuMs, n, .95),
               percentile(gpuComputeMs, n, .5),
               errors[0],
               errors[1],
               errors[2]);
        CVPixelBufferRelease(a);
        CVPixelBufferRelease(same);
        CVPixelBufferRelease(delta);
        CVPixelBufferRelease(different);
        CFRelease(cache);
        return errors[0] || errors[1] || errors[2] ? 1 : 0;
    }
}
