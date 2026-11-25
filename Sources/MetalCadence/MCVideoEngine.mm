#import "MetalCadence.h"
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <mach/mach.h>
#import <sys/resource.h>
#import <IOKit/IOKitLib.h>
#import <math.h>
#include "internal/MCTexturePool.hpp"
#include "internal/MCFixedTimingWindow.hpp"
#include "internal/MCSceneDiscontinuity.hpp"
#include <memory>
#include <bitset>
#if defined(__aarch64__)
#import <arm_neon.h>
#endif
static NSError *MCError(NSString *message) {
    return [NSError errorWithDomain:@"MetalCadence"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
@implementation MCVideoConfiguration
- (instancetype)init {
    if ((self = [super init])) {
        _inputWidth = 1920;
        _inputHeight = 1080;
        _outputWidth = 2560;
        _outputHeight = 1440;
        _multiplier = 2;
        _gpuTextureBudgetMiB = 512;
        _maxCachedTexturesPerPool = 12;
        _preallocatedTexturesPerPool = 0;
        _maxConcurrentGPUBatches = 2;
        _interpolationBackend = MCInterpolationBackendVideoToolbox;
        _adaptiveMultiplier = NO;
        _duplicateFingerprintMethod = MCDuplicateFingerprintNEON;
        _adaptiveLatency = YES;
        _duplicateDetection = YES;
        _audioEnabled = YES;
        _suppressAbruptInterpolation = NO;
        _playoutDelay = .075;
        _minimumDelay = .012;
        _maximumDelay = .125;
        _presentation = MCVideoPresentationEnhanced;
        _preferFreshestFrame = NO;
        _dedicatedPresentationThread = NO;
        _lateLatchDelaySeconds = 0;
        _gameplayImmediate = NO;
        _skipRedundantPresentations = NO;
        _heldRefreshDrawEvery = 1;
        _presentationLatenessRefreshes = 1.5;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    MCVideoConfiguration *c = [MCVideoConfiguration new];
    c.inputWidth = _inputWidth;
    c.inputHeight = _inputHeight;
    c.outputWidth = _outputWidth;
    c.outputHeight = _outputHeight;
    c.multiplier = _multiplier;
    c.gpuTextureBudgetMiB = _gpuTextureBudgetMiB;
    c.maxCachedTexturesPerPool = _maxCachedTexturesPerPool;
    c.preallocatedTexturesPerPool = _preallocatedTexturesPerPool;
    c.maxConcurrentGPUBatches = _maxConcurrentGPUBatches;
    c.interpolationBackend = _interpolationBackend;
    c.adaptiveMultiplier = _adaptiveMultiplier;
    c.duplicateFingerprintMethod = _duplicateFingerprintMethod;
    c.adaptiveLatency = _adaptiveLatency;
    c.duplicateDetection = _duplicateDetection;
    c.audioEnabled = _audioEnabled;
    c.suppressAbruptInterpolation = _suppressAbruptInterpolation;
    c.playoutDelay = _playoutDelay;
    c.minimumDelay = _minimumDelay;
    c.maximumDelay = _maximumDelay;
    c.presentation = _presentation;
    c.preferFreshestFrame = _preferFreshestFrame;
    c.dedicatedPresentationThread = _dedicatedPresentationThread;
    c.lateLatchDelaySeconds = _lateLatchDelaySeconds;
    c.gameplayImmediate = _gameplayImmediate;
    c.skipRedundantPresentations = _skipRedundantPresentations;
    c.heldRefreshDrawEvery = _heldRefreshDrawEvery;
    c.presentationLatenessRefreshes = _presentationLatenessRefreshes;
    c.profile = [_profile copy];
    return c;
}
+ (instancetype)configurationWithProfile:(MCWorkloadProfile *)profile {
    MCWorkloadPlan *plan = [[MCWorkloadPlan alloc] initWithProfile:profile];
    MCVideoConfiguration *c = [self new];
    c.profile = [profile copy];
    c.preferFreshestFrame = profile.policy == MCFramePolicyLowestLatency;
    c.multiplier = plan.multiplier;
    c.adaptiveMultiplier = plan.multiplier == 4 && profile.policy == MCFramePolicyMaximumThroughput;
    c.minimumDelay = plan.minimumDelay;
    c.maximumDelay = plan.maximumDelay;
    c.playoutDelay = plan.initialDelay;
    c.adaptiveLatency = plan.adaptiveLatency;
    return c;
}
@end
@interface MCInputFrame : NSObject
@property CVPixelBufferRef buffer, original;
@property double pts, arrival;
@end
@implementation MCInputFrame
- (void)dealloc {
    if (_buffer)
        CVPixelBufferRelease(_buffer);
    if (_original)
        CVPixelBufferRelease(_original);
}
@end
@interface MCTexturePool : NSObject {
    std::unique_ptr<metalcadence::TexturePool> _storage;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                    descriptor:(MTLTextureDescriptor *)descriptor
                        budget:(std::shared_ptr<metalcadence::TextureBudget>)budget
                 cacheCapacity:(NSUInteger)cacheCapacity
                   preallocate:(NSUInteger)preallocate;
@property (nonatomic, readonly) long allocations;
@property (nonatomic, readonly) long reuses;
@property (nonatomic, readonly) long evictions;
@property (nonatomic, readonly) long denied;
@property (nonatomic, readonly) NSUInteger cachedCount;
@property (nonatomic, readonly) NSUInteger bytesPerTexture;
- (id<MTLTexture>)take;
- (void)put:(id<MTLTexture>)texture;
@end

@implementation MCTexturePool
- (instancetype)initWithDevice:(id<MTLDevice>)device
                    descriptor:(MTLTextureDescriptor *)descriptor
                        budget:(std::shared_ptr<metalcadence::TextureBudget>)budget
                 cacheCapacity:(NSUInteger)cacheCapacity
                   preallocate:(NSUInteger)preallocate {
    if ((self = [super init])) {
        _storage = std::make_unique<metalcadence::TexturePool>(
            device, descriptor, std::move(budget), cacheCapacity);
        _storage->prewarm(preallocate);
    }
    return self;
}
- (id<MTLTexture>)take {
    return _storage->acquire();
}
- (void)put:(id<MTLTexture>)texture {
    _storage->release(texture);
}
- (long)allocations {
    return static_cast<long>(_storage->allocations());
}
- (long)reuses {
    return static_cast<long>(_storage->reuses());
}
- (long)evictions {
    return static_cast<long>(_storage->evictions());
}
- (long)denied {
    return static_cast<long>(_storage->denied());
}
- (NSUInteger)cachedCount {
    return _storage->cachedCount();
}
- (NSUInteger)bytesPerTexture {
    return _storage->byteCost();
}
@end

@interface MCOutputBatch : NSObject
@property NSArray<id<MTLTexture>> *textures;
@property MCTexturePool *pool, *nativePool;
@property NSArray<id<MTLTexture>> *nativeTextures;
@end
static void MCRecycleUniqueTextures(NSArray<id<MTLTexture>> *textures, MCTexturePool *pool) {
    if (!pool)
        return;
    // A scene discontinuity may intentionally reuse a single texture in all
    // generated phases. Release each physical texture lease exactly once.
    for (NSUInteger i = 0; i < textures.count; i++) {
        id<MTLTexture> item = textures[i];
        BOOL seen = NO;
        for (NSUInteger j = 0; j < i; j++) {
            if (textures[j] == item) {
                seen = YES;
                break;
            }
        }
        if (!seen)
            [pool put:item];
    }
}
@implementation MCOutputBatch
- (void)dealloc {
    MCRecycleUniqueTextures(_textures, _pool);
    MCRecycleUniqueTextures(_nativeTextures, _nativePool);
}
@end
#include "internal/MCProductionShaderSource.hpp"
static NSString *MCShaderSource(void) {
    return [NSString stringWithUTF8String:kMCProductionMetalSource];
}

// Compiled pipeline resources are immutable and may be shared across engine
// instances using the same Metal device and layer format.
@interface MCPipelineBundle : NSObject
@property (nonatomic, strong) id<MTLComputePipelineState> convert;
@property (nonatomic, strong) id<MTLComputePipelineState> blend;
@property (nonatomic, strong) id<MTLRenderPipelineState> render;
@property (nonatomic) BOOL precompiled;
@end
@implementation MCPipelineBundle
@end

static MCPipelineBundle *MCProductionPipelines(id<MTLDevice> device,
                                               MTLPixelFormat format,
                                               NSError **error,
                                               BOOL *cacheHit) {
    static std::mutex mutex;
    static NSMutableDictionary<NSString *, MCPipelineBundle *> *cache;

    std::scoped_lock lock(mutex);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
    }

    NSString *key =
        [NSString stringWithFormat:@"%p:%lu", (__bridge void *)device, (unsigned long)format];
    MCPipelineBundle *cached = cache[key];
    if (cached) {
        if (cacheHit) {
            *cacheHit = YES;
        }
        return cached;
    }
    if (cacheHit) {
        *cacheHit = NO;
    }

    NSError *libraryError = nil;
    NSURL *libraryURL = [[NSBundle mainBundle] URLForResource:@"MetalCadence"
                                                withExtension:@"metallib"];
    id<MTLLibrary> library = nil;
    BOOL precompiled = NO;
    if (libraryURL) {
        library = [device newLibraryWithURL:libraryURL error:&libraryError];
        precompiled = library != nil;
    }
    if (!library) {
        library = [device newLibraryWithSource:MCShaderSource() options:nil error:&libraryError];
    }
    if (!library) {
        if (error) {
            *error = libraryError ?: MCError(@"Production shader library unavailable");
        }
        return nil;
    }

    MCPipelineBundle *result = [MCPipelineBundle new];
    result.precompiled = precompiled;
    result.convert =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"convert"]
                                              error:&libraryError];
    result.blend =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"blend"]
                                              error:&libraryError];

    MTLRenderPipelineDescriptor *renderDescriptor = [MTLRenderPipelineDescriptor new];
    renderDescriptor.vertexFunction = [library newFunctionWithName:@"vert"];
    renderDescriptor.fragmentFunction = [library newFunctionWithName:@"frag"];
    renderDescriptor.colorAttachments[0].pixelFormat = format;
    result.render = [device newRenderPipelineStateWithDescriptor:renderDescriptor
                                                           error:&libraryError];

    if (!result.convert || !result.blend || !result.render) {
        if (error) {
            *error = libraryError ?: MCError(@"Production Metal pipeline unavailable");
        }
        return nil;
    }

    cache[key] = result;
    return result;
}

