#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "MetalCadence.h"
#import "VirtualCapture.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <IOKit/IOKitLib.h>
@interface SDKDemo:NSObject<NSApplicationDelegate,NSWindowDelegate>
@property NSWindow *window;
@property MTKView *view;
@property NSTextField *stats,*details;
@property NSPopUpButton *mode,*rate;
@property NSButton *mute;
@property (atomic) MCVideoEngine *engine;
@property NSTask *simulator;
@property NSThread *reader;
@property NSTimer *reportTimer;
@property CVPixelBufferPoolRef inputPool;
@property(atomic) BOOL stopping;
@property(atomic) long packets,transportDrops,ringOverruns,unstable,poolDrops;
@property double lastElapsed,lastCPU;
@property long lastPresented;
@property NSString *base,*logPath;
@property NSInteger refresh;
@end
@implementation SDKDemo
-(void)launchEngine:(NSInteger)mult{
 MCVideoConfiguration *c=[MCVideoConfiguration new];c.multiplier=mult;c.presentation=MCVideoPresentationCompare;c.adaptiveLatency=YES;c.audioEnabled=YES;
 NSError *e=nil;self.engine=[[MCVideoEngine alloc]initWithConfiguration:c layer:(CAMetalLayer*)self.view.layer error:&e];self.engine.muted=self.mute.state==NSControlStateValueOn;
 self.refresh=self.window.screen.maximumFramesPerSecond?:60;
 if(!self.engine||![self.engine startWithRefreshRate:self.refresh error:&e]){self.stats.stringValue=e.localizedDescription?:@"Engine unavailable";return;}
 self.lastElapsed=0;self.lastPresented=0;self.lastCPU=0;
}
-(void)readLoop{
 NSString *path=[self.base stringByAppendingPathComponent:@"capture.ring"];int fd=-1;VCRing *ring=MAP_FAILED;
 while(!self.stopping){fd=open(path.fileSystemRepresentation,O_RDONLY);struct stat st;if(fd>=0&&fstat(fd,&st)==0&&st.st_size==sizeof(VCRing)){ring=mmap(NULL,sizeof(VCRing),PROT_READ,MAP_SHARED,fd,0);if(ring!=MAP_FAILED&&ring->magic==VC_MAGIC)break;if(ring!=MAP_FAILED)munmap(ring,sizeof(VCRing));}if(fd>=0)close(fd);usleep(10000);}
 if(ring==MAP_FAILED)return;uint64_t next=1;unsigned char *data=malloc(VC_BYTES);float pcm[VC_AUDIO*2];
 while(!self.stopping){@autoreleasepool{uint64_t latest=atomic_load_explicit(&ring->latest,memory_order_acquire);if(latest<next){usleep(500);continue;}if(latest-next>=VC_SLOTS){self.ringOverruns+=latest-next-VC_SLOTS+1;next=latest-VC_SLOTS+1;}VCSlot *s=&ring->slots[next%VC_SLOTS];uint64_t stamp=atomic_load_explicit(&s->stamp,memory_order_acquire);if(stamp!=next*2){self.transportDrops++;next++;continue;}double pts=s->pts;memcpy(data,s->pixels,VC_BYTES);memcpy(pcm,s->pcm,sizeof(pcm));atomic_thread_fence(memory_order_seq_cst);if(atomic_load_explicit(&s->stamp,memory_order_acquire)!=stamp){self.unstable++;next++;continue;}next++;self.packets++;
 MCVideoEngine *engine=self.engine;[engine submitAudio:pcm frameCount:VC_AUDIO hostTime:pts];
 CVPixelBufferRef pb=NULL;NSDictionary *limit=@{(id)kCVPixelBufferPoolAllocationThresholdKey:@12};if(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,self.inputPool,(__bridge CFDictionaryRef)limit,&pb)!=kCVReturnSuccess){self.poolDrops++;continue;}CVPixelBufferLockBaseAddress(pb,0);for(int plane=0;plane<2;plane++){uint8_t *d=CVPixelBufferGetBaseAddressOfPlane(pb,plane);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pb,plane);const uint8_t *src=data+(plane?VC_W*VC_H:0);for(int y=0;y<(plane?VC_H/2:VC_H);y++)memcpy(d+y*stride,src+y*VC_W,VC_W);}CVPixelBufferUnlockBaseAddress(pb,0);[engine submitVideo:pb hostTime:pts];CVPixelBufferRelease(pb);
 }}
 free(data);munmap(ring,sizeof(VCRing));close(fd);
}
-(void)startSimulator{
 NSString *path=[self.base stringByAppendingPathComponent:@"capture.ring"];unlink(path.fileSystemRepresentation);self.simulator=[NSTask new];self.simulator.executableURL=[NSURL fileURLWithPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/MacOS/VirtualCapture"]];NSMutableArray *args=[NSMutableArray new];for(NSString *a in NSProcessInfo.processInfo.arguments)if([a isEqual:@"--source60"]||[a hasPrefix:@"--seed="]) [args addObject:a];self.simulator.arguments=args;self.simulator.standardOutput=[NSFileHandle fileHandleWithNullDevice];self.simulator.standardError=[NSFileHandle fileHandleWithNullDevice];NSError *e=nil;if(![self.simulator launchAndReturnError:&e]){self.stats.stringValue=e.localizedDescription;return;}self.reader=[[NSThread alloc]initWithBlock:^{[self readLoop];}];self.reader.qualityOfService=NSQualityOfServiceUserInteractive;[self.reader start];
}
-(void)changeMode:(id)sender{self.engine.presentation=(MCVideoPresentation)self.mode.indexOfSelectedItem;}
-(void)changeMute:(id)sender{self.engine.muted=self.mute.state==NSControlStateValueOn;}
-(void)changeRate:(id)sender{[self.engine stop];[self launchEngine:self.rate.indexOfSelectedItem==0?2:4];[self changeMode:nil];}
-(void)windowDidChangeScreen:(NSNotification*)n{self.refresh=self.window.screen.maximumFramesPerSecond?:60;[self.engine updateRefreshRate:self.refresh];}
-(void)report{
 NSInteger hz=self.window.screen.maximumFramesPerSecond?:60;if(hz!=self.refresh){self.refresh=hz;[self.engine updateRefreshRate:hz];}
 NSMutableDictionary *m=[[self.engine metrics] mutableCopy];if(!m)return;double elapsed=[m[@"elapsed"] doubleValue],cpu=[m[@"cpuSeconds"] doubleValue];long presented=[m[@"presented"] longValue];double delta=elapsed-self.lastElapsed;double fps=delta>0?(presented-self.lastPresented)/delta:0,cpuPct=self.lastElapsed&&delta>0?(cpu-self.lastCPU)/delta*100:0;self.lastElapsed=elapsed;self.lastCPU=cpu;self.lastPresented=presented;
 int gpu=-1;io_iterator_t it=0;if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&it)==KERN_SUCCESS){io_service_t svc;while((svc=IOIteratorNext(it))){CFTypeRef v=IORegistryEntryCreateCFProperty(svc,CFSTR("PerformanceStatistics"),NULL,0);if(v){NSDictionary *d=CFBridgingRelease(v);NSNumber *n=d[@"Device Utilization %"];if(n)gpu=MAX(gpu,n.intValue);}IOObjectRelease(svc);}IOObjectRelease(it);}
 m[@"rollingFPS"]=@(fps);m[@"cpuPercentOneCore"]=@(cpuPct);m[@"systemGPUPercent"]=@(gpu);m[@"capturePackets"]=@(self.packets);m[@"transportDrops"]=@(self.transportDrops);m[@"ringOverruns"]=@(self.ringOverruns);m[@"unstable"]=@(self.unstable);m[@"capturePoolDrops"]=@(self.poolDrops);m[@"multiplier"]=@(self.engine.configuration.multiplier);
 self.stats.stringValue=[NSString stringWithFormat:@"%.1f FPS   •   playout %.1f ms   •   P95 %.1f ms   •   P99 %.1f ms   •   GPU %d%%   •   CPU %.0f%%   •   RAM %.0f MiB",fps,[m[@"playoutDelayMs"] doubleValue],[m[@"gapP95Ms"] doubleValue],[m[@"gapP99Ms"] doubleValue],gpu,cpuPct,[m[@"memoryMiB"] doubleValue]];
 self.details.stringValue=[NSString stringWithFormat:@"Capture %@  /  duplicates %@  /  processed %@  /  audio %@  /  GPU errors %@  /  texture reuse %@",m[@"received"],m[@"duplicates"],m[@"processed"],m[@"audioRendered"],m[@"gpuErrors"],m[@"textureReuses"]];
 NSData *line=[NSJSONSerialization dataWithJSONObject:m options:NSJSONWritingSortedKeys error:nil];NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:self.logPath];[f seekToEndOfFile];[f writeData:line];[f writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];[f closeFile];
}
-(void)applicationDidFinishLaunching:(NSNotification*)n{
 self.base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MetalCadence"];[[NSFileManager defaultManager]createDirectoryAtPath:self.base withIntermediateDirectories:YES attributes:nil error:nil];self.logPath=[self.base stringByAppendingPathComponent:@"sdk-metrics.jsonl"];[@"" writeToFile:self.logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1300,780) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];self.window.title=@"MetalCadence SDK • Live capture benchmark";self.window.delegate=self;[self.window center];self.window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
 NSView *root=self.window.contentView;self.view=[[MTKView alloc]initWithFrame:NSMakeRect(0,88,1300,692) device:MTLCreateSystemDefaultDevice()];self.view.paused=YES;self.view.enableSetNeedsDisplay=NO;self.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[root addSubview:self.view];
 self.mode=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(12,56,230,26) pullsDown:NO];[self.mode addItemsWithTitles:@[@"Compare: native | enhanced",@"Enhanced fullscreen",@"Original (no MetalFX)",@"Upscaling only",@"Frame generation only"]];self.mode.target=self;self.mode.action=@selector(changeMode:);[root addSubview:self.mode];
 self.rate=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(250,56,150,26) pullsDown:NO];[self.rate addItemsWithTitles:@[@"2× / 60 FPS",@"4× / 120 FPS"]];self.rate.target=self;self.rate.action=@selector(changeRate:);[root addSubview:self.rate];if([NSProcessInfo.processInfo.arguments containsObject:@"--benchmark"])self.rate.enabled=NO;
 self.mute=[NSButton checkboxWithTitle:@"Mute" target:self action:@selector(changeMute:)];self.mute.frame=NSMakeRect(415,56,100,26);self.mute.state=NSControlStateValueOn;[root addSubview:self.mute];
 self.stats=[NSTextField labelWithString:@"Starting SDK..."];self.stats.frame=NSMakeRect(12,30,1276,22);self.stats.font=[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];self.stats.autoresizingMask=NSViewWidthSizable;[root addSubview:self.stats];
 self.details=[NSTextField labelWithString:@"Waiting for independent capture source"];self.details.frame=NSMakeRect(12,6,1276,20);self.details.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];self.details.autoresizingMask=NSViewWidthSizable;[root addSubview:self.details];
 NSDictionary *attrs=@{(id)kCVPixelBufferWidthKey:@VC_W,(id)kCVPixelBufferHeightKey:@VC_H,(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferMetalCompatibilityKey:@YES,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attrs,&_inputPool);
 [self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];BOOL four=[NSProcessInfo.processInfo.arguments containsObject:@"--4x"],one=[NSProcessInfo.processInfo.arguments containsObject:@"--1x"];[self.rate selectItemAtIndex:four?1:0];[self launchEngine:one?1:four?4:2];if(self.engine.running)[self startSimulator];self.reportTimer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(report) userInfo:nil repeats:YES];
}
-(void)applicationWillTerminate:(NSNotification*)n{self.stopping=YES;[self.reportTimer invalidate];if(self.simulator.running)[self.simulator terminate];[self.engine stop];}
-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a{return YES;}
@end
int main(){@autoreleasepool{NSApplication *a=NSApplication.sharedApplication;static SDKDemo *demo;demo=[SDKDemo new];a.delegate=demo;[a setActivationPolicy:NSApplicationActivationPolicyRegular];[a run];}return 0;}
