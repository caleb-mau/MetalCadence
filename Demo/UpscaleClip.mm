#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>

static const int InputWidth = 1280, InputHeight = 720;
static const int OutputWidth = 2560, OutputHeight = 1440;

static void LogFailure(NSString *stage, NSError *error) {
    fprintf(stderr,
            "MetalCadence Upscale: %s%s%s\n",
            stage.UTF8String,
            error ? ": " : "",
            error ? error.localizedDescription.UTF8String : "");
}

static BOOL ConvertAndUpscale(CVPixelBufferRef input,
                              CVPixelBufferRef output,
                              id<MTLDevice> device,
                              id<MTLCommandQueue> queue,
                              CVMetalTextureCacheRef cache,
                              id<MTLComputePipelineState> convert,
                              id<MTLComputePipelineState> exportColor,
                              id<MTLFXSpatialScaler> scaler,
                              id<MTLTexture> nativeTexture,
                              id<MTLTexture> upscaledTexture,
                              double *gpuMilliseconds) {
    CVMetalTextureRef y = NULL, uv = NULL, bgra = NULL;
    BOOL success = NO;
    if (CVMetalTextureCacheCreateTextureFromImage(
            NULL, cache, input, NULL, MTLPixelFormatR8Unorm, InputWidth, InputHeight, 0, &y) !=
            kCVReturnSuccess ||
        CVMetalTextureCacheCreateTextureFromImage(NULL,
                                                  cache,
                                                  input,
                                                  NULL,
                                                  MTLPixelFormatRG8Unorm,
                                                  InputWidth / 2,
                                                  InputHeight / 2,
                                                  1,
                                                  &uv) != kCVReturnSuccess ||
        CVMetalTextureCacheCreateTextureFromImage(NULL,
                                                  cache,
                                                  output,
                                                  NULL,
                                                  MTLPixelFormatBGRA8Unorm,
                                                  OutputWidth,
                                                  OutputHeight,
                                                  0,
                                                  &bgra) != kCVReturnSuccess)
        goto cleanup;
    {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (!command)
            goto cleanup;
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:convert];
        [encoder setTexture:CVMetalTextureGetTexture(y) atIndex:0];
        [encoder setTexture:CVMetalTextureGetTexture(uv) atIndex:1];
        [encoder setTexture:nativeTexture atIndex:2];
        int fullRange =
            CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ? 1
                : 0;
        int matrix = 0;
        CFTypeRef colorMatrix = CVBufferGetAttachment(input, kCVImageBufferYCbCrMatrixKey, NULL);
        if (colorMatrix && CFEqual(colorMatrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4))
            matrix = 1;
        else if (colorMatrix && CFEqual(colorMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020))
            matrix = 2;
        [encoder setBytes:&fullRange length:sizeof(fullRange) atIndex:0];
        [encoder setBytes:&matrix length:sizeof(matrix) atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(InputWidth, InputHeight, 1)
            threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        [encoder endEncoding];

        scaler.colorTexture = nativeTexture;
        scaler.outputTexture = upscaledTexture;
        scaler.inputContentWidth = InputWidth;
        scaler.inputContentHeight = InputHeight;
        [scaler encodeToCommandBuffer:command];

        id<MTLComputeCommandEncoder> exportEncoder = [command computeCommandEncoder];
        [exportEncoder setComputePipelineState:exportColor];
        [exportEncoder setTexture:upscaledTexture atIndex:0];
        [exportEncoder setTexture:CVMetalTextureGetTexture(bgra) atIndex:1];
        [exportEncoder dispatchThreads:MTLSizeMake(OutputWidth, OutputHeight, 1)
                 threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        [exportEncoder endEncoding];

        CFTimeInterval started = CACurrentMediaTime();
        [command commit];
        [command waitUntilCompleted];
        *gpuMilliseconds += (CACurrentMediaTime() - started) * 1000.0;
        success = command.status == MTLCommandBufferStatusCompleted;
        if (!success)
            NSLog(@"MetalFX upscale command failed: %@", command.error);
    }
cleanup:
    if (y)
        CFRelease(y);
    if (uv)
        CFRelease(uv);
    if (bgra)
        CFRelease(bgra);
    return success;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr,
                    "Usage: upscale-clip <720p-input.mp4> <1440p-output.mp4> <MetalFX.metallib>\n");
            return 2;
        }
        NSError *error = nil;
        NSURL *source = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *destination = [NSURL fileURLWithPath:@(argv[2])];
        NSURL *shaders = [NSURL fileURLWithPath:@(argv[3])];
        AVAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        CGSize size = track.naturalSize;