@interface MCVideoEngine () {
    std::shared_ptr<metalcadence::TextureBudget> _textureBudget;
    std::bitset<4> _availableGPUSlots;
    metalcadence::FixedTimingWindow<> _hashSamples, _fgSamples, _pairSamples, _scaleSamples,
        _arrivalSamples, _normalizationSamples;
    metalcadence::FixedTimingWindow<120> _readySamples;
}
@property (nonatomic, readwrite, copy) MCVideoConfiguration *configuration;
@property (atomic, readwrite) BOOL running;
@property (atomic, readwrite) double currentPlayoutDelay;
@property CAMetalLayer *layer;
@property id<MTLDevice> device;
@property id<MTLCommandQueue> gpu;
@property id<MTLComputePipelineState> convert, blend;
@property id<MTLRenderPipelineState> render;
@property double pipelineInitMs;
@property BOOL pipelineCacheHit, precompiledShaderLibrary;
@property id<MTLFXSpatialScaler> scaler;
@property NSArray *scalers;
@property BOOL nativeResolution;

@property dispatch_group_t gpuGroup;
@property (atomic) NSInteger batchesInFlight, peakBatches;
@property MCInputFrame *lastUnique;
@property double refreshPeriod, deadlineSafety, readyPrediction;
@property double scaleGPUSum, scaleGPUIdleSum, previousScaleGPUEnd;
@property MCTexturePool *pool, *nativePool;
@property MCDisplayScheduler *scheduler;
@property VTFrameProcessor *processor, *fallbackProcessor;
@property MCFrameBudgetController *budgetController;
@property MCLatencyController *latencyController;
@property VTLowLatencyFrameInterpolationConfiguration *fallbackConfig;
@property CVPixelBufferPoolRef fallbackDestinations;
@property VTLowLatencyFrameInterpolationConfiguration *vtConfig;
@property CVMetalTextureCacheRef cache;
@property CVPixelBufferPoolRef destinations, inputNormalizePool;
@property NSLock *lock, *statisticsLock;
@property dispatch_queue_t worker, audioQueue, completionQueue;
@property NSMutableArray<MCInputFrame *> *pendingFrames;
@property MCInputFrame *previous;
@property BOOL draining, hasHash;
@property uint64_t lastHash;
@property double lastPTS, lastOutputPTS, nextAudioPTS, lastAudioSource;
@property int64_t outputID;
@property (atomic) long abruptHoldBatches;
@property (atomic) long outputFrameAttempts;
@property (atomic) long rejectedOutputFrames;
@property (atomic) long incompleteGeneratedBatches;
@property (atomic) long nativeOutputBatches;
@property (atomic) long destinationPoolFailures;
@property (atomic) long scaleFailures;
@property (atomic) long received, duplicates, ingressDrops, invalid, processed, interpolationErrors,
    gpuErrors, submitted, audioSubmitted, audioRendered, audioDropped, duplicateHashCollisions,
    fullRangeNormalized;
@property AVAudioEngine *audioEngine;
@property AVAudioPlayerNode *player;
@property double startTime;
@property (atomic) long audioPending, audioOutstanding;
@property double previousMetricsTime, previousMetricsCPU;
@property (atomic) double observedSourceInterval, nominalSourceInterval, lastBatchDuration;
@property (atomic) NSInteger activeMultiplier;

