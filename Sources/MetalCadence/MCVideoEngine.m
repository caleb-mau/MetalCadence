#import "MetalCadence.h"
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <mach/mach.h>
#import <sys/resource.h>
#import <IOKit/IOKitLib.h>
#import <math.h>
static NSError *MCError(NSString *message){return [NSError errorWithDomain:@"MetalCadence" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
@implementation MCVideoConfiguration
-(instancetype)init{if((self=[super init])){_inputWidth=1920;_inputHeight=1080;_outputWidth=2560;_outputHeight=1440;_multiplier=2;_adaptiveLatency=YES;_duplicateDetection=YES;_audioEnabled=YES;_playoutDelay=.075;_minimumDelay=.012;_maximumDelay=.125;_presentation=MCVideoPresentationEnhanced;}return self;}
-(id)copyWithZone:(NSZone*)zone{MCVideoConfiguration *c=[MCVideoConfiguration new];c.inputWidth=_inputWidth;c.inputHeight=_inputHeight;c.outputWidth=_outputWidth;c.outputHeight=_outputHeight;c.multiplier=_multiplier;c.adaptiveLatency=_adaptiveLatency;c.duplicateDetection=_duplicateDetection;c.audioEnabled=_audioEnabled;c.playoutDelay=_playoutDelay;c.minimumDelay=_minimumDelay;c.maximumDelay=_maximumDelay;c.presentation=_presentation;return c;}
@end
@interface MCInputFrame:NSObject
@property CVPixelBufferRef buffer;
@property double pts,arrival;
@end
@implementation MCInputFrame
-(void)dealloc{if(_buffer)CVPixelBufferRelease(_buffer);}
@end
@interface MCTexturePool:NSObject
@property NSLock *lock;
@property NSMutableArray *free;
@property id<MTLDevice> device;
@property MTLTextureDescriptor *descriptor;
@property (atomic) long allocations,reuses;
-(id<MTLTexture>)take;
-(void)put:(id<MTLTexture>)texture;
@end
@implementation MCTexturePool
-(id<MTLTexture>)take{[self.lock lock];id<MTLTexture> t=self.free.lastObject;if(t){[self.free removeLastObject];self.reuses++;}[self.lock unlock];if(!t){t=[self.device newTextureWithDescriptor:self.descriptor];self.allocations++;}return t;}
-(void)put:(id<MTLTexture>)t{if(!t)return;[self.lock lock];if(self.free.count<24)[self.free addObject:t];[self.lock unlock];}
@end
@interface MCOutputBatch:NSObject
@property NSArray<id<MTLTexture>> *textures;
@property MCTexturePool *pool,*nativePool;
@property NSArray<id<MTLTexture>> *nativeTextures;
@end
@implementation MCOutputBatch
-(void)dealloc{for(id<MTLTexture> t in _textures)[_pool put:t];for(id<MTLTexture> t in _nativeTextures)[_nativePool put:t];}
@end
static NSString * const MCShader=@"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void convert(texture2d<float,access::sample> y[[texture(0)]],texture2d<float,access::sample> uv[[texture(1)]],texture2d<float,access::write> out[[texture(2)]],uint2 g[[thread_position_in_grid]]){if(g.x>=out.get_width()||g.y>=out.get_height())return;constexpr sampler s(filter::linear);float2 p=(float2(g)+.5)/float2(out.get_width(),out.get_height());float l=(y.sample(s,p).r*255.-16.)/219.;float2 ch=(uv.sample(s,p).rg*255.-128.)/224.;out.write(float4(clamp(float3(l+1.5748*ch.y,l-.1873*ch.x-.4681*ch.y,l+1.8556*ch.x),0.,1.),1),g);}"
"struct V{float4 pos[[position]];float2 uv;};vertex V vert(uint i[[vertex_id]]){float2 a=float2((i<<1)&2,i&2);return {float4(a*float2(2,-2)+float2(-1,1),0,1),a};}"
"fragment float4 frag(V v[[stage_in]],texture2d<float> a[[texture(0)]],texture2d<float> b[[texture(1)]],constant int &mode[[buffer(0)]],constant float2 &aspect[[buffer(1)]]){constexpr sampler s(filter::linear,address::clamp_to_edge);float2 p=v.uv;bool split=mode==0;bool right=p.x>=.5;if(split)p.x=fract(p.x*2);float ar=aspect.x*(split?.5:1.);if(ar<aspect.y)p.y=(p.y-.5)*aspect.y/ar+.5;else p.x=(p.x-.5)*ar/aspect.y+.5;if(any(p<0)||any(p>1))return float4(.035,.04,.05,1);return mode==2||(split&&!right)?a.sample(s,p):b.sample(s,p);}";
@interface MCVideoEngine ()
@property(nonatomic,readwrite,copy) MCVideoConfiguration *configuration;
@property(atomic,readwrite) BOOL running;
@property(atomic,readwrite) double currentPlayoutDelay;
@property CAMetalLayer *layer;
@property id<MTLDevice> device;
@property id<MTLCommandQueue> gpu;
@property id<MTLComputePipelineState> convert;
@property id<MTLRenderPipelineState> render;
@property id<MTLFXSpatialScaler> scaler;
@property id<MTLTexture> scratch;
@property NSArray *scalers,*scratches;
@property NSMutableIndexSet *freeSlots;
@property dispatch_group_t gpuGroup;
@property (atomic) NSInteger batchesInFlight,peakBatches;
@property NSMutableArray *readySamples,*hashSamples;
@property MCInputFrame *lastUnique;
@property double refreshPeriod;
@property double scaleGPUSum,scaleGPUIdleSum,previousScaleGPUEnd;
@property MCTexturePool *pool,*nativePool;
@property MCDisplayScheduler *scheduler;
@property VTFrameProcessor *processor;
@property VTLowLatencyFrameInterpolationConfiguration *vtConfig;
@property CVMetalTextureCacheRef cache;
@property CVPixelBufferPoolRef destinations;
@property NSLock *lock,*statisticsLock;
@property dispatch_queue_t worker,audioQueue,completionQueue;
@property MCInputFrame *pending,*previous;
@property BOOL draining,hasHash;
@property uint64_t lastHash;
@property double lastPTS,lastOutputPTS,nextAudioPTS,lastAudioSource;
@property int64_t outputID;
@property(atomic) long received,duplicates,ingressDrops,invalid,processed,interpolationErrors,gpuErrors,submitted,audioSubmitted,audioRendered,audioDropped;
@property NSMutableArray *fgSamples,*pairSamples,*scaleSamples,*arrivalSamples;
@property AVAudioEngine *audioEngine;
@property AVAudioPlayerNode *player;
@property double startTime;
@property (atomic) long audioPending,audioOutstanding;
@property double previousMetricsTime,previousMetricsCPU;
@end
@implementation MCVideoEngine
@synthesize configuration=_configuration;
@synthesize muted=_muted;
-(instancetype)initWithConfiguration:(MCVideoConfiguration*)configuration layer:(CAMetalLayer*)layer error:(NSError**)error{
 if(!(self=[super init]))return nil;MCVideoConfiguration *c=[configuration copy];if(c.inputWidth<2||c.inputHeight<2||c.inputWidth%2||c.inputHeight%2||c.outputWidth<2||c.outputHeight<2||!(c.multiplier==1||c.multiplier==2||c.multiplier==4)||!isfinite(c.minimumDelay)||!isfinite(c.maximumDelay)||!isfinite(c.playoutDelay)||c.minimumDelay<0||c.maximumDelay<c.minimumDelay){if(error)*error=MCError(@"Invalid configuration");return nil;}
 _configuration=c;_layer=layer;_presentation=c.presentation;_currentPlayoutDelay=MAX(c.minimumDelay,MIN(c.maximumDelay,c.playoutDelay));_device=layer.device?:MTLCreateSystemDefaultDevice();if(!_device){if(error)*error=MCError(@"Metal device unavailable");return nil;}_layer.device=_device;_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;_gpu=[_device newCommandQueue];
 NSError *e=nil;id<MTLLibrary> lib=[_device newLibraryWithSource:MCShader options:nil error:&e];if(!lib){if(error)*error=e;return nil;}_convert=[_device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"convert"] error:&e];MTLRenderPipelineDescriptor *rd=[MTLRenderPipelineDescriptor new];rd.vertexFunction=[lib newFunctionWithName:@"vert"];rd.fragmentFunction=[lib newFunctionWithName:@"frag"];rd.colorAttachments[0].pixelFormat=_layer.pixelFormat;_render=[_device newRenderPipelineStateWithDescriptor:rd error:&e];if(!_convert||!_render){if(error)*error=e?:MCError(@"Metal pipeline unavailable");return nil;}
 MTLFXSpatialScalerDescriptor *sd=[MTLFXSpatialScalerDescriptor new];sd.inputWidth=c.inputWidth;sd.inputHeight=c.inputHeight;sd.outputWidth=c.outputWidth;sd.outputHeight=c.outputHeight;sd.colorTextureFormat=MTLPixelFormatRGBA8Unorm;sd.outputTextureFormat=MTLPixelFormatRGBA8Unorm;sd.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;_scaler=[sd newSpatialScalerWithDevice:_device];if(!_scaler){if(error)*error=MCError(@"MetalFX scaler unsupported");return nil;}
 MTLTextureDescriptor *in=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:c.inputWidth height:c.inputHeight mipmapped:NO];in.storageMode=MTLStorageModePrivate;in.usage=MTLTextureUsageShaderWrite|MTLTextureUsageShaderRead|_scaler.colorTextureUsage;_scratch=[_device newTextureWithDescriptor:in];id<MTLFXSpatialScaler> second=[sd newSpatialScalerWithDevice:_device];id<MTLTexture> secondScratch=[_device newTextureWithDescriptor:in];if(!second||!secondScratch||!_scratch){if(error)*error=MCError(@"Second GPU slot unavailable");return nil;}_scalers=@[_scaler,second];_scratches=@[_scratch,secondScratch];_freeSlots=[NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0,2)];_gpuGroup=dispatch_group_create();MTLTextureDescriptor *out=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:c.outputWidth height:c.outputHeight mipmapped:NO];out.storageMode=MTLStorageModePrivate;out.usage=MTLTextureUsageShaderRead|_scaler.outputTextureUsage;_pool=[MCTexturePool new];_pool.lock=[NSLock new];_pool.free=[NSMutableArray new];_pool.device=_device;_pool.descriptor=out;_nativePool=[MCTexturePool new];_nativePool.lock=[NSLock new];_nativePool.free=[NSMutableArray new];_nativePool.device=_device;_nativePool.descriptor=in;
 if(CVMetalTextureCacheCreate(NULL,NULL,_device,NULL,&_cache)!=kCVReturnSuccess){if(error)*error=MCError(@"Metal texture cache unavailable");return nil;}
 _lock=[NSLock new];_statisticsLock=[NSLock new];_worker=dispatch_queue_create("metalcadence.sdk.video",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));_completionQueue=dispatch_queue_create("metalcadence.sdk.completion",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));_audioQueue=dispatch_queue_create("metalcadence.sdk.audio",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));_fgSamples=[NSMutableArray new];_pairSamples=[NSMutableArray new];_scaleSamples=[NSMutableArray new];_arrivalSamples=[NSMutableArray new];_readySamples=[NSMutableArray new];_hashSamples=[NSMutableArray new];
 __weak MCVideoEngine *weak=self;_scheduler=[[MCDisplayScheduler alloc]initWithLayer:layer device:_device capacity:12 maxInFlight:2 encode:^(id<MTLCommandBuffer> cb,id<CAMetalDrawable> d,MCFrame *frame){MCVideoEngine *engine=weak;if(!engine)return;NSArray *p=frame.payload;MCOutputBatch *batch=p[0];NSUInteger index=[p[1] unsignedIntegerValue];int mode=(int)engine.presentation;float aspect[2]={(float)d.texture.width/MAX(1,d.texture.height),(float)c.outputWidth/c.outputHeight};MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=d.texture;rp.colorAttachments[0].loadAction=MTLLoadActionDontCare;rp.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];[enc setRenderPipelineState:engine.render];id<MTLTexture> original=batch.nativeTextures[0];id<MTLTexture> enhanced=batch.textures[index];if(mode==3)enhanced=batch.textures[0];if(mode==4)enhanced=batch.nativeTextures[index];[enc setFragmentTexture:original atIndex:0];[enc setFragmentTexture:enhanced atIndex:1];[enc setFragmentBytes:&mode length:sizeof(mode) atIndex:0];[enc setFragmentBytes:aspect length:sizeof(aspect) atIndex:1];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];}];return self;
}
-(MCVideoConfiguration*)configuration{return [_configuration copy];}
-(BOOL)startWithRefreshRate:(float)hz error:(NSError**)error{NSAssert(NSThread.isMainThread,@"start on main thread");if(self.running)return YES;
 MCVideoConfiguration *c=_configuration;if(c.multiplier>1){_vtConfig=[[VTLowLatencyFrameInterpolationConfiguration alloc]initWithFrameWidth:c.inputWidth frameHeight:c.inputHeight numberOfInterpolatedFrames:c.multiplier==4?2:1];_processor=[VTFrameProcessor new];NSError *e=nil;if(![_processor startSessionWithConfiguration:_vtConfig error:&e]){if(error)*error=e?:MCError(@"Interpolation unavailable");return NO;}NSMutableDictionary *attrs=[_vtConfig.destinationPixelBufferAttributes mutableCopy];attrs[(id)kCVPixelBufferMetalCompatibilityKey]=@YES;if(CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attrs,&_destinations)!=kCVReturnSuccess){[_processor endSession];if(error)*error=MCError(@"Destination pool unavailable");return NO;}}
 if(c.audioEnabled){_audioEngine=[AVAudioEngine new];_player=[AVAudioPlayerNode new];[_audioEngine attachNode:_player];[_audioEngine connect:_player to:_audioEngine.mainMixerNode format:[[AVAudioFormat alloc]initStandardFormatWithSampleRate:48000 channels:2]];NSError *e=nil;if(![_audioEngine startAndReturnError:&e]){if(error)*error=e;[_processor endSession];if(_destinations){CVPixelBufferPoolRelease(_destinations);_destinations=NULL;}return NO;}[_player play];_player.volume=self.muted?0:1;}
 _refreshPeriod=1.0/MAX(30,hz);_startTime=CACurrentMediaTime();_lastPTS=0;_lastOutputPTS=0;_hasHash=NO;_nextAudioPTS=0;_lastAudioSource=0;self.running=YES;[_scheduler startWithRefreshRate:hz];return YES;
}
-(void)stop{NSAssert(NSThread.isMainThread,@"stop on main thread");if(!self.running)return;self.running=NO;[_scheduler stop];[_lock lock];_pending=nil;_lastUnique=nil;[_lock unlock];dispatch_sync(_worker,^{self.previous=nil;});dispatch_group_wait(_gpuGroup,DISPATCH_TIME_FOREVER);dispatch_sync(_worker,^{[self.processor endSession];self.processor=nil;if(self.destinations){CVPixelBufferPoolRelease(self.destinations);self.destinations=NULL;}});dispatch_sync(_audioQueue,^{[self.player stop];[self.audioEngine stop];self.player=nil;self.audioEngine=nil;});}
-(void)updateRefreshRate:(float)hz{_refreshPeriod=1.0/MAX(30,hz);if(self.running)[_scheduler startWithRefreshRate:hz];}
-(void)setMuted:(BOOL)muted{ @synchronized(self){_muted=muted;self.player.volume=muted?0:1;} }
-(BOOL)muted{@synchronized(self){return _muted;}}
-(uint64_t)hashBuffer:(CVPixelBufferRef)b{CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly);uint64_t h=1469598103934665603ULL;for(int plane=0;plane<2;plane++){const uint8_t *data=CVPixelBufferGetBaseAddressOfPlane(b,plane);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(b,plane),width=CVPixelBufferGetWidthOfPlane(b,plane)*(plane?2:1),height=CVPixelBufferGetHeightOfPlane(b,plane);for(size_t y=0;y<height;y+=16)for(size_t x=0;x<width;x+=17){h^=data[y*stride+x];h*=1099511628211ULL;}}CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);return h;}
static BOOL MCEqualNV12(CVPixelBufferRef a,CVPixelBufferRef b){
 if(a==b)return YES;
 if(CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return NO;
 if(CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess){CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);return NO;}
 BOOL equal=YES;for(int p=0;p<2&&equal;p++){const uint8_t *x=CVPixelBufferGetBaseAddressOfPlane(a,p),*y=CVPixelBufferGetBaseAddressOfPlane(b,p);size_t w=CVPixelBufferGetWidthOfPlane(a,p)*(p?2:1),h=CVPixelBufferGetHeightOfPlane(a,p),xs=CVPixelBufferGetBytesPerRowOfPlane(a,p),ys=CVPixelBufferGetBytesPerRowOfPlane(b,p);for(size_t row=0;row<h;row++)if(memcmp(x+row*xs,y+row*ys,w)){equal=NO;break;}}
 CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);return equal;
}
-(BOOL)submitVideo:(CVPixelBufferRef)b hostTime:(double)pts{if(!self.running)return NO;MCVideoConfiguration *c=_configuration;if(!b||!isfinite(pts)||pts<=0||CVPixelBufferGetWidth(b)!=c.inputWidth||CVPixelBufferGetHeight(b)!=c.inputHeight||CVPixelBufferGetPixelFormatType(b)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange){self.invalid++;return NO;}double hashStart=CACurrentMediaTime();uint64_t hash=c.duplicateDetection?[self hashBuffer:b]:0;[_lock lock];self.received++;if(!self.running||pts<=_lastPTS){self.invalid++;[_lock unlock];return NO;}_lastPTS=pts;if(c.duplicateDetection&&_hasHash&&hash==_lastHash&&_lastUnique&&MCEqualNV12(b,_lastUnique.buffer)){self.duplicates++;[_statisticsLock lock];[_hashSamples addObject:@((CACurrentMediaTime()-hashStart)*1000)];if(_hashSamples.count>600)[_hashSamples removeObjectAtIndex:0];[_statisticsLock unlock];[_lock unlock];return YES;}_hasHash=YES;_lastHash=hash;MCInputFrame *f=[MCInputFrame new];f.buffer=CVPixelBufferRetain(b);f.pts=pts;f.arrival=hashStart;_lastUnique=f;[_statisticsLock lock];[_hashSamples addObject:@((CACurrentMediaTime()-hashStart)*1000)];if(_hashSamples.count>600)[_hashSamples removeObjectAtIndex:0];[_statisticsLock unlock];if(_pending)self.ingressDrops++;_pending=f;if(!_draining){_draining=YES;dispatch_async(_worker,^{[self drain];});}[_lock unlock];return YES;}
-(void)drain{while(self.running){@autoreleasepool{[_lock lock];MCInputFrame *f=_pending;_pending=nil;if(!f||!_freeSlots.count){_pending=f;_draining=NO;[_lock unlock];return;}[_lock unlock];MCInputFrame *a=_previous;_previous=f;if(_configuration.multiplier==1)[self process:f next:f];else if(a)[self process:a next:f];}}[_lock lock];_draining=NO;[_lock unlock];}
-(id<MTLTexture>)scale:(CVPixelBufferRef)pb cb:(id<MTLCommandBuffer>)cb refs:(NSMutableArray*)refs native:(NSMutableArray*)native{MCVideoConfiguration *c=_configuration;CVMetalTextureRef y=NULL,uv=NULL;CVMetalTextureCacheCreateTextureFromImage(NULL,_cache,pb,NULL,MTLPixelFormatR8Unorm,c.inputWidth,c.inputHeight,0,&y);CVMetalTextureCacheCreateTextureFromImage(NULL,_cache,pb,NULL,MTLPixelFormatRG8Unorm,c.inputWidth/2,c.inputHeight/2,1,&uv);if(!y||!uv){if(y)CFRelease(y);if(uv)CFRelease(uv);return nil;}id<MTLTexture> out=[_pool take],raw=[_nativePool take];if(!out||!raw){[_pool put:out];[_nativePool put:raw];CFRelease(y);CFRelease(uv);return nil;}[native addObject:raw];[refs addObject:CFBridgingRelease(y)];[refs addObject:CFBridgingRelease(uv)];id<MTLComputeCommandEncoder> enc=[cb computeCommandEncoder];[enc setComputePipelineState:_convert];[enc setTexture:CVMetalTextureGetTexture(y) atIndex:0];[enc setTexture:CVMetalTextureGetTexture(uv) atIndex:1];[enc setTexture:raw atIndex:2];[enc dispatchThreads:MTLSizeMake(c.inputWidth,c.inputHeight,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];[enc endEncoding];_scaler.colorTexture=raw;_scaler.outputTexture=out;_scaler.inputContentWidth=c.inputWidth;_scaler.inputContentHeight=c.inputHeight;[_scaler encodeToCommandBuffer:cb];return out;}
-(void)process:(MCInputFrame*)a next:(MCInputFrame*)b{double start=CACurrentMediaTime(),delta=b.pts-a.pts;NSInteger mult=_configuration.multiplier;if(mult>1&&(delta<=0||delta>.15))return;[_lock lock];NSUInteger slot=_freeSlots.firstIndex;if(slot!=NSNotFound)[_freeSlots removeIndex:slot];if(slot!=NSNotFound){self.batchesInFlight++;self.peakBatches=MAX(self.peakBatches,self.batchesInFlight);}[_lock unlock];if(slot==NSNotFound)return;_scaler=_scalers[slot];_scratch=_scratches[slot];
 NSMutableArray *dest=[NSMutableArray new],*frames=[NSMutableArray new],*phases=[NSMutableArray new];BOOL ok=YES;for(int i=1;i<mult;i++){CVPixelBufferRef pb=NULL;if(CVPixelBufferPoolCreatePixelBuffer(NULL,_destinations,&pb)!=kCVReturnSuccess){ok=NO;break;}[dest addObject:CFBridgingRelease(pb)];double phase=(double)i/mult;VTFrameProcessorFrame *frame=[[VTFrameProcessorFrame alloc]initWithBuffer:pb presentationTimeStamp:CMTimeMakeWithSeconds(a.pts+phase*delta,60000)];if(!frame){ok=NO;break;}[frames addObject:frame];[phases addObject:@(phase)];}
 if(mult>1&&ok){VTFrameProcessorFrame *af=[[VTFrameProcessorFrame alloc]initWithBuffer:a.buffer presentationTimeStamp:CMTimeMakeWithSeconds(a.pts,60000)],*bf=[[VTFrameProcessorFrame alloc]initWithBuffer:b.buffer presentationTimeStamp:CMTimeMakeWithSeconds(b.pts,60000)];VTLowLatencyFrameInterpolationParameters *p=af&&bf?[[VTLowLatencyFrameInterpolationParameters alloc]initWithSourceFrame:bf previousFrame:af interpolationPhase:phases destinationFrames:frames]:nil;NSError *e=nil;ok=p&&[_processor processWithParameters:p error:&e];}
 double fgEnd=CACurrentMediaTime();if(!ok)self.interpolationErrors++;
 id<MTLCommandBuffer> cb=[_gpu commandBuffer];NSMutableArray *refs=[NSMutableArray new],*textures=[NSMutableArray new],*native=[NSMutableArray new];id<MTLTexture> first=[self scale:a.buffer cb:cb refs:refs native:native];if(first)[textures addObject:first];if(ok)for(id pb in dest){id<MTLTexture> t=[self scale:(__bridge CVPixelBufferRef)pb cb:cb refs:refs native:native];if(t)[textures addObject:t];else{ok=NO;break;}}BOOL encodedOK=ok;dispatch_group_enter(_gpuGroup);
 [cb addCompletedHandler:^(id<MTLCommandBuffer> completed){
 dispatch_async(self.completionQueue,^{@autoreleasepool{
 double end=CACurrentMediaTime();(void)refs;(void)dest;(void)a;(void)b;BOOL success=encodedOK;
 if(completed.status==MTLCommandBufferStatusError||!first){self.gpuErrors++;for(id t in textures)[self.pool put:t];for(id t in native)[self.nativePool put:t];}
 else {
 if(!success&&textures.count>1){for(NSUInteger i=1;i<textures.count;i++)[self.pool put:textures[i]];[textures removeObjectsInRange:NSMakeRange(1,textures.count-1)];for(NSUInteger i=1;i<native.count;i++)[self.nativePool put:native[i]];[native removeObjectsInRange:NSMakeRange(1,native.count-1)];}
 if(self.running){
 double readyAge=MAX(0,end-a.pts);[self.statisticsLock lock];[self.readySamples addObject:@(readyAge)];if(self.readySamples.count>120)[self.readySamples removeObjectAtIndex:0];
 double predicted=[self p:self.readySamples q:.95];[self.statisticsLock unlock];
 if(self.configuration.adaptiveLatency){double safety=MAX(.003,self.refreshPeriod*.75);double desired=MAX(self.configuration.minimumDelay,MIN(self.configuration.maximumDelay,predicted+safety)),old=self.currentPlayoutDelay;self.currentPlayoutDelay=desired>old?old*.65+desired*.35:MAX(desired,old-.0005);}
 double pts=a.pts+self.currentPlayoutDelay;MCOutputBatch *batch=[MCOutputBatch new];batch.textures=textures;batch.pool=self.pool;batch.nativeTextures=native;batch.nativePool=self.nativePool;for(NSUInteger i=0;i<textures.count;i++){double target=MAX(pts+i*delta/MAX(1,mult),self.lastOutputPTS+.0001);if([self.scheduler submit:[[MCFrame alloc]initWithID:++self->_outputID pts:target sourceTime:a.pts+i*delta/MAX(1,mult) payload:@[batch,@(i)]]])self.submitted++;self.lastOutputPTS=target;}self.processed++;
 [self.statisticsLock lock];[self.fgSamples addObject:@((fgEnd-start)*1000)];[self.pairSamples addObject:@((end-start)*1000)];[self.scaleSamples addObject:@((completed.GPUEndTime-completed.GPUStartTime)*1000)];if(completed.GPUStartTime>0&&completed.GPUEndTime>=completed.GPUStartTime){self.scaleGPUSum+=completed.GPUEndTime-completed.GPUStartTime;if(self.previousScaleGPUEnd>0)self.scaleGPUIdleSum+=MAX(0,completed.GPUStartTime-self.previousScaleGPUEnd);self.previousScaleGPUEnd=completed.GPUEndTime;}[self.arrivalSamples addObject:@((b.arrival-b.pts)*1000)];for(NSMutableArray *x in @[self.fgSamples,self.pairSamples,self.scaleSamples,self.arrivalSamples])if(x.count>600)[x removeObjectAtIndex:0];[self.statisticsLock unlock];
 }else{for(id t in textures)[self.pool put:t];for(id t in native)[self.nativePool put:t];}
 }
 [self.lock lock];[self.freeSlots addIndex:slot];self.batchesInFlight--;BOOL resume=self.running&&self.pending&&!self.draining;if(resume)self.draining=YES;[self.lock unlock];if(resume)dispatch_async(self.worker,^{[self drain];});dispatch_group_leave(self.gpuGroup);
 }});
 }];[cb commit];
}
-(BOOL)submitAudio:(const float*)samples frameCount:(NSUInteger)count hostTime:(double)pts{if(!self.running||!_configuration.audioEnabled||!samples||count==0||count>4800||!isfinite(pts))return NO;@synchronized(self){if(self.audioPending>=16||self.audioOutstanding>=32){self.audioDropped++;return NO;}self.audioPending++;}NSData *data=[NSData dataWithBytes:samples length:count*2*sizeof(float)];dispatch_async(_audioQueue,^{@autoreleasepool{if(self.running&&self.player){double now=CACurrentMediaTime(),target=pts+self.currentPlayoutDelay;if(self.nextAudioPTS>now+.004&&self.lastAudioSource>0&&fabs(pts-self.lastAudioSource)<.05)target=self.nextAudioPTS;if(target<=now+.004||target>now+.35){self.audioDropped++;}else{AVAudioPCMBuffer *buf=[[AVAudioPCMBuffer alloc]initWithPCMFormat:[[AVAudioFormat alloc]initStandardFormatWithSampleRate:48000 channels:2] frameCapacity:(AVAudioFrameCount)count];buf.frameLength=(AVAudioFrameCount)count;const float *p=data.bytes;for(NSUInteger j=0;j<count;j++){buf.floatChannelData[0][j]=p[2*j];buf.floatChannelData[1][j]=p[2*j+1];}self.audioOutstanding++;[self.player scheduleBuffer:buf atTime:[AVAudioTime timeWithHostTime:[AVAudioTime hostTimeForSeconds:target]] options:0 completionCallbackType:AVAudioPlayerNodeCompletionDataRendered completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type){self.audioRendered++;self.audioOutstanding=MAX(0,self.audioOutstanding-1);}];self.audioSubmitted++;self.nextAudioPTS=target+count/48000.;self.lastAudioSource=pts;}}@synchronized(self){self.audioPending--;}}});return YES;}
-(double)p:(NSArray*)x q:(double)q{NSArray *a=[x sortedArrayUsingSelector:@selector(compare:)];return a.count?[a[(NSUInteger)floor((a.count-1)*q)] doubleValue]:0;}
-(NSDictionary*)metrics{NSMutableDictionary *m=[[_scheduler metrics] mutableCopy];[_statisticsLock lock];m[@"interpolationMedianMs"]=@([self p:_fgSamples q:.5]);m[@"processingP50Ms"]=@([self p:_pairSamples q:.5]);m[@"duplicateP95Ms"]=@([self p:_hashSamples q:.95]);m[@"readyAgeP95Ms"]=@([self p:_readySamples q:.95]*1000);m[@"processingP95Ms"]=@([self p:_pairSamples q:.95]);m[@"processingP99Ms"]=@([self p:_pairSamples q:.99]);m[@"scaleGPUMedianMs"]=@([self p:_scaleSamples q:.5]);m[@"scaleGPUExecutionSeconds"]=@(self.scaleGPUSum);m[@"scaleGPUQueueGapSeconds"]=@(self.scaleGPUIdleSum);m[@"ingressP95Ms"]=@([self p:_arrivalSamples q:.95]);[_statisticsLock unlock];m[@"batchesInFlight"]=@(self.batchesInFlight);m[@"peakBatches"]=@(self.peakBatches);m[@"received"]=@(self.received);m[@"duplicates"]=@(self.duplicates);m[@"ingressDrops"]=@(self.ingressDrops);m[@"invalid"]=@(self.invalid);m[@"processed"]=@(self.processed);m[@"interpolationErrors"]=@(self.interpolationErrors);m[@"gpuErrors"]=@(self.gpuErrors);m[@"scheduledFrames"]=@(self.submitted);m[@"audioSubmitted"]=@(self.audioSubmitted);m[@"audioRendered"]=@(self.audioRendered);m[@"audioDropped"]=@(self.audioDropped);m[@"textureAllocations"]=@(_pool.allocations);m[@"textureReuses"]=@(_pool.reuses);m[@"nativeTextureAllocations"]=@(_nativePool.allocations);m[@"nativeTextureReuses"]=@(_nativePool.reuses);m[@"playoutDelayMs"]=@(self.currentPlayoutDelay*1000);m[@"elapsed"]=@(MAX(0,CACurrentMediaTime()-_startTime));m[@"thermalState"]=@([NSProcessInfo processInfo].thermalState);task_vm_info_data_t ti={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&ti,&count)==KERN_SUCCESS)m[@"memoryMiB"]=@(ti.phys_footprint/1048576.);struct rusage ru;getrusage(RUSAGE_SELF,&ru);double cpu=ru.ru_utime.tv_sec+ru.ru_utime.tv_usec/1e6+ru.ru_stime.tv_sec+ru.ru_stime.tv_usec/1e6,now=CACurrentMediaTime();m[@"cpuSeconds"]=@(cpu);@synchronized(self){m[@"cpuPercentOneCore"]=@(self.previousMetricsTime?(cpu-self.previousMetricsCPU)/MAX(.001,now-self.previousMetricsTime)*100:0);self.previousMetricsCPU=cpu;self.previousMetricsTime=now;}int gpu=-1;io_iterator_t it=0;if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&it)==KERN_SUCCESS){io_service_t svc;while((svc=IOIteratorNext(it))){CFTypeRef value=IORegistryEntryCreateCFProperty(svc,CFSTR("PerformanceStatistics"),NULL,0);if(value){NSDictionary *d=CFBridgingRelease(value);NSNumber *n=d[@"Device Utilization %"];if(n)gpu=MAX(gpu,n.intValue);}IOObjectRelease(svc);}IOObjectRelease(it);}m[@"systemGPUPercent"]=@(gpu);m[@"audioOutstanding"]=@(self.audioOutstanding);return m;}
-(void)dealloc{if(_cache)CFRelease(_cache);if(_destinations)CVPixelBufferPoolRelease(_destinations);}
@end