#pragma clang diagnostic pop
        if (!track || round(size.width) != InputWidth || round(size.height) != InputHeight) {
            fprintf(stderr,
                    "Expected a genuine 1280x720 video track, got %.0fx%.0f\n",
                    size.width,
                    size.height);
            return 3;
        }

        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
        if (!reader) {
            LogFailure(@"reader", error);
            return 4;
        }
        NSDictionary *readSettings = @{
            (id)
            kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (id)kCVPixelBufferMetalCompatibilityKey : @YES
        };
        AVAssetReaderTrackOutput *readOutput =
            [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                       outputSettings:readSettings];
        readOutput.alwaysCopiesSampleData = NO;
        [reader addOutput:readOutput];
        [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:destination
                                                         fileType:AVFileTypeMPEG4
                                                            error:&error];
        if (!writer) {
            LogFailure(@"writer", error);
            return 5;
        }
        AVAssetWriterInput *input = [AVAssetWriterInput
            assetWriterInputWithMediaType:AVMediaTypeVideo
                           outputSettings:@{
                               AVVideoCodecKey : AVVideoCodecTypeH264,
                               AVVideoWidthKey : @(OutputWidth),
                               AVVideoHeightKey : @(OutputHeight),
                               AVVideoCompressionPropertiesKey : @{
                                   AVVideoAverageBitRateKey : @10000000,
                                   AVVideoExpectedSourceFrameRateKey : @30,
                                   AVVideoProfileLevelKey : AVVideoProfileLevelH264HighAutoLevel
                               }
                           }];
        input.expectsMediaDataInRealTime = NO;
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                       sourcePixelBufferAttributes:@{
                                           (id)kCVPixelBufferPixelFormatTypeKey :
                                               @(kCVPixelFormatType_32BGRA),
                                           (id)kCVPixelBufferWidthKey : @(OutputWidth),
                                           (id)kCVPixelBufferHeightKey : @(OutputHeight),
                                           (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                                           (id)kCVPixelBufferMetalCompatibilityKey : @YES
                                       }];
        [writer addInput:input];

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLLibrary> library = [device newLibraryWithURL:shaders error:&error];
        if (!library) {
            LogFailure(@"shader library", error);
            return 6;
        }
        id<MTLComputePipelineState> convert =
            [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"convert"]
                                                  error:&error];
        id<MTLComputePipelineState> exportColor =
            [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"exportRGBA"]
                                                  error:&error];
        if (!convert || !exportColor) {
            LogFailure(@"compute pipelines", error);
            return 7;
        }

        MTLFXSpatialScalerDescriptor *descriptor = [MTLFXSpatialScalerDescriptor new];
        descriptor.inputWidth = InputWidth;
        descriptor.inputHeight = InputHeight;
        descriptor.outputWidth = OutputWidth;
        descriptor.outputHeight = OutputHeight;
        descriptor.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        id<MTLFXSpatialScaler> scaler = [descriptor newSpatialScalerWithDevice:device];
        if (!scaler) {
            LogFailure(@"MetalFX spatial scaler unavailable", nil);
            return 8;
        }

        MTLTextureDescriptor *native =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:InputWidth
                                                              height:InputHeight
                                                           mipmapped:NO];
        native.storageMode = MTLStorageModePrivate;
        native.usage =
            MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | scaler.colorTextureUsage;
        MTLTextureDescriptor *scaled =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:OutputWidth
                                                              height:OutputHeight
                                                           mipmapped:NO];
        scaled.storageMode = MTLStorageModePrivate;
        scaled.usage =
            MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | scaler.outputTextureUsage;
        id<MTLTexture> nativeTexture = [device newTextureWithDescriptor:native];
        id<MTLTexture> upscaledTexture = [device newTextureWithDescriptor:scaled];
        CVMetalTextureCacheRef cache = NULL;
        if (CVMetalTextureCacheCreate(NULL, NULL, device, NULL, &cache) != kCVReturnSuccess)
            return 9;

        if (![reader startReading] || ![writer startWriting]) {
            LogFailure(@"start reader/writer", reader.error ?: writer.error);
            return 10;
        }

        CMSampleBufferRef sample = NULL;
        NSUInteger count = 0;
        double gpuMs = 0;
        CMTime firstPTS = kCMTimeInvalid;
        BOOL failed = NO;
        while ((sample = [readOutput copyNextSampleBuffer])) {
            @autoreleasepool {
                if (!CMTIME_IS_VALID(firstPTS)) {
                    firstPTS = CMSampleBufferGetPresentationTimeStamp(sample);
                    [writer startSessionAtSourceTime:kCMTimeZero];
                }
                CVPixelBufferRef inputFrame = CMSampleBufferGetImageBuffer(sample);
                CVPixelBufferRef target = NULL;
                if (!inputFrame ||
                    CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &target) !=
                        kCVReturnSuccess) {
                    LogFailure(@"output pixel buffer pool", nil);
                    failed = YES;
                } else {
                    failed = !ConvertAndUpscale(inputFrame,
                                                target,
                                                device,
                                                queue,
                                                cache,
                                                convert,
                                                exportColor,
                                                scaler,
                                                nativeTexture,
                                                upscaledTexture,
                                                &gpuMs);
                    CMTime pts =
                        CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), firstPTS);
                    if (!failed) {
                        while (!input.readyForMoreMediaData &&
                               writer.status == AVAssetWriterStatusWriting)
                            [NSThread sleepForTimeInterval:.002];
                        if (![adaptor appendPixelBuffer:target withPresentationTime:pts]) {
                            LogFailure(@"append video frame", writer.error);
                            failed = YES;
                        }
                    }
                    CVPixelBufferRelease(target);
                }
                if (!failed)
                    ++count;
                CFRelease(sample);
            }
            if (failed)
                break;
        }
        if (reader.status == AVAssetReaderStatusFailed) {
            LogFailure(@"read video", reader.error);
            failed = YES;
        }
        if (failed || count == 0) {
            [writer cancelWriting];
            if (cache)
                CFRelease(cache);
            return 11;
        }
        [input markAsFinished];
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(finished);
        }];
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        if (cache)
            CFRelease(cache);
        if (writer.status != AVAssetWriterStatusCompleted) {
            LogFailure(@"finish export", writer.error);
            return 12;
        }
        printf("MetalFX export successful: %lu frames, %dx%d -> %dx%d, %.2f ms/frame GPU wall "
               "sync, output=%s\n",
               (unsigned long)count,
               InputWidth,
               InputHeight,
               OutputWidth,
               OutputHeight,
               gpuMs / MAX(1, count),
               destination.path.UTF8String);
        return 0;
    }
}