@property (atomic) double audioScheduleDriftMs;
@property (atomic) long audioDiscontinuities;
@property (atomic) long audioLateDrops;
@property (atomic) long audioTooFarDrops;
@property (atomic) long audioBackpressureDrops;
@property NSUInteger lastAudioFrameCount;
@end
@implementation MCVideoEngine
@synthesize configuration = _configuration;
@synthesize muted = _muted;
- (instancetype)initWithConfiguration:(MCVideoConfiguration *)configuration
                                layer:(CAMetalLayer *)layer
                                error:(NSError **)error {
    if (!(self = [super init]))
        return nil;
    MCVideoConfiguration *c = [configuration copy];
    if (c.inputWidth < 2 || c.inputHeight < 2 || c.inputWidth % 2 || c.inputHeight % 2 ||
        c.outputWidth < 2 || c.outputHeight < 2 ||
        !(c.multiplier == 1 || c.multiplier == 2 || c.multiplier == 4) ||
        !isfinite(c.minimumDelay) || !isfinite(c.maximumDelay) || !isfinite(c.playoutDelay) ||
        !isfinite(c.lateLatchDelaySeconds) || c.lateLatchDelaySeconds < 0 ||
        c.lateLatchDelaySeconds > .010 || c.minimumDelay < 0 || c.maximumDelay < c.minimumDelay ||
        c.gpuTextureBudgetMiB < 64 || c.gpuTextureBudgetMiB > 16384 ||
        c.maxCachedTexturesPerPool > 256 ||
        c.preallocatedTexturesPerPool > c.maxCachedTexturesPerPool ||
        c.maxConcurrentGPUBatches < 1 || c.maxConcurrentGPUBatches > 4 ||
        (c.gameplayImmediate && c.audioEnabled)) {
        if (error)
            *error = MCError(@"Invalid configuration");
        return nil;
    }
    _configuration = c;
    _layer = layer;
    _presentation = c.presentation;
    _currentPlayoutDelay = MAX(c.minimumDelay, MIN(c.maximumDelay, c.playoutDelay));
    _device = layer.device ?: MTLCreateSystemDefaultDevice();
    if (!_device) {
        if (error)
            *error = MCError(@"Metal device unavailable");
        return nil;
    }
    _layer.device = _device;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _gpu = [_device newCommandQueue];
    NSError *e = nil;
    double pipelineStarted = CACurrentMediaTime();
    BOOL cacheHit = NO;
    MCPipelineBundle *pipelines = MCProductionPipelines(_device, _layer.pixelFormat, &e, &cacheHit);
    if (!pipelines) {
        if (error) {
            *error = e ?: MCError(@"Production shaders unavailable");
        }
        return nil;
    }
    _convert = pipelines.convert;
    _blend = pipelines.blend;
    _render = pipelines.render;
    _pipelineInitMs = (CACurrentMediaTime() - pipelineStarted) * 1000;
    _pipelineCacheHit = cacheHit;
    _precompiledShaderLibrary = pipelines.precompiled;

    MTLFXSpatialScalerDescriptor *sd = [MTLFXSpatialScalerDescriptor new];
    sd.inputWidth = c.inputWidth;
    sd.inputHeight = c.inputHeight;
    sd.outputWidth = c.outputWidth;
    sd.outputHeight = c.outputHeight;
    sd.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
    sd.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
    sd.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    MTLTextureDescriptor *in =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:c.inputWidth
                                                          height:c.inputHeight
                                                       mipmapped:NO];
    in.storageMode = MTLStorageModePrivate;

    _nativeResolution = c.inputWidth == c.outputWidth && c.inputHeight == c.outputHeight;
    NSMutableArray<id<MTLFXSpatialScaler>> *scalers = [NSMutableArray new];
    in.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    for (NSUInteger slot = 0; slot < c.maxConcurrentGPUBatches; ++slot) {
        _availableGPUSlots.set(slot);
        if (_nativeResolution)
            continue;
        id<MTLFXSpatialScaler> scaler = [sd newSpatialScalerWithDevice:_device];
        if (!scaler) {
            if (error)
                *error = MCError(@"MetalFX scaler slot unavailable");
            return nil;
        }

        in.usage |= scaler.colorTextureUsage;
        [scalers addObject:scaler];
    }
    _scalers = [scalers copy];
    _scaler = _scalers.firstObject;
    _gpuGroup = dispatch_group_create();
    MTLTextureDescriptor *out =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:c.outputWidth
                                                          height:c.outputHeight
                                                       mipmapped:NO];
    out.storageMode = MTLStorageModePrivate;
    out.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (!_nativeResolution)
        out.usage |= _scaler.outputTextureUsage;
    _textureBudget = std::make_shared<metalcadence::TextureBudget>(
        static_cast<std::size_t>(c.gpuTextureBudgetMiB) * 1024 * 1024);
    _pool = [[MCTexturePool alloc] initWithDevice:_device
                                       descriptor:out
                                           budget:_textureBudget
                                    cacheCapacity:c.maxCachedTexturesPerPool
                                      preallocate:c.preallocatedTexturesPerPool];
    // Equal-size output aliases the native texture; only the output pool owns its lease.
    if (!_nativeResolution)
        _nativePool = [[MCTexturePool alloc] initWithDevice:_device
                                                 descriptor:in
                                                     budget:_textureBudget
                                              cacheCapacity:c.maxCachedTexturesPerPool
                                                preallocate:c.preallocatedTexturesPerPool];
    if (CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_cache) != kCVReturnSuccess) {
        if (error)
            *error = MCError(@"Metal texture cache unavailable");
        return nil;
    }
    NSDictionary *normAttrs = @{
        (id)kCVPixelBufferWidthKey : @(c.inputWidth),
        (id)kCVPixelBufferHeightKey : @(c.inputHeight),
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES
    };
    if (CVPixelBufferPoolCreate(
            NULL, NULL, (__bridge CFDictionaryRef)normAttrs, &_inputNormalizePool) !=
        kCVReturnSuccess) {
        if (error)
            *error = MCError(@"Full-range NV12 normalization pool unavailable");
        return nil;
    }
    _lock = [NSLock new];
    _pendingFrames = [NSMutableArray new];
    _statisticsLock = [NSLock new];
    _worker = dispatch_queue_create("metalcadence.sdk.video",
                                    dispatch_queue_attr_make_with_qos_class(
                                        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _completionQueue =
        dispatch_queue_create("metalcadence.sdk.completion",
                              dispatch_queue_attr_make_with_qos_class(
                                  DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _audioQueue = dispatch_queue_create("metalcadence.sdk.audio",
                                        dispatch_queue_attr_make_with_qos_class(
                                            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    __weak MCVideoEngine *weak = self;
    _scheduler = [[MCDisplayScheduler alloc]
        initWithLayer:layer
               device:_device
             capacity:12
          maxInFlight:2
               encode:^(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d, MCFrame *frame) {
                   MCVideoEngine *engine = weak;
                   if (!engine)
                       return;
                   NSArray *p = frame.payload;
                   MCOutputBatch *batch = p[0];
                   NSUInteger index = [p[1] unsignedIntegerValue];
                   int mode = (int)engine.presentation;
                   float aspect[2] = {(float)d.texture.width / MAX(1, d.texture.height),
                                      (float)c.outputWidth / c.outputHeight};
                   MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                   rp.colorAttachments[0].texture = d.texture;
                   rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                   rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                   id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                   [enc setRenderPipelineState:engine.render];
                   id<MTLTexture> original = batch.nativeTextures[0];
                   id<MTLTexture> enhanced = batch.textures[index];
                   if (mode == 3)
                       enhanced = batch.textures[0];
                   if (mode == 4)
                       enhanced = batch.nativeTextures[index];
                   [enc setFragmentTexture:original atIndex:0];
                   [enc setFragmentTexture:enhanced atIndex:1];
                   [enc setFragmentBytes:&mode length:sizeof(mode) atIndex:0];
                   [enc setFragmentBytes:aspect length:sizeof(aspect) atIndex:1];
                   [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                   [enc endEncoding];
               }];
    _scheduler.onFreshFramePresented =
        ^(CFTimeInterval sourceTime, CFTimeInterval presentedTime, int64_t frameID) {
            MCVideoEngine *engine = weak;
            MCFramePresentedBlock callback = engine.onFreshFramePresented;
            if (callback)
                callback(sourceTime, presentedTime, frameID);
        };
    _scheduler.useDedicatedRenderThread = c.dedicatedPresentationThread;
    _scheduler.lateLatchDelaySeconds = c.lateLatchDelaySeconds;
    _scheduler.immediatePresentation = c.gameplayImmediate;
    _scheduler.skipHeldDraws = c.skipRedundantPresentations;
    _scheduler.heldRefreshDrawEvery = c.heldRefreshDrawEvery;
    _scheduler.latenessRefreshAllowance = c.presentationLatenessRefreshes;
    if (c.preferFreshestFrame) {
        _scheduler.selectionMode = MCFrameSelectionInteractive;
        _scheduler.maximumPendingFrames = 8;
    } else {
        _scheduler.selectionMode = MCFrameSelectionSmooth;
        _scheduler.maximumPendingFrames = 12;
    }
    return self;
}
- (MCVideoConfiguration *)configuration {
    return [_configuration copy];
}
- (BOOL)startWithRefreshRate:(float)hz error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"start on main thread");
    if (self.running)
        return YES;
    MCVideoConfiguration *c = _configuration;
    if (c.multiplier > 1 && c.interpolationBackend == MCInterpolationBackendVideoToolbox) {
        _vtConfig = [[VTLowLatencyFrameInterpolationConfiguration alloc]
                    initWithFrameWidth:c.inputWidth
                           frameHeight:c.inputHeight
            numberOfInterpolatedFrames:c.multiplier == 4 ? 2 : 1];
        _processor = [VTFrameProcessor new];
        NSError *e = nil;
        if (![_processor startSessionWithConfiguration:_vtConfig error:&e]) {
            if (error)
                *error = e ?: MCError(@"Interpolation unavailable");
            return NO;
        }
        NSMutableDictionary *attrs = [_vtConfig.destinationPixelBufferAttributes mutableCopy];
        attrs[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_destinations) !=
            kCVReturnSuccess) {
            [_processor endSession];
            if (error)
                *error = MCError(@"Destination pool unavailable");
            return NO;
        }
        if (c.multiplier == 4 && c.adaptiveMultiplier) {
            _fallbackConfig = [[VTLowLatencyFrameInterpolationConfiguration alloc]
                        initWithFrameWidth:c.inputWidth
                               frameHeight:c.inputHeight
                numberOfInterpolatedFrames:1];
            _fallbackProcessor = [VTFrameProcessor new];
            NSError *fallbackError = nil;
            if (![_fallbackProcessor startSessionWithConfiguration:_fallbackConfig
                                                             error:&fallbackError]) {
                if (error)
                    *error = fallbackError ?: MCError(@"2x fallback interpolation unavailable");
                [_processor endSession];
                CVPixelBufferPoolRelease(_destinations);
                _destinations = NULL;
                return NO;
            }
            NSMutableDictionary *fallbackAttrs =
                [_fallbackConfig.destinationPixelBufferAttributes mutableCopy];
            fallbackAttrs[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
            if (CVPixelBufferPoolCreate(
                    NULL, NULL, (__bridge CFDictionaryRef)fallbackAttrs, &_fallbackDestinations) !=
                kCVReturnSuccess) {
                if (error)
                    *error = MCError(@"Fallback destination pool unavailable");
                [_fallbackProcessor endSession];
                [_processor endSession];
                CVPixelBufferPoolRelease(_destinations);
                _destinations = NULL;
                return NO;
            }
        }
    }
    if (c.audioEnabled) {
        _audioEngine = [AVAudioEngine new];
        _player = [AVAudioPlayerNode new];
        [_audioEngine attachNode:_player];
        NSError *e = nil;
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000
                                                                               channels:2];
        if (@available(macOS 27.0, *)) {
            if (![_audioEngine connect:_player
                                    to:_audioEngine.mainMixerNode
                                format:format
                                 error:&e]) {
                if (error)
                    *error = e;
                return NO;
            }
        } else {
            [_audioEngine connect:_player to:_audioEngine.mainMixerNode format:format];
        }
        if (![_audioEngine startAndReturnError:&e]) {
            if (error)
                *error = e;
            [_processor endSession];
            if (_destinations) {
                CVPixelBufferPoolRelease(_destinations);
                _destinations = NULL;
            }
            return NO;
        }
        if (@available(macOS 27.0, *)) {
            if (![_player playAndReturnError:&e]) {
                if (error)
                    *error = e;
                [_audioEngine stop];
                return NO;
            }
        } else {
            [_player play];
        }
        _player.volume = self.muted ? 0 : 1;
    }
    _refreshPeriod = 1.0 / MAX(30, hz);
    self.latencyController =
        c.adaptiveLatency && !c.gameplayImmediate
            ? [[MCLatencyController alloc]
                  initWithMinimumDelay:c.minimumDelay
                          maximumDelay:c.maximumDelay
                          initialDelay:c.playoutDelay
                                policy:c.profile ? c.profile.policy : MCFramePolicyMinimumBoost]
            : nil;
    self.budgetController = (c.multiplier == 4 && c.adaptiveMultiplier)
                                ? [[MCFrameBudgetController alloc] initWithPreferredMultiplier:4]
                                : nil;
    self.activeMultiplier = c.gameplayImmediate ? 1 : c.multiplier;
    if (c.gameplayImmediate)
        self.currentPlayoutDelay = 0;
    self.nominalSourceInterval =
        (c.profile && c.profile.sourceFPS > 0 && isfinite(c.profile.sourceFPS))
            ? 1. / c.profile.sourceFPS
            : 0;
    _startTime = CACurrentMediaTime();
    _lastPTS = 0;
    _lastOutputPTS = 0;
    _hasHash = NO;
    _nextAudioPTS = 0;
    _lastAudioSource = 0;
    self.running = YES;
    [_scheduler startWithRefreshRate:hz];
    return YES;
}
- (void)stop {
    NSAssert(NSThread.isMainThread, @"stop on main thread");
    if (!self.running)
        return;
    self.running = NO;
    [_scheduler stop];
    [_lock lock];
    [_pendingFrames removeAllObjects];
    _lastUnique = nil;
    [_lock unlock];
    dispatch_sync(_worker, ^{
        self.previous = nil;
    });
    dispatch_group_wait(_gpuGroup, DISPATCH_TIME_FOREVER);
    dispatch_sync(_worker, ^{
        [self.processor endSession];
        self.processor = nil;
        [self.fallbackProcessor endSession];
        self.fallbackProcessor = nil;
        if (self.fallbackDestinations) {
            CVPixelBufferPoolRelease(self.fallbackDestinations);
            self.fallbackDestinations = NULL;
        }
        if (self.destinations) {
            CVPixelBufferPoolRelease(self.destinations);
            self.destinations = NULL;
        }
    });
    dispatch_sync(_audioQueue, ^{
        [self.player stop];
        [self.audioEngine stop];
        self.player = nil;
        self.audioEngine = nil;
    });
}
- (void)updateRefreshRate:(float)hz {
    _refreshPeriod = 1.0 / MAX(30, hz);
    if (self.running)
        [_scheduler startWithRefreshRate:hz];
}
- (void)setMuted:(BOOL)muted {
    @synchronized(self) {
        _muted = muted;
        self.player.volume = muted ? 0 : 1;
    }
}
- (BOOL)muted {
    @synchronized(self) {
        return _muted;
    }
}
#if defined(__aarch64__)
static uint64_t MCNEONFingerprint(CVPixelBufferRef b) {
    uint8x16_t accum = vdupq_n_u8(0);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    for (int p = 0; p < 2; p++) {
        const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, p);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(b, p),
               width = CVPixelBufferGetWidthOfPlane(b, p) * (p ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(b, p);
        for (size_t y = 0; y < height; y += 16)
            for (size_t x = 0; x + 16 <= width; x += 128) {
                uint8x16_t sample = vld1q_u8(base + y * stride + x);
                accum =
                    veorq_u8(accum, vaddq_u8(sample, vdupq_n_u8((uint8_t)(x / 128 + y / 16 + p))));
            }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    uint8_t bytes[16];
    vst1q_u8(bytes, accum);
    uint64_t h = 1469598103934665603ULL;
    for (int i = 0; i < 16; i++) {
        h ^= bytes[i];
        h *= 1099511628211ULL;
    }
    return h;
}
#endif
- (uint64_t)hashBuffer:(CVPixelBufferRef)b {
#if defined(__aarch64__)
    if (_configuration.duplicateFingerprintMethod == MCDuplicateFingerprintNEON)
        return MCNEONFingerprint(b);
#endif
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    uint64_t h = 1469598103934665603ULL;
    for (int plane = 0; plane < 2; plane++) {
        const uint8_t *data = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane),
               width = CVPixelBufferGetWidthOfPlane(b, plane) * (plane ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(b, plane);
        for (size_t y = 0; y < height; y += 16)
            for (size_t x = 0; x < width; x += 17) {
                h ^= data[y * stride + x];
                h *= 1099511628211ULL;
            }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    return h;
}
static BOOL MCShouldHoldDiscontinuity(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (!a || !b || a == b || CVPixelBufferGetPlaneCount(a) < 1 ||
        CVPixelBufferGetPlaneCount(b) < 1 || CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(b) ||
        CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(b))
        return NO;
    if (CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return NO;
    if (CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    const auto verdict = metalcadence::classifyDiscontinuity(
        static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(a, 0)),
        static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(b, 0)),
        CVPixelBufferGetWidthOfPlane(a, 0),
        CVPixelBufferGetHeightOfPlane(a, 0),
        CVPixelBufferGetBytesPerRowOfPlane(a, 0),
        CVPixelBufferGetBytesPerRowOfPlane(b, 0));
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return verdict.abrupt;
}
static BOOL MCEqualNV12(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (a == b)
        return YES;
    if (CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return NO;
    if (CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    BOOL equal = YES;
    for (int p = 0; p < 2 && equal; p++) {
        const uint8_t *x = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, p),
                      *y = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, p);
        size_t w = CVPixelBufferGetWidthOfPlane(a, p) * (p ? 2 : 1),
               h = CVPixelBufferGetHeightOfPlane(a, p),
               xs = CVPixelBufferGetBytesPerRowOfPlane(a, p),
               ys = CVPixelBufferGetBytesPerRowOfPlane(b, p);
        for (size_t row = 0; row < h; row++)
            if (memcmp(x + row * xs, y + row * ys, w)) {
                equal = NO;
                break;
            }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return equal;
}
static uint8_t MCYVideoLUT[256], MCUVVideoLUT[256];
static void MCInitializeColorRangeLUT(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int v = 0; v < 256; v++) {
            MCYVideoLUT[v] = (uint8_t)MAX(16, MIN(235, (int)lround(v * 219. / 255. + 16.)));
            MCUVVideoLUT[v] =
                (uint8_t)MAX(16, MIN(240, (int)lround((v - 128) * 224. / 255. + 128.)));
        }
    });
}
- (CVPixelBufferRef)normalizeFullRange:(CVPixelBufferRef)input {
    MCInitializeColorRangeLUT();
    CVPixelBufferRef output = NULL;
    static NSDictionary *limit;
    static dispatch_once_t limitOnce;
    dispatch_once(&limitOnce, ^{
        limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey : @12};
    });
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            NULL, _inputNormalizePool, (__bridge CFDictionaryRef)limit, &output) !=
        kCVReturnSuccess)
        return NULL;
    if (CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferRelease(output);
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(output, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(output);
        return NULL;
    }
    for (int plane = 0; plane < 2; plane++) {
        const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, plane);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output, plane);
        size_t width = CVPixelBufferGetWidthOfPlane(input, plane) * (plane ? 2 : 1),
               height = CVPixelBufferGetHeightOfPlane(input, plane);
        size_t ss = CVPixelBufferGetBytesPerRowOfPlane(input, plane),
               ds = CVPixelBufferGetBytesPerRowOfPlane(output, plane);
        const uint8_t *lut = plane ? MCUVVideoLUT : MCYVideoLUT;
        for (size_t y = 0; y < height; y++) {
            const uint8_t *in = src + y * ss;
            uint8_t *out = dst + y * ds;
            for (size_t x = 0; x < width; x++)
                out[x] = lut[in[x]];
        }
    }
    CVPixelBufferUnlockBaseAddress(output, 0);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVBufferPropagateAttachments(input, output);
    return output;
}
- (BOOL)submitVideo:(CVPixelBufferRef)b hostTime:(double)pts {
    if (!self.running)
        return NO;
    MCVideoConfiguration *c = _configuration;
    if (!b || !isfinite(pts) || pts <= 0 || CVPixelBufferGetWidth(b) != c.inputWidth ||
        CVPixelBufferGetHeight(b) != c.inputHeight ||
        (CVPixelBufferGetPixelFormatType(b) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
         CVPixelBufferGetPixelFormatType(b) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
        self.invalid++;
        return NO;
    }
    double hashStart = CACurrentMediaTime();
    uint64_t hash = c.duplicateDetection ? [self hashBuffer:b] : 0;
    [_lock lock];
    self.received++;
    if (!self.running || pts <= _lastPTS) {
        self.invalid++;
        [_lock unlock];
        return NO;
    }
    _lastPTS = pts;
    BOOL fingerprintMatch =
        c.duplicateDetection && _hasHash && hash == _lastHash && _lastUnique &&
        CVPixelBufferGetPixelFormatType(b) == CVPixelBufferGetPixelFormatType(_lastUnique.original);
    BOOL confirmed = fingerprintMatch && MCEqualNV12(b, _lastUnique.original);
    if (fingerprintMatch && !confirmed)
        self.duplicateHashCollisions++;
    if (confirmed) {
        self.duplicates++;
        [_statisticsLock lock];
        _hashSamples.record((CACurrentMediaTime() - hashStart) * 1000);
        [_statisticsLock unlock];
        [_lock unlock];
        return YES;
    }
    MCInputFrame *f = [MCInputFrame new];
    f.original = CVPixelBufferRetain(b);
    if (CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        double started = CACurrentMediaTime();
        f.buffer = [self normalizeFullRange:b];
        if (!f.buffer) {
            self.ingressDrops++;
            [_lock unlock];
            return NO;
        }
        self.fullRangeNormalized++;
        [_statisticsLock lock];
        _normalizationSamples.record((CACurrentMediaTime() - started) * 1000);
        [_statisticsLock unlock];
    } else
        f.buffer = CVPixelBufferRetain(b);
    f.pts = pts;
    f.arrival = hashStart;
    _hasHash = YES;
    _lastHash = hash;
    _lastUnique = f;
    [_statisticsLock lock];
    _hashSamples.record((CACurrentMediaTime() - hashStart) * 1000);
    [_statisticsLock unlock];
    if (_pendingFrames.count >= 4) {
        [_pendingFrames removeObjectAtIndex:0];
        self.ingressDrops++;
    }
    [_pendingFrames addObject:f];
    if (!_draining) {
        _draining = YES;
        dispatch_async(_worker, ^{
            [self drain];
        });
    }
    [_lock unlock];
    return YES;
}
- (void)drain {
    while (self.running) {
        @autoreleasepool {
            [_lock lock];
            if (!_pendingFrames.count || _availableGPUSlots.none()) {
                _draining = NO;
                [_lock unlock];
                return;
            }
            MCInputFrame *f = _pendingFrames.firstObject;
            [_pendingFrames removeObjectAtIndex:0];
            [_lock unlock];
            MCInputFrame *a = _previous;
            _previous = f;
            if (_configuration.gameplayImmediate || _configuration.multiplier == 1 ||
                self.presentation == MCVideoPresentationOriginal ||
                self.presentation == MCVideoPresentationUpscalingOnly)
                [self process:f next:f];
            else if (a)
                [self process:a next:f];
        }
    }
    [_lock lock];
    _draining = NO;
    [_lock unlock];
}
- (id<MTLTexture>)scale:(CVPixelBufferRef)pb
                     cb:(id<MTLCommandBuffer>)cb
                   refs:(NSMutableArray *)refs
                 native:(NSMutableArray *)native {
    MCVideoConfiguration *c = _configuration;
    CVMetalTextureRef y = NULL, uv = NULL;
    CVMetalTextureCacheCreateTextureFromImage(
        NULL, _cache, pb, NULL, MTLPixelFormatR8Unorm, c.inputWidth, c.inputHeight, 0, &y);
    CVMetalTextureCacheCreateTextureFromImage(NULL,
                                              _cache,
                                              pb,
                                              NULL,
                                              MTLPixelFormatRG8Unorm,
                                              c.inputWidth / 2,
                                              c.inputHeight / 2,
                                              1,
                                              &uv);
    if (!y || !uv) {
        if (y)
            CFRelease(y);
        if (uv)
            CFRelease(uv);
        return nil;
    }
    id<MTLTexture> out = [_pool take];
    id<MTLTexture> raw = _nativeResolution ? out : [_nativePool take];
    if (!out || !raw) {
        [_pool put:out];
        [_nativePool put:raw];
        CFRelease(y);
        CFRelease(uv);
        return nil;
    }
    [native addObject:raw];
    [refs addObject:CFBridgingRelease(y)];
    [refs addObject:CFBridgingRelease(uv)];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_convert];
    [enc setTexture:CVMetalTextureGetTexture(y) atIndex:0];
    [enc setTexture:CVMetalTextureGetTexture(uv) atIndex:1];
    int fullRange =
        CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    int matrix = 0;
    CFTypeRef attachment = CVBufferGetAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
    if (attachment) {
        if (CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4))
            matrix = 1;
        else if (CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_2020))
            matrix = 2;
    }
    [enc setTexture:raw atIndex:2];
    [enc setBytes:&fullRange length:sizeof(fullRange) atIndex:0];
    [enc setBytes:&matrix length:sizeof(matrix) atIndex:1];
    [enc dispatchThreads:MTLSizeMake(c.inputWidth, c.inputHeight, 1)
        threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
    [enc endEncoding];
    if (_nativeResolution)
        return out;
    _scaler.colorTexture = raw;
    _scaler.outputTexture = out;
    _scaler.inputContentWidth = c.inputWidth;
    _scaler.inputContentHeight = c.inputHeight;
    [_scaler encodeToCommandBuffer:cb];
    return out;
}
- (void)encodeBlendFrom:(id<MTLTexture>)a
                     to:(id<MTLTexture>)b
                 output:(id<MTLTexture>)out
                  phase:(float)phase
                command:(id<MTLCommandBuffer>)cb {
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_blend];
    [enc setTexture:a atIndex:0];
    [enc setTexture:b atIndex:1];
    [enc setTexture:out atIndex:2];
    [enc setBytes:&phase length:sizeof(phase) atIndex:0];
    [enc dispatchThreads:MTLSizeMake(out.width, out.height, 1)
        threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
    [enc endEncoding];
}
- (void)process:(MCInputFrame *)a next:(MCInputFrame *)b {
    double start = CACurrentMediaTime(), delta = b.pts - a.pts;
    NSInteger viewMode = self.presentation;
    NSInteger mult = (_configuration.gameplayImmediate || viewMode == MCVideoPresentationOriginal ||
                      viewMode == MCVideoPresentationUpscalingOnly)
                         ? 1
                         : self.activeMultiplier;
    if (mult > 1 && (delta <= 0 || delta > .15))
        return;
    [_lock lock];
    NSUInteger slot = NSNotFound;
    for (NSUInteger candidate = 0; candidate < _configuration.maxConcurrentGPUBatches;
         ++candidate) {
        if (_availableGPUSlots.test(candidate)) {
            _availableGPUSlots.reset(candidate);
            slot = candidate;
            break;
        }
    }
    if (slot != NSNotFound) {
        self.batchesInFlight++;
        self.peakBatches = MAX(self.peakBatches, self.batchesInFlight);
    }
    [_lock unlock];
    if (slot == NSNotFound)
        return;
    id<MTLCommandBuffer> cb = [_gpu commandBuffer];
    if (!cb) {
        self.gpuErrors++;
        [_lock lock];
        _availableGPUSlots.set(slot);
        self.batchesInFlight--;
        [_lock unlock];
        return;
    }
    if (!_nativeResolution)
        _scaler = _scalers[slot];
    BOOL useBlend =
        _configuration.interpolationBackend == MCInterpolationBackendLinearBlend && mult > 1;
    BOOL holdAbrupt = mult > 1 && _configuration.suppressAbruptInterpolation &&
                      MCShouldHoldDiscontinuity(a.buffer, b.buffer);
    if (holdAbrupt)
        self.abruptHoldBatches++;

    NSMutableArray *dest = [NSMutableArray new], *frames = [NSMutableArray new],
                   *phases = [NSMutableArray new];
    BOOL ok = YES;
    for (int i = 1; !useBlend && !holdAbrupt && i < mult; i++) {
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(
                NULL,
                (mult == 2 && _configuration.multiplier == 4 && _configuration.adaptiveMultiplier)
                    ? _fallbackDestinations
                    : _destinations,
                &pb) != kCVReturnSuccess) {
            self.destinationPoolFailures++;
            ok = NO;
            break;
        }
        CVBufferPropagateAttachments(a.buffer, pb);
        [dest addObject:CFBridgingRelease(pb)];
        double phase = (double)i / mult;
        VTFrameProcessorFrame *frame = [[VTFrameProcessorFrame alloc]
                   initWithBuffer:pb
            presentationTimeStamp:CMTimeMakeWithSeconds(a.pts + phase * delta, 60000)];
        if (!frame) {
            ok = NO;
            break;
        }
        [frames addObject:frame];
        [phases addObject:@(phase)];
    }
    NSError *vtError = nil;
    if (mult > 1 && !useBlend && !holdAbrupt && ok) {
        VTFrameProcessorFrame *af = [[VTFrameProcessorFrame alloc]
                                         initWithBuffer:a.buffer
                                  presentationTimeStamp:CMTimeMakeWithSeconds(a.pts, 60000)],
                              *bf = [[VTFrameProcessorFrame alloc]
                                         initWithBuffer:b.buffer
                                  presentationTimeStamp:CMTimeMakeWithSeconds(b.pts, 60000)];
        VTLowLatencyFrameInterpolationParameters *p =
            af && bf ? [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:bf
                                                                               previousFrame:af
                                                                          interpolationPhase:phases
                                                                           destinationFrames:frames]
                     : nil;
        VTFrameProcessor *current =
            (mult == 2 && _configuration.multiplier == 4 && _configuration.adaptiveMultiplier)
                ? _fallbackProcessor
                : _processor;
        ok = p && [current processWithParameters:p error:&vtError];
    }
    double fgEnd = CACurrentMediaTime();
    if (!ok) {
        NSLog(@"MetalCadence VideoToolbox interpolation rejected source; backend=%ld "
              @"multiplier=%ld inputFormat=%u lastError=%@",
              (long)_configuration.interpolationBackend,
              (long)mult,
              (unsigned)CVPixelBufferGetPixelFormatType(a.buffer),
              vtError);
        self.interpolationErrors++;
    }
    NSMutableArray *refs = [NSMutableArray new], *textures = [NSMutableArray new],
                   *native = [NSMutableArray new];
    id<MTLTexture> first = [self scale:a.buffer cb:cb refs:refs native:native];
    if (first) {
        [textures addObject:first];
    } else {
        self.scaleFailures++;
        ok = NO;
    }
    NSMutableArray *temporaryScaled = [NSMutableArray new], *temporaryNative = [NSMutableArray new];
    if (holdAbrupt && ok && first && native.count) {
        // Repeat the previous real image until the next real source frame.
        // Never feed a hard teleport through VideoToolbox optical flow.
        for (NSInteger i = 1; i < mult; i++) {
            [textures addObject:first];
            [native addObject:native[0]];
        }
    } else if (useBlend && ok && first && native.count) {
        id<MTLTexture> next = [self scale:b.buffer cb:cb refs:refs native:temporaryNative];
        if (next && temporaryNative.count) {
            [temporaryScaled addObject:next];
            for (int i = 1; i < mult; i++) {
                float phase = (float)i / mult;
                id<MTLTexture> out = [self.pool take];
                id<MTLTexture> raw = self.nativeResolution ? out : [self.nativePool take];
                if (!out || !raw) {
                    [self.pool put:out];
                    [self.nativePool put:raw];
                    ok = NO;
                    break;
                }
                [self encodeBlendFrom:first to:next output:out phase:phase command:cb];
                if (!self.nativeResolution)
                    [self encodeBlendFrom:native[0]
                                       to:temporaryNative[0]
                                   output:raw
                                    phase:phase
                                  command:cb];
                [textures addObject:out];
                [native addObject:raw];
            }
        } else
            ok = NO;
    } else if (ok)
        for (id pb in dest) {
            id<MTLTexture> t = [self scale:(__bridge CVPixelBufferRef)pb
                                        cb:cb
                                      refs:refs
                                    native:native];
            if (t)
                [textures addObject:t];
            else {
                self.scaleFailures++;
                ok = NO;
                break;
            }
        }
    BOOL encodedOK = ok;
    dispatch_group_enter(_gpuGroup);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(self.completionQueue, ^{
            @autoreleasepool {
                double end = CACurrentMediaTime();
                self.lastBatchDuration = end - start;
                self.observedSourceInterval = delta;
                if (self.budgetController) {
                    double budgetInterval = self.nominalSourceInterval > 0
                                                ? self.nominalSourceInterval
                                                : MIN(delta, 1. / 30.);
                    self.activeMultiplier = [self.budgetController
                        recordBatchSeconds:end - start
                            sourceInterval:budgetInterval
                              thermalState:[NSProcessInfo processInfo].thermalState];
                }
                for (id t in temporaryScaled)
                    [self.pool put:t];
                for (id t in temporaryNative)
                    [self.nativePool put:t];
                (void)refs;
                (void)dest;
                (void)a;
                (void)b;
                BOOL success = encodedOK;
                if (completed.status == MTLCommandBufferStatusError || !first) {
                    NSLog(@"MetalCadence GPU error status=%ld: %@",
                          (long)completed.status,
                          completed.error);
                    self.gpuErrors++;
                    MCRecycleUniqueTextures(textures, self.pool);
                    MCRecycleUniqueTextures(native, self.nativePool);
                } else {
                    if (textures.count < (NSUInteger)mult || !success)
                        self.incompleteGeneratedBatches++;
                    if (mult == 1)
                        self.nativeOutputBatches++;
                    if (!success && textures.count > 1) {
                        for (NSUInteger i = 1; i < textures.count; i++)
                            [self.pool put:textures[i]];
                        [textures removeObjectsInRange:NSMakeRange(1, textures.count - 1)];
                        for (NSUInteger i = 1; i < native.count; i++)
                            [self.nativePool put:native[i]];
                        [native removeObjectsInRange:NSMakeRange(1, native.count - 1)];
                    }
                    if (self.running) {
                        double readyAge = MAX(0, end - a.pts);
                        [self.statisticsLock lock];
                        self->_readySamples.record(readyAge);
                        [self.statisticsLock unlock];
                        if (self.latencyController) {
                            MCSchedulerPressure pressure = [self.scheduler pressureCounters];
                            double phaseTime = mult > 1 ? delta / mult : delta;
                            double delay =
                                [self.latencyController observeReadyAge:readyAge
                                                          refreshPeriod:self.refreshPeriod
                                                         outputInterval:phaseTime
                                                           queuedFrames:pressure.overdue
                                                        totalSuperseded:pressure.reactiveSuperseded
                                                          totalOverflow:pressure.overflow];
                            self.currentPlayoutDelay = delay;
                            MCLatencyEstimate estimate = [self.latencyController estimate];
                            self.readyPrediction = estimate.readyPrediction;
                            self.deadlineSafety = estimate.deadlineSafety;
                        }
                        double pts = _configuration.gameplayImmediate
                                         ? a.pts
                                         : a.pts + self.currentPlayoutDelay;
                        MCOutputBatch *batch = [MCOutputBatch new];
                        batch.textures = textures;
                        batch.pool = self.pool;
                        batch.nativeTextures = native;
                        batch.nativePool = self.nativePool;
                        for (NSUInteger i = 0; i < textures.count; i++) {
                            double target =
                                MAX(pts + i * delta / MAX(1, mult), self.lastOutputPTS + .0001);
                            self.outputFrameAttempts++;
                            BOOL accepted = [self.scheduler
                                submit:[[MCFrame alloc] initWithID:++self->_outputID
                                                               pts:target
                                                        sourceTime:a.pts + i * delta / MAX(1, mult)
                                                           payload:@[ batch, @(i) ]]];
                            if (accepted) {
                                self.submitted++;
                            } else {
                                self.rejectedOutputFrames++;
                            }
                            self.lastOutputPTS = target;
                        }
                        self.processed++;
                        [self.statisticsLock lock];
                        self->_fgSamples.record((fgEnd - start) * 1000);
                        self->_pairSamples.record((end - start) * 1000);
                        self->_scaleSamples.record((completed.GPUEndTime - completed.GPUStartTime) *
                                                   1000);
                        if (completed.GPUStartTime > 0 &&
                            completed.GPUEndTime >= completed.GPUStartTime) {
                            self.scaleGPUSum += completed.GPUEndTime - completed.GPUStartTime;
                            if (self.previousScaleGPUEnd > 0)
                                self.scaleGPUIdleSum +=
                                    MAX(0, completed.GPUStartTime - self.previousScaleGPUEnd);
                            self.previousScaleGPUEnd = completed.GPUEndTime;
                        }
                        self->_arrivalSamples.record((b.arrival - b.pts) * 1000);
                        [self.statisticsLock unlock];
                    } else {
                        MCRecycleUniqueTextures(textures, self.pool);
                        MCRecycleUniqueTextures(native, self.nativePool);
                    }
                }
                [self.lock lock];
                self->_availableGPUSlots.set(slot);
                self.batchesInFlight--;
                BOOL resume = self.running && self.pendingFrames.count && !self.draining;
                if (resume)
                    self.draining = YES;
                [self.lock unlock];
                if (resume)
                    dispatch_async(self.worker, ^{
                        [self drain];
                    });
                dispatch_group_leave(self.gpuGroup);
            }
        });
    }];
    [cb commit];
}
- (BOOL)submitAudio:(const float *)samples frameCount:(NSUInteger)count hostTime:(double)pts {
    if (!self.running || !_configuration.audioEnabled || !samples || count == 0 || count > 4800 ||
        !isfinite(pts))
        return NO;
    @synchronized(self) {
        if (self.audioPending >= 16 || self.audioOutstanding >= 32) {
            self.audioBackpressureDrops++;
            self.audioDropped++;
            return NO;
        }
        self.audioPending++;
    }
    NSData *data = [NSData dataWithBytes:samples length:count * 2 * sizeof(float)];
    dispatch_async(_audioQueue, ^{
        @autoreleasepool {
            if (self.running && self.player) {
                double now = CACurrentMediaTime();
                if (self.latencyController)
                    [self.latencyController observeAudioSchedulingAge:now - pts];
                double target = pts + self.currentPlayoutDelay;
                BOOL continuous = self.lastAudioSource > 0 &&
                                  fabs((pts - self.lastAudioSource) -
                                       (double)self.lastAudioFrameCount / 48000.) < .006;
                if (self.lastAudioSource > 0 && !continuous)
                    self.audioDiscontinuities++;
                if (self.nextAudioPTS > now + .004 && continuous) {
                    self.audioScheduleDriftMs = (self.nextAudioPTS - target) * 1000;
                    target = self.nextAudioPTS;
                } else
                    self.audioScheduleDriftMs = 0;
                if (target <= now + .004) {
                    self.audioLateDrops++;
                    self.audioDropped++;
                    if (self.latencyController)
                        [self.latencyController recordAudioDeadlineMiss];
                } else if (target > now + .35) {
                    self.audioTooFarDrops++;
                    self.audioDropped++;
                } else {
                    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc]
                        initWithPCMFormat:[[AVAudioFormat alloc]
                                              initStandardFormatWithSampleRate:48000
                                                                      channels:2]
                            frameCapacity:(AVAudioFrameCount)count];
                    buf.frameLength = (AVAudioFrameCount)count;
                    const float *p = (const float *)data.bytes;
                    for (NSUInteger j = 0; j < count; j++) {
                        buf.floatChannelData[0][j] = p[2 * j];
                        buf.floatChannelData[1][j] = p[2 * j + 1];
                    }
                    @synchronized(self) {
                        self.audioOutstanding++;
                    }
                    [self.player scheduleBuffer:buf
                                         atTime:[AVAudioTime
                                                    timeWithHostTime:[AVAudioTime
                                                                         hostTimeForSeconds:target]]
                                        options:0
                         completionCallbackType:AVAudioPlayerNodeCompletionDataRendered
                              completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
                                  @synchronized(self) {
                                      self.audioRendered++;
                                      self.audioOutstanding = MAX(0, self.audioOutstanding - 1);
                                  }
                              }];
                    self.audioSubmitted++;
                    self.nextAudioPTS = target + count / 48000.;
                    self.lastAudioSource = pts;
                    self.lastAudioFrameCount = count;
                }
            }
            @synchronized(self) {
                self.audioPending--;
            }
        }
    });
    return YES;
}
- (NSDictionary *)metrics {
    NSMutableDictionary *m = [[_scheduler metrics] mutableCopy];
    [_statisticsLock lock];
    const auto fgSamples = _fgSamples;
    const auto pairSamples = _pairSamples;
    const auto hashSamples = _hashSamples;
    const auto normalizationSamples = _normalizationSamples;
    const auto readySamples = _readySamples;
    const auto scaleSamples = _scaleSamples;
    const auto arrivalSamples = _arrivalSamples;
    const double scaleGPUSum = self.scaleGPUSum, scaleGPUIdleSum = self.scaleGPUIdleSum;
    [_statisticsLock unlock];
    m[@"interpolationMedianMs"] = @(fgSamples.percentile(.5));
    m[@"processingP50Ms"] = @(pairSamples.percentile(.5));
    m[@"duplicateP95Ms"] = @(hashSamples.percentile(.95));
    m[@"fullRangeNormalizationP95Ms"] = @(normalizationSamples.percentile(.95));
    m[@"normalizedFullRange"] = @(self.fullRangeNormalized);
    m[@"readyAgeP95Ms"] = @(readySamples.percentile(.95) * 1000);
    m[@"processingP95Ms"] = @(pairSamples.percentile(.95));
    m[@"processingP99Ms"] = @(pairSamples.percentile(.99));
    m[@"scaleGPUMedianMs"] = @(scaleSamples.percentile(.5));
    m[@"scaleGPUExecutionSeconds"] = @(scaleGPUSum);
    m[@"scaleGPUQueueGapSeconds"] = @(scaleGPUIdleSum);
    double seconds = MAX(.001, CACurrentMediaTime() - self.startTime);
    m[@"gpuCommandWorkPercent"] = @(MIN(100., MAX(0., scaleGPUSum / seconds * 100.)));
    m[@"gpuWorkMillisecondsPerSecond"] = @(MAX(0., scaleGPUSum / seconds * 1000.));
    m[@"ingressP95Ms"] = @(arrivalSamples.percentile(.95));

    if (_configuration.profile) {
        m[@"profileKind"] = @(_configuration.profile.kind);
        m[@"framePolicy"] = @(_configuration.profile.policy);
        m[@"producerKind"] = @(_configuration.profile.producer);
        m[@"goalMinimumFPS"] = @(_configuration.profile.minimumFreshFPS);
        m[@"goalPreferredFPS"] = @(_configuration.profile.preferredFreshFPS);
    }
    m[@"deadlineSafetyMs"] = @(self.deadlineSafety * 1000);
    m[@"readyPredictionMs"] = @(self.readyPrediction * 1000);
    [_lock lock];
    m[@"pendingInputFrames"] = @(_pendingFrames.count);
    [_lock unlock];
    m[@"batchesInFlight"] = @(self.batchesInFlight);
    m[@"peakBatches"] = @(self.peakBatches);
    m[@"received"] = @(self.received);
    m[@"duplicates"] = @(self.duplicates);
    m[@"duplicateHashCollisions"] = @(self.duplicateHashCollisions);
    m[@"duplicateFingerprintMethod"] = @(_configuration.duplicateFingerprintMethod);
    m[@"ingressDrops"] = @(self.ingressDrops);
    m[@"invalid"] = @(self.invalid);
    m[@"processed"] = @(self.processed);
    m[@"interpolationErrors"] = @(self.interpolationErrors);
    m[@"interpolationBackend"] = @(_configuration.interpolationBackend);
    m[@"activeMultiplier"] = @(self.activeMultiplier);
    m[@"adaptiveMultiplierEnabled"] = @(_configuration.adaptiveMultiplier);
    m[@"nominalSourceIntervalMs"] = @(self.nominalSourceInterval * 1000);
    m[@"observedSourceIntervalMs"] = @(self.observedSourceInterval * 1000);
    m[@"lastBatchDurationMs"] = @(self.lastBatchDuration * 1000);
    m[@"fallbackTransitions"] = @(self.budgetController.fallbackTransitions);
    m[@"recoveryProbes"] = @(self.budgetController.recoveryProbes);
    m[@"fallbackCooldownPairs"] = @(self.budgetController.cooldownPairs);
    m[@"fallbackSlowStreak"] = @(self.budgetController.slowStreak);
    m[@"gpuErrors"] = @(self.gpuErrors);
    m[@"scheduledFrames"] = @(self.submitted);
    m[@"abruptHoldBatches"] = @(self.abruptHoldBatches);
    m[@"abruptGuardEnabled"] = @(_configuration.suppressAbruptInterpolation);
    m[@"outputFrameAttempts"] = @(self.outputFrameAttempts);
    m[@"rejectedOutputFrames"] = @(self.rejectedOutputFrames);
    m[@"incompleteGeneratedBatches"] = @(self.incompleteGeneratedBatches);
    m[@"nativeOutputBatches"] = @(self.nativeOutputBatches);
    m[@"destinationPoolFailures"] = @(self.destinationPoolFailures);
    m[@"scaleFailures"] = @(self.scaleFailures);
    m[@"presentationMode"] = @(self.presentation);
    m[@"audioSubmitted"] = @(self.audioSubmitted);
    m[@"audioRendered"] = @(self.audioRendered);
    m[@"audioDropped"] = @(self.audioDropped);
    m[@"audioLateDrops"] = @(self.audioLateDrops);
    m[@"audioTooFarDrops"] = @(self.audioTooFarDrops);
    m[@"audioBackpressureDrops"] = @(self.audioBackpressureDrops);
    m[@"pipelineInitializationMs"] = @(self.pipelineInitMs);
    m[@"pipelineCacheHit"] = @(self.pipelineCacheHit);
    m[@"precompiledShaderLibrary"] = @(self.precompiledShaderLibrary);
    m[@"textureAllocations"] = @(_pool.allocations);
    m[@"textureReuses"] = @(_pool.reuses);
    m[@"gameplayImmediate"] = @(_configuration.gameplayImmediate);
    m[@"nativeResolutionBypass"] = @(_nativeResolution);
    m[@"nativeTextureAllocations"] = @(_nativePool.allocations);
    m[@"nativeTextureReuses"] = @(_nativePool.reuses);
    m[@"textureEvictions"] = @(_pool.evictions);
    m[@"nativeTextureEvictions"] = @(_nativePool.evictions);
    m[@"textureBudgetDenied"] = @(_pool.denied + _nativePool.denied);
    m[@"cachedOutputTextures"] = @(_pool.cachedCount);
    m[@"cachedNativeTextures"] = @(_nativePool.cachedCount);
    m[@"gpuTextureBudgetMiB"] = @(_configuration.gpuTextureBudgetMiB);
    m[@"maxConcurrentGPUBatches"] = @(_configuration.maxConcurrentGPUBatches);
    m[@"preallocatedTexturesPerPool"] = @(_configuration.preallocatedTexturesPerPool);
    m[@"maxCachedTexturesPerPool"] = @(_configuration.maxCachedTexturesPerPool);
    {
        std::scoped_lock budgetLock(_textureBudget->mutex);
        m[@"textureBudgetActiveMiB"] = @(_textureBudget->activeBytes / 1048576.0);
        m[@"textureBudgetCachedMiB"] = @(_textureBudget->cachedBytes / 1048576.0);
        m[@"textureBudgetPeakMiB"] = @(_textureBudget->peakBytes / 1048576.0);
    }
    if (self.latencyController)
        [m addEntriesFromDictionary:[self.latencyController metrics]];
    m[@"playoutDelayMs"] = @(self.currentPlayoutDelay * 1000);
    m[@"elapsed"] = @(MAX(0, CACurrentMediaTime() - _startTime));
    m[@"thermalState"] = @([NSProcessInfo processInfo].thermalState);
    task_vm_info_data_t ti = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&ti, &count) == KERN_SUCCESS)
        m[@"memoryMiB"] = @(ti.phys_footprint / 1048576.);
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec +
                 ru.ru_stime.tv_usec / 1e6,
           now = CACurrentMediaTime();
    m[@"cpuSeconds"] = @(cpu);
    @synchronized(self) {
        m[@"cpuPercentOneCore"] =
            @(self.previousMetricsTime ? (cpu - self.previousMetricsCPU) /
                                             MAX(.001, now - self.previousMetricsTime) * 100
                                       : 0);
        self.previousMetricsCPU = cpu;
        self.previousMetricsTime = now;
    }
    int gpu = -1;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) ==
        KERN_SUCCESS) {
        io_service_t svc;
        while ((svc = IOIteratorNext(it))) {
            CFTypeRef value =
                IORegistryEntryCreateCFProperty(svc, CFSTR("PerformanceStatistics"), NULL, 0);
            if (value) {
                NSDictionary *d = CFBridgingRelease(value);
                NSNumber *n = d[@"Device Utilization %"];
                if (n)
                    gpu = MAX(gpu, n.intValue);
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(it);
    }
    m[@"systemGPUPercent"] = @(gpu);
    m[@"audioOutstanding"] = @(self.audioOutstanding);
    m[@"audioScheduleDriftMs"] = @(self.audioScheduleDriftMs);
    m[@"audioDiscontinuities"] = @(self.audioDiscontinuities);
    m[@"audioQueueLeadMs"] = @(MAX(0, self.nextAudioPTS - CACurrentMediaTime()) * 1000);
    return m;
}
- (void)dealloc {
    if (_cache)
        CFRelease(_cache);
    if (_destinations)
        CVPixelBufferPoolRelease(_destinations);
    if (_inputNormalizePool)
        CVPixelBufferPoolRelease(_inputNormalizePool);
    if (_fallbackDestinations)
        CVPixelBufferPoolRelease(_fallbackDestinations);
}
@end
