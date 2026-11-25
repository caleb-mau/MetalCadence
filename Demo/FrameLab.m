
#import <Cocoa/Cocoa.h>
#import "MetalCadence.h"
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <IOKit/IOKitLib.h>
#import <sys/resource.h>
#import <MetalKit/MetalKit.h>
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#include <math.h>
static const int W=1920,H=1080,OW=2560,OH=1440;
static NSString *shader=@"#include <metal_stdlib>\nusing namespace metal;\n"
"float hash(float2 p){return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453);}"
"float3 scene(float2 uv,float t){float2 p=uv*2-1; p.x*=1.7778; float bend=.17*sin(t*1.0472);float horizon=-.19;float3 c=mix(float3(.16,.32,.55),float3(.75,.80,.84),clamp((p.y+1)*.75,0.,1.));"
"float sun=length(p-float2(.85,-.72));c+=float3(.8,.52,.2)*exp(-sun*sun*18);"
"if(p.y<horizon){float bx=(p.x+bend)*8;float k=floor(bx);float ht=.10+hash(float2(k,2))*.56; if(p.y>horizon-ht){float2 q=float2(fract(bx), (p.y-horizon+ht)*20);c=float3(.10,.14,.20)+hash(float2(k,1))*.11;float windows=step(.24,fract(q.x*4))*step(fract(q.x*4),.78)*step(.22,fract(q.y))*step(fract(q.y),.64);c+=windows*float3(.45,.30,.12)*step(.35,hash(float2(floor(q.x*4)+k*7,floor(q.y))));}}"
"if(p.y>=horizon){float z=1.0/max(.025,p.y-horizon);float x=(p.x-bend*(1.-.4/(z+1)))*z;float road=abs(x);float tile=floor(z*2+t*9);float noise=hash(floor(float2(x*75,z*40+t*180))); c=float3(.16,.19,.21)+noise*.07;"
"if(road>1.5){c=float3(.12,.24,.10)+noise*.13; if(road<1.72)c=mix(float3(.7,.7,.65),float3(.7,.09,.06),step(.5,fract(z*2+t*8)));}else{if(abs(road-1.43)<.035)c=float3(.85,.82,.62);if(abs(x)<.024&&fract(z*.7+t*3)>.43)c=float3(.9,.88,.74);}"
"for(int i=0;i<8;i++){float zz=1.0+float(i)*1.4+fmod(t*1.4,1.4);float side=(i%2==0?-1.:1.);float xx=side*(2.1+hash(float2(i,4))*.5)/zz+bend;float yy=horizon+1./zz;float2 d=p-float2(xx,yy);float r=.24/zz; if(abs(d.x)<.032/zz&&d.y<0&&d.y>-.65/zz)c=float3(.22,.13,.075);if(length((d+float2(0,.49/zz))*float2(1,.75))<r)c=float3(.09,.25,.12)+noise*.1;}}"
"float cx=.35*sin(t*1.0472);float2 car=p-float2(cx,.43);if(abs(car.x)<.23&&car.y>-.10&&car.y<.11){c=float3(.62,.07,.04)*(1.-.6*abs(car.y));if(car.y<-.035&&abs(car.x)<.17)c=float3(.14,.24,.32);if(car.y>.045&&abs(car.x)>.115)c=float3(1,.15,.04);if(car.y>.075&&abs(car.x)<.08)c=float3(.8,.8,.72);}"
"float2 hud=uv-float2(.87,.86);if(length(hud)<.085&&length(hud)>.079)c=float3(.85);if(abs(hud.y)<.002&&abs(hud.x)<.06)c=float3(.9);return clamp(c,0.,1.);}"
"float3 yuv(float3 c){return float3((16.+219.*dot(c,float3(.2126,.7152,.0722)))/255.,(128.+224.*dot(c,float3(-.1146,-.3854,.5)))/255.,(128.+224.*dot(c,float3(.5,-.4542,-.0458)))/255.);}"
"kernel void generate(texture2d<float,access::write> y[[texture(0)]],texture2d<float,access::write> uv[[texture(1)]],constant float &t[[buffer(0)]],uint2 g[[thread_position_in_grid]]){if(g.x>=y.get_width()||g.y>=y.get_height())return;float2 p=(float2(g)+.5)/float2(y.get_width(),y.get_height());float3 v=yuv(scene(p,t));y.write(float4(v.x,0,0,1),g);if((g.x%2)==0&&(g.y%2)==0)uv.write(float4(v.yz,0,1),g/2);}"
"kernel void convert(texture2d<float,access::sample> y[[texture(0)]],texture2d<float,access::sample> uv[[texture(1)]],texture2d<float,access::write> out[[texture(2)]],uint2 g[[thread_position_in_grid]]){if(g.x>=out.get_width()||g.y>=out.get_height())return;constexpr sampler s(filter::linear);float2 p=(float2(g)+.5)/float2(out.get_width(),out.get_height());float l=(y.sample(s,p).r*255.-16.)/219.;float2 ch=(uv.sample(s,p).rg*255.-128.)/224.;out.write(float4(clamp(float3(l+1.5748*ch.y,l-.1873*ch.x-.4681*ch.y,l+1.8556*ch.x),0.,1.),1),g);}"
"struct V{float4 pos[[position]];float2 uv;};vertex V vert(uint i[[vertex_id]]){float2 a=float2((i<<1)&2,i&2);return {float4(a*float2(2,-2)+float2(-1,1),0,1),a};}"
"fragment float4 frag(V v[[stage_in]],texture2d<float> a[[texture(0)]],texture2d<float> b[[texture(1)]],texture2d<float> ref[[texture(2)]],constant int &mode[[buffer(0)]],constant float &aspect[[buffer(1)]]){constexpr sampler s(filter::linear,address::clamp_to_edge);float2 p=v.uv;bool split=mode==0||mode==4;bool right=p.x>=.5;if(split)p.x=fract(p.x*2);float ar=aspect*(split?.5:1.);if(ar<1.77778)p.y=(p.y-.5)*1.77778/ar+.5;else p.x=(p.x-.5)*ar/1.77778+.5;if(any(p<0)||any(p>1))return float4(.035,.04,.05,1);if(mode==1)return b.sample(s,p);if(mode==2)return ref.sample(s,p);if(mode==3)return a.sample(s,p);if(mode==4)return right?ref.sample(s,p):b.sample(s,p);if(mode==5)return float4(min(abs(b.sample(s,p).rgb-ref.sample(s,p).rgb)*5.,1.),1);return right?b.sample(s,p):a.sample(s,p);}";
@interface Frame : NSObject
@property CVPixelBufferRef pb;
@property CVMetalTextureRef yref;
@property CVMetalTextureRef uvref;
@property id<MTLTexture> y,uv;
@end
@implementation Frame
-(void)dealloc {if(_yref)CFRelease(_yref);if(_uvref)CFRelease(_uvref);if(_pb)CVPixelBufferRelease(_pb);}
@end
@interface Pair : NSObject
@property id<MTLTexture> previous,mid,current,reference;
@property double fg,scale,gpu,source,total,ready,psnr,baselinePSNR;
@property BOOL ok;
@property long seq;
@end
@implementation Pair
@end
@interface Lab : NSObject <NSApplicationDelegate,MTKViewDelegate>
@property NSWindow *window;
@property MTKView *view;
@property MCDisplayScheduler *scheduler;
@property dispatch_source_t reportTimer;
@property NSThread *producerThread;
@property (atomic) BOOL sourceRequested;
@property double origin,prevWall,prevCPU;
@property long lastSource;
@property (atomic) long produced,sourceSkipped;
@property (atomic) BOOL rawMode;
@property (atomic) NSInteger displayMode;
@property (atomic) double playoutDelay;
@property NSPopUpButton *latencyMenu;
@property NSTextField *stats,*status;
@property NSPopUpButton *modes,*sources;
@property BOOL useRaw;
@property Frame *poolA,*poolB,*poolR,*poolM;
@property id<MTLDevice> dev;
@property id<MTLCommandQueue> queue,displayQ;
@property id<MTLComputePipelineState> gen,conv;
@property id<MTLRenderPipelineState> render;
@property id<MTLFXSpatialScaler> scaler;
@property VTFrameProcessor *processor;
@property VTLowLatencyFrameInterpolationConfiguration *config;
@property CVMetalTextureCacheRef cache;
@property dispatch_queue_t worker;
@property dispatch_source_t timer,drawTimer;
@property Pair *pending,*active;
@property NSInteger phase;
@property long seq,shown,unique,repeats,missed,errors,presented,lastFrameID,inFlight;
@property id activity;
@property double lastPresented;
@property NSMutableArray<NSNumber*> *presentGaps;
@property double begin,lastReport;
@property NSMutableArray<NSNumber*> *fgTimes,*scaleTimes,*totalTimes,*gpuTimes,*quality,*baselineQuality;
@property BOOL busy;
@property NSInteger mode;
@property NSData *raw;
@property NSUInteger rawCount;
@property NSString *assetName;
@end
@implementation Lab
-(Frame*)frame:(BOOL)dest {
 Frame *f=[Frame new]; CVPixelBufferRef pb=NULL; NSMutableDictionary *attrs=[(dest?self.config.destinationPixelBufferAttributes:self.config.sourcePixelBufferAttributes) mutableCopy];
 attrs[(id)kCVPixelBufferMetalCompatibilityKey]=@YES;
 CVReturn r=CVPixelBufferCreate(kCFAllocatorDefault,W,H,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&pb);
 if(r||!pb)return nil;f.pb=pb;CVMetalTextureRef yr=NULL,ur=NULL;
 CVMetalTextureCacheCreateTextureFromImage(NULL,self.cache,pb,NULL,MTLPixelFormatR8Unorm,W,H,0,&yr);
 CVMetalTextureCacheCreateTextureFromImage(NULL,self.cache,pb,NULL,MTLPixelFormatRG8Unorm,W/2,H/2,1,&ur);
 f.yref=yr;f.uvref=ur;if(!yr||!ur)return nil;f.y=CVMetalTextureGetTexture(yr);f.uv=CVMetalTextureGetTexture(ur);return f;
}
-(void)encode:(id<MTLCommandBuffer>)cb pipeline:(id<MTLComputePipelineState>)ps textures:(NSArray*)textures time:(float*)t width:(int)w height:(int)h {
 id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:ps];for(NSUInteger i=0;i<textures.count;i++)[e setTexture:textures[i] atIndex:i];if(t)[e setBytes:t length:sizeof(float) atIndex:0];[e dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];[e endEncoding];
}
-(void)fill:(Frame*)f index:(long)i cb:(id<MTLCommandBuffer>)cb {
 if(self.rawMode&&self.rawCount){const uint8_t *p=(const uint8_t*)self.raw.bytes+(i%self.rawCount)*(W*H*3/2);CVPixelBufferLockBaseAddress(f.pb,0);for(int plane=0;plane<2;plane++){uint8_t *dst=CVPixelBufferGetBaseAddressOfPlane(f.pb,plane);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(f.pb,plane);int rows=plane?H/2:H;const uint8_t *src=p+(plane?W*H:0);for(int j=0;j<rows;j++)memcpy(dst+j*stride,src+j*W,W);}CVPixelBufferUnlockBaseAddress(f.pb,0);}
 else {float t=(float)(i%360)/60.;[self encode:cb pipeline:self.gen textures:@[f.y,f.uv] time:&t width:W height:H];}
}
-(id<MTLTexture>)tex:(int)w height:(int)h usage:(MTLTextureUsage)usage {MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];d.storageMode=MTLStorageModePrivate;d.usage=usage;return [self.dev newTextureWithDescriptor:d];}
-(id<MTLTexture>)scaleFrame:(Frame*)f cb:(id<MTLCommandBuffer>)cb {
 id<MTLTexture> in=[self tex:W height:H usage:MTLTextureUsageShaderWrite|MTLTextureUsageShaderRead|self.scaler.colorTextureUsage];
 id<MTLTexture> out=[self tex:OW height:OH usage:MTLTextureUsageShaderRead|self.scaler.outputTextureUsage];
 [self encode:cb pipeline:self.conv textures:@[f.y,f.uv,in] time:NULL width:W height:H];
 self.scaler.colorTexture=in;self.scaler.outputTexture=out;self.scaler.inputContentWidth=W;self.scaler.inputContentHeight=H;[self.scaler encodeToCommandBuffer:cb];return out;
}
-(void)work:(long)n {
 @autoreleasepool{
 double start=CACurrentMediaTime();if(!self.poolA){self.poolA=[self frame:NO];self.poolB=[self frame:NO];self.poolR=[self frame:NO];self.poolM=[self frame:YES];} Frame *a=self.poolA,*b=self.poolB,*r=self.poolR,*m=self.poolM; if(!a||!b||!r||!m){dispatch_async(dispatch_get_main_queue(),^{self.errors++;self.busy=NO;self.status.stringValue=@"Pixel buffer allocation failed";});return;}
 id<MTLCommandBuffer> s=[self.queue commandBuffer];[self fill:a index:n*2 cb:s];[self fill:b index:n*2+2 cb:s];BOOL reference=self.displayMode==2||self.displayMode==4||self.displayMode==5;if(reference)[self fill:r index:n*2+1 cb:s];if(!self.rawMode){[s commit];[s waitUntilCompleted];}double st=CACurrentMediaTime();
 VTFrameProcessorFrame *af=[[VTFrameProcessorFrame alloc]initWithBuffer:a.pb presentationTimeStamp:CMTimeMake(n*2,60)];
 VTFrameProcessorFrame *bf=[[VTFrameProcessorFrame alloc]initWithBuffer:b.pb presentationTimeStamp:CMTimeMake(n*2+2,60)];
 VTFrameProcessorFrame *mf=[[VTFrameProcessorFrame alloc]initWithBuffer:m.pb presentationTimeStamp:CMTimeMake(n*2+1,60)];
 NSError *err=nil;BOOL ok=NO;if(af&&bf&&mf){VTLowLatencyFrameInterpolationParameters *p=[[VTLowLatencyFrameInterpolationParameters alloc]initWithSourceFrame:bf previousFrame:af interpolationPhase:@[@0.5] destinationFrames:@[mf]];if(p)ok=[self.processor processWithParameters:p error:&err];}
 double after=CACurrentMediaTime();Pair *pair=[Pair new];
pair.seq=n;pair.ok=ok;pair.source=(st-start)*1000;pair.fg=(after-st)*1000;
 id<MTLCommandBuffer> cb=[self.queue commandBuffer];pair.previous=[self scaleFrame:a cb:cb];pair.mid=[self scaleFrame:ok?m:a cb:cb];if(reference)pair.reference=[self scaleFrame:r cb:cb];[cb commit];[cb waitUntilCompleted];pair.scale=(CACurrentMediaTime()-after)*1000;pair.gpu=(cb.GPUEndTime-cb.GPUStartTime)*1000;pair.total=(CACurrentMediaTime()-start)*1000;pair.ready=CACurrentMediaTime();
 if(cb.status==MTLCommandBufferStatusError){ok=NO;err=cb.error;pair.ok=NO;}
 NSString *error=err.localizedDescription?:@"Unknown interpolation failure";
 self.produced++;
 double pts=self.origin+n/30.0+self.playoutDelay;
 [self.scheduler submit:[[MCFrame alloc]initWithID:n*2 pts:pts payload:@[pair,@0]]];
 [self.scheduler submit:[[MCFrame alloc]initWithID:n*2+1 pts:pts+1./60. payload:@[pair,@1]]];
 dispatch_async(dispatch_get_main_queue(),^{if(!pair.ok){self.errors++;self.status.stringValue=error;}[self.fgTimes addObject:@(pair.fg)];[self.scaleTimes addObject:@(pair.scale)];[self.totalTimes addObject:@(pair.total)];[self.gpuTimes addObject:@(pair.gpu)];for(NSMutableArray *arr in @[self.fgTimes,self.scaleTimes,self.totalTimes,self.gpuTimes])if(arr.count>600)[arr removeObjectAtIndex:0];});

 }
}
-(double)percentile:(NSArray*)a q:(double)q {if(!a.count)return 0;NSArray *s=[a sortedArrayUsingSelector:@selector(compare:)];return [s[(NSUInteger)floor((s.count-1)*q)] doubleValue];}
-(void)tick {self.rawMode=self.sourceRequested;long n=(long)floor((CACurrentMediaTime()-self.origin)*30+.2);if(n<=self.lastSource)return;if(self.lastSource>=0&&n>self.lastSource+1)self.sourceSkipped+=n-self.lastSource-1;self.lastSource=n;[self work:n];}
-(void)drawInMTKView:(MTKView*)v{}
-(void)mtkView:(MTKView*)v drawableSizeWillChange:(CGSize)s{}
-(void)change:(id)sender{self.displayMode=self.modes.indexOfSelectedItem;}
-(void)changeSource:(id)sender{BOOL raw=self.rawCount&&self.sources.indexOfSelectedItem==0;self.sourceRequested=raw;self.status.stringValue=raw?@"Big Buck Bunny | direct Metal":@"Driving scene | direct Metal";}
-(void)changeLatency:(id)sender{self.playoutDelay=[@[@.040,@.060,@.080][self.latencyMenu.indexOfSelectedItem] doubleValue];}
-(void)report{
 NSDictionary *m=[self.scheduler metrics];double now=CACurrentMediaTime(),elapsed=now-self.origin;struct rusage ru;getrusage(RUSAGE_SELF,&ru);double cpu=ru.ru_utime.tv_sec+ru.ru_utime.tv_usec/1e6+ru.ru_stime.tv_sec+ru.ru_stime.tv_usec/1e6;double pct=self.prevWall?(cpu-self.prevCPU)/(now-self.prevWall)*100:0;self.prevCPU=cpu;self.prevWall=now;
 task_vm_info_data_t ti={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&ti,&count);double mem=ti.phys_footprint/1048576.;
 double fps=[m[@"presented"] doubleValue]/MAX(1,elapsed);
 int gpu=-1;io_iterator_t it=0;if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&it)==KERN_SUCCESS){io_service_t svc;while((svc=IOIteratorNext(it))){CFTypeRef v=IORegistryEntryCreateCFProperty(svc,CFSTR("PerformanceStatistics"),NULL,0);if(v){NSDictionary *stats=CFBridgingRelease(v);NSNumber *d=stats[@"Device Utilization %"];if(d)gpu=MAX(gpu,d.intValue);}IOObjectRelease(svc);}IOObjectRelease(it);}
 self.stats.stringValue=[NSString stringWithFormat:@"Presented %.1f FPS | FG %.1f ms | pair p95 %.1f ms | gap p95 %.1f ms | CPU %.0f%% | GPU %d%% | RAM %.0f MiB | source skips %ld | dropped %@",fps,[self percentile:self.fgTimes q:.5],[self percentile:self.totalTimes q:.95],[m[@"gapP95Ms"] doubleValue],pct,gpu,mem,self.sourceSkipped,m[@"superseded"]];
 NSMutableDictionary *row=[m mutableCopy];row[@"elapsed"]=@(elapsed);row[@"sourceSkipped"]=@(self.sourceSkipped);row[@"pairs"]=@(self.produced);row[@"fgMedianMs"]=@([self percentile:self.fgTimes q:.5]);row[@"pairP95Ms"]=@([self percentile:self.totalTimes q:.95]);row[@"scaleGPUMedianMs"]=@([self percentile:self.gpuTimes q:.5]);row[@"cpuPercentOneCore"]=@(pct);row[@"memoryMiB"]=@(mem);row[@"interpolationErrors"]=@(self.errors);row[@"systemGPUPercent"]=@(gpu);row[@"playoutDelayMs"]=@(self.playoutDelay*1000);
 NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop/MetalCadence/metrics.jsonl"]];[file seekToEndOfFile];[file writeData:data];[file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];[file closeFile];
}
-(void)applicationDidFinishLaunching:(NSNotification*)notification {
 self.activity=[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated reason:@"Interactive frame generation benchmark"];self.dev=MTLCreateSystemDefaultDevice();self.queue=[self.dev newCommandQueue];self.displayQ=[self.dev newCommandQueue];NSError *err=nil;
 id<MTLLibrary> lib=[self.dev newLibraryWithSource:shader options:nil error:&err];if(!lib){NSLog(@"shader %@",err);[NSApp terminate:nil];return;}
 self.gen=[self.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"generate"] error:&err];self.conv=[self.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"convert"] error:&err];
 MTLRenderPipelineDescriptor *rd=[MTLRenderPipelineDescriptor new];rd.vertexFunction=[lib newFunctionWithName:@"vert"];rd.fragmentFunction=[lib newFunctionWithName:@"frag"];rd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;self.render=[self.dev newRenderPipelineStateWithDescriptor:rd error:&err];
 MTLFXSpatialScalerDescriptor *sd=[MTLFXSpatialScalerDescriptor new];sd.inputWidth=W;sd.inputHeight=H;sd.outputWidth=OW;sd.outputHeight=OH;sd.colorTextureFormat=MTLPixelFormatRGBA8Unorm;sd.outputTextureFormat=MTLPixelFormatRGBA8Unorm;sd.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;self.scaler=[sd newSpatialScalerWithDevice:self.dev];
 self.config=[[VTLowLatencyFrameInterpolationConfiguration alloc]initWithFrameWidth:W frameHeight:H numberOfInterpolatedFrames:1];self.processor=[VTFrameProcessor new];if(![self.processor startSessionWithConfiguration:self.config error:&err]||!self.scaler||!self.gen||!self.conv||!self.render){NSLog(@"setup %@",err);[NSApp terminate:nil];return;}CVMetalTextureCacheCreate(NULL,NULL,self.dev,NULL,&_cache);
 NSString *asset=[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop/FrameLab/test.nv12"];self.raw=[NSData dataWithContentsOfFile:asset options:0 error:nil];self.rawCount=self.raw.length/(W*H*3/2);self.rawMode=self.rawCount>0;self.sourceRequested=self.rawMode;self.assetName=self.rawCount?@"60 FPS video asset":@"Procedural driving stress scene";
 self.lastFrameID=-1;self.presentGaps=[NSMutableArray new];self.fgTimes=[NSMutableArray new];self.scaleTimes=[NSMutableArray new];self.totalTimes=[NSMutableArray new];self.gpuTimes=[NSMutableArray new];self.quality=[NSMutableArray new];self.baselineQuality=[NSMutableArray new];self.worker=dispatch_queue_create("metalcadence.processing",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1440,860) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];self.window.title=@"MetalCadence | FrameLab direct Metal";self.window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;[self.window center];[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidChangeScreen:) name:NSWindowDidChangeScreenNotification object:self.window];
 NSView *root=self.window.contentView;self.view=[[MTKView alloc]initWithFrame:NSMakeRect(0,60,1440,800) device:self.dev];self.view.colorPixelFormat=MTLPixelFormatBGRA8Unorm;self.view.preferredFramesPerSecond=60;((CAMetalLayer*)self.view.layer).maximumDrawableCount=3;self.view.paused=YES;self.view.enableSetNeedsDisplay=NO;self.view.delegate=nil;self.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[root addSubview:self.view];
 self.modes=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(12,30,260,26) pullsDown:NO];[self.modes addItemsWithTitles:@[@"Compare: 30 FPS | interpolated 60 FPS",@"Interpolated 60 FPS (full)",@"Ground truth 60 FPS (full)",@"Native 30 FPS (full)",@"Compare: generated | ground truth",@"Error heatmap (midpoint)"]];[self.modes selectItemAtIndex:1];self.displayMode=1;self.modes.target=self;self.modes.action=@selector(change:);[root addSubview:self.modes];
 self.status=[NSTextField labelWithString:[NSString stringWithFormat:@"%@ | %@ | 1080p30 → 1440p60 | four scaled frames per pair",self.dev.name,self.assetName]];self.sources=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(280,30,240,26) pullsDown:NO];[self.sources addItemsWithTitles:@[@"60 FPS video (Big Buck Bunny)",@"Procedural driving scene"]];self.sources.target=self;self.sources.action=@selector(changeSource:);[root addSubview:self.sources];self.playoutDelay=.040;self.latencyMenu=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(535,30,150,26) pullsDown:NO];[self.latencyMenu addItemsWithTitles:@[@"40 ms playout",@"60 ms playout",@"80 ms playout"]];self.latencyMenu.target=self;self.latencyMenu.action=@selector(changeLatency:);[root addSubview:self.latencyMenu];self.status.frame=NSMakeRect(700,33,725,22);self.status.autoresizingMask=NSViewWidthSizable;[root addSubview:self.status];
 self.stats=[NSTextField labelWithString:@"Starting native GPU benchmark…"];self.stats.font=[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];self.stats.frame=NSMakeRect(12,6,1416,22);self.stats.autoresizingMask=NSViewWidthSizable;[root addSubview:self.stats];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 [@"" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop/MetalCadence/metrics.jsonl"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
 __weak Lab *weak=self;
 self.scheduler=[[MCDisplayScheduler alloc]initWithLayer:(CAMetalLayer*)self.view.layer device:self.dev capacity:8 maxInFlight:2 encode:^(id<MTLCommandBuffer> cb,id<CAMetalDrawable> d,MCFrame *frame){
 Lab *l=weak;if(!l)return;NSArray *payload=frame.payload;Pair *p=payload[0];int ph=[payload[1] intValue],mode=(int)l.displayMode;
 MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
 id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:l.render];[e setFragmentTexture:p.previous atIndex:0];[e setFragmentTexture:ph?p.mid:p.previous atIndex:1];[e setFragmentTexture:ph?(p.reference?:p.mid):p.previous atIndex:2];float aspect=(float)d.texture.width/d.texture.height;[e setFragmentBytes:&mode length:sizeof(mode) atIndex:0];[e setFragmentBytes:&aspect length:sizeof(aspect) atIndex:1];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];
 }];
 self.origin=CACurrentMediaTime();self.lastSource=-1;[self.scheduler startWithRefreshRate:self.window.screen.maximumFramesPerSecond?:60];
 self.producerThread=[[NSThread alloc]initWithBlock:^{pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);mach_timebase_info_data_t tb;mach_timebase_info(&tb);uint64_t base=mach_absolute_time();double ticksPerSecond=1e9*tb.denom/tb.numer;long last=-1;while(!NSThread.currentThread.cancelled){@autoreleasepool{double elapsed=CACurrentMediaTime()-self.origin;long n=MAX(last+1,(long)floor(elapsed*30+.15));uint64_t deadline=base+(uint64_t)(n*ticksPerSecond/30.);mach_wait_until(deadline);[self tick];last=n;}}}];self.producerThread.qualityOfService=NSQualityOfServiceUserInteractive;self.producerThread.name=@"MetalCadence Capture Clock";[self.producerThread start];
 self.reportTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());dispatch_source_set_timer(self.reportTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,10000000);dispatch_source_set_event_handler(self.reportTimer,^{[self report];});dispatch_resume(self.reportTimer);

}
-(void)windowDidChangeScreen:(NSNotification*)n{[self.scheduler startWithRefreshRate:self.window.screen.maximumFramesPerSecond?:60];}
-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender{return YES;}
@end
int main(int argc,const char**argv){@autoreleasepool{NSApplication *a=[NSApplication sharedApplication];static Lab *l;l=[Lab new];a.delegate=l;[a setActivationPolicy:NSApplicationActivationPolicyRegular];[a run];}return 0;}

