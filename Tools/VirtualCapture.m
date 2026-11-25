#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
#import "VirtualCapture.h"
#import "SceneShader.h"
@interface Replay : NSObject
@property AVURLAsset *asset;
@property BOOL fullRate;
@property AVAssetReader *reader;
@property AVAssetReaderTrackOutput *output;
-(BOOL)reset;
-(BOOL)read:(unsigned char*)bytes;
@end
@implementation Replay
-(BOOL)reset {NSError *error=nil;self.reader=[[AVAssetReader alloc]initWithAsset:self.asset error:&error];__block NSArray<AVAssetTrack*> *tracks=nil;dispatch_semaphore_t done=dispatch_semaphore_create(0);[self.asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack*> *loaded,NSError *err){tracks=loaded;dispatch_semaphore_signal(done);}];if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))!=0)return NO;AVAssetTrack *track=tracks.firstObject;if(!track||!self.reader)return NO;self.output=[[AVAssetReaderTrackOutput alloc]initWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];self.output.alwaysCopiesSampleData=NO;if(![self.reader canAddOutput:self.output])return NO;[self.reader addOutput:self.output];return [self.reader startReading];}
-(BOOL)read:(unsigned char*)bytes {CMSampleBufferRef a=[self.output copyNextSampleBuffer];if(!a){if(![self reset])return NO;a=[self.output copyNextSampleBuffer];if(!a)return NO;}CVPixelBufferRef p=CMSampleBufferGetImageBuffer(a);if(!p||CVPixelBufferGetWidth(p)!=VC_W||CVPixelBufferGetHeight(p)!=VC_H){CFRelease(a);return NO;}CVPixelBufferLockBaseAddress(p,kCVPixelBufferLock_ReadOnly);for(int plane=0;plane<2;plane++){const uint8_t *src=CVPixelBufferGetBaseAddressOfPlane(p,plane);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(p,plane);uint8_t *dst=bytes+(plane?VC_W*VC_H:0);for(int y=0;y<(plane?VC_H/2:VC_H);y++)memcpy(dst+y*VC_W,src+y*stride,VC_W);}CVPixelBufferUnlockBaseAddress(p,kCVPixelBufferLock_ReadOnly);CFRelease(a);if(!self.fullRate){CMSampleBufferRef skip=[self.output copyNextSampleBuffer];if(skip)CFRelease(skip);}return YES;}
@end
int main(int argc,const char **argv){@autoreleasepool{
 NSString *base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MetalCadence"];[[NSFileManager defaultManager]createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];NSString *runID=nil;for(NSString *arg in NSProcessInfo.processInfo.arguments){if([arg hasPrefix:@"--run-id="]){NSString *candidate=[arg substringFromIndex:9];NSCharacterSet *safe=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];if(candidate.length>0&&candidate.length<=100&&[candidate rangeOfCharacterFromSet:safe.invertedSet].location==NSNotFound)runID=candidate;}}NSString *path=[base stringByAppendingPathComponent:runID?[NSString stringWithFormat:@"capture-%@.ring",runID]:@"capture.ring"];int fd=open(path.fileSystemRepresentation,O_RDWR|O_CREAT|O_TRUNC,0600);if(fd<0||ftruncate(fd,sizeof(VCRing)))return 2;VCRing *ring=mmap(NULL,sizeof(VCRing),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(ring==MAP_FAILED)return 3;memset(ring,0,sizeof(*ring));ring->magic=VC_MAGIC;
 BOOL stress=[NSProcessInfo.processInfo.arguments containsObject:@"--3d"];BOOL fullRate=[NSProcessInfo.processInfo.arguments containsObject:@"--source60"];uint64_t seed=0;for(NSString *arg in NSProcessInfo.processInfo.arguments)if([arg hasPrefix:@"--seed="])seed=strtoull([[arg substringFromIndex:7] UTF8String],NULL,10);Replay *replay=nil;if(!stress){replay=[Replay new];replay.fullRate=fullRate;replay.asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"replay.mp4"]] options:nil];if(![replay reset]){NSLog(@"Replay unavailable; supply 1920x1080 60fps replay.mp4 in Application Support/MetalCadence or use --3d.");return 5;}}
 id<MTLDevice> dev=stress?MTLCreateSystemDefaultDevice():nil;NSError *err=nil;id<MTLLibrary> lib=stress?[dev newLibraryWithSource:shader options:nil error:&err]:nil;if(stress&&!lib){NSLog(@"shader %@",err);return 4;}id<MTLComputePipelineState> pipeline=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"generate"] error:&err];id<MTLCommandQueue> q=[dev newCommandQueue];
 MTLTextureDescriptor *yd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:VC_W height:VC_H mipmapped:NO];yd.storageMode=MTLStorageModeShared;yd.usage=MTLTextureUsageShaderWrite;id<MTLTexture> y=[dev newTextureWithDescriptor:yd];MTLTextureDescriptor *ud=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm width:VC_W/2 height:VC_H/2 mipmapped:NO];ud.storageMode=MTLStorageModeShared;ud.usage=MTLTextureUsageShaderWrite;id<MTLTexture> uv=[dev newTextureWithDescriptor:ud];
 NSData *sound=stress?nil:[NSData dataWithContentsOfFile:[base stringByAppendingPathComponent:@"replay.f32"] options:NSDataReadingMappedIfSafe error:nil];const float *samples=sound.bytes;size_t sampleFrames=sound.length/(sizeof(float)*2);NSLog(@"Replay soundtrack: %zu stereo samples (missing soundtrack produces silence)",sampleFrames);
 unsigned char *frame=malloc(VC_BYTES);mach_timebase_info_data_t tb;mach_timebase_info(&tb);double ticks=1e9*tb.denom/tb.numer;uint64_t start=mach_absolute_time();double origin=CACurrentMediaTime();uint64_t last=UINT64_MAX;double sceneOffset=arc4random_uniform(60000)/100.;
 pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED,0);
 NSLog(@"VirtualCapture: independent 1080p60 NV12, 30 unique FPS, 48k stereo, randomized jitter; ring %@",path);
 for(uint64_t i=0;;i++){@autoreleasepool{
 uint64_t target=start+(uint64_t)(i*ticks/60.);mach_wait_until(target);double pts=origin+i/60.;uint64_t content=fullRate?i:i/2;
 if(content!=last){if(!stress){uint64_t count=last==UINT64_MAX?1:content-last;for(uint64_t k=0;k<count;k++){if(![replay read:frame])return 6;}}else{float t=(float)(sceneOffset+content/30.);id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:pipeline];[e setTexture:y atIndex:0];[e setTexture:uv atIndex:1];[e setBytes:&t length:4 atIndex:0];[e dispatchThreads:MTLSizeMake(VC_W,VC_H,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];[y getBytes:frame bytesPerRow:VC_W fromRegion:MTLRegionMake2D(0,0,VC_W,VC_H) mipmapLevel:0];[uv getBytes:frame+VC_W*VC_H bytesPerRow:VC_W fromRegion:MTLRegionMake2D(0,0,VC_W/2,VC_H/2) mipmapLevel:0];}last=content;}
 uint64_t x=seed+i*0x9e3779b97f4a7c15ULL;x=(x^(x>>30))*0xbf58476d1ce4e5b9ULL;x=(x^(x>>27))*0x94d049bb133111ebULL;x^=x>>31;uint32_t r=seed?x%1000:arc4random_uniform(1000);if(r<4){atomic_fetch_add(&ring->sourceDrops,1);continue;}usleep((seed?(x>>16)%2200:arc4random_uniform(2200))+(r<17?6000:0));
 uint64_t seq=i+1;VCSlot *s=&ring->slots[seq%VC_SLOTS];atomic_store_explicit(&s->stamp,seq*2+1,memory_order_seq_cst);s->pts=pts;s->arrival=CACurrentMediaTime();s->tick=i;s->audioFrames=VC_AUDIO;memcpy(s->pixels,frame,VC_BYTES);for(int j=0;j<VC_AUDIO;j++){size_t k=sampleFrames?(i*VC_AUDIO+j)%sampleFrames:0;s->pcm[j*2]=sampleFrames?samples[k*2]:0;s->pcm[j*2+1]=sampleFrames?samples[k*2+1]:0;}
 atomic_store_explicit(&s->stamp,seq*2,memory_order_release);atomic_store_explicit(&ring->latest,seq,memory_order_release);atomic_store(&ring->heartbeat,seq);
 if(CACurrentMediaTime()-pts>.12){uint64_t skip=(uint64_t)((CACurrentMediaTime()-origin)*60)-i;if(skip>0){atomic_fetch_add(&ring->sourceDrops,skip);i+=skip;}}
 }}
}}
