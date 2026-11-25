#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "MetalCadence.h"
#include <assert.h>
static CVPixelBufferRef sample(int value){
 CVPixelBufferRef b=NULL;NSDictionary *attrs=@{(id)kCVPixelBufferMetalCompatibilityKey:@YES,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
 assert(CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&b)==0);
 CVPixelBufferLockBaseAddress(b,0);for(int p=0;p<2;p++)memset(CVPixelBufferGetBaseAddressOfPlane(b,p),p?128:value,CVPixelBufferGetBytesPerRowOfPlane(b,p)*CVPixelBufferGetHeightOfPlane(b,p));CVPixelBufferUnlockBaseAddress(b,0);return b;
}
int main(){@autoreleasepool{
 if(@available(macOS 26.0,*)){
 MCVideoConfiguration *c=[MCVideoConfiguration new];assert(c.multiplier==2);MCVideoConfiguration *copy=[c copy];copy.multiplier=4;assert(c.multiplier==2);
 c.interpolationBackend=MCInterpolationBackendLinearBlend;c.adaptiveMultiplier=YES;c.duplicateFingerprintMethod=MCDuplicateFingerprintFNV;
 MCVideoConfiguration *all=[c copy];
 assert(all.interpolationBackend==MCInterpolationBackendLinearBlend);
 assert(all.adaptiveMultiplier==YES);
 assert(all.duplicateFingerprintMethod==MCDuplicateFingerprintFNV);
 c.interpolationBackend=MCInterpolationBackendVideoToolbox;c.adaptiveMultiplier=NO;c.duplicateFingerprintMethod=MCDuplicateFingerprintNEON;
 c.inputWidth=1279;NSError *e=nil;assert(![[MCVideoEngine alloc]initWithConfiguration:c layer:[CAMetalLayer layer] error:&e]&&e);
 c.inputWidth=1280;c.inputHeight=720;c.outputWidth=1920;c.outputHeight=1080;c.audioEnabled=NO;
 MCVideoEngine *engine=[[MCVideoEngine alloc]initWithConfiguration:c layer:[CAMetalLayer layer] error:&e];assert(engine);assert([engine startWithRefreshRate:60 error:&e]);
 CVPixelBufferRef a=sample(64),b=sample(100);double now=CACurrentMediaTime();assert([engine submitVideo:a hostTime:now]);assert([engine submitVideo:a hostTime:now+.0167]);assert([engine submitVideo:b hostTime:now+.0333]);assert(![engine submitVideo:b hostTime:now+.020]);assert(![engine submitVideo:NULL hostTime:now+.04]);
 CVPixelBufferRelease(a);CVPixelBufferRelease(b);
 NSDictionary *m=nil;for(int attempt=0;attempt<200;attempt++){[NSThread sleepForTimeInterval:.01];m=[engine metrics];if([m[@"processed"] longValue]>=1)break;}NSLog(@"SDK metrics processed=%@ received=%@ duplicates=%@ collisions=%@ ingressDrops=%@ errors=%@ VT=%@ peak=%@ sent=%@",m[@"processed"],m[@"received"],m[@"duplicates"],m[@"duplicateHashCollisions"],m[@"ingressDrops"],m[@"gpuErrors"],m[@"interpolationErrors"],m[@"peakBatches"],m[@"scheduledFrames"]);assert([m[@"duplicates"] longValue]==1);assert([m[@"invalid"] longValue]==2);assert([m[@"received"] longValue]==4);assert([m[@"processed"] longValue]>=1);assert([m[@"interpolationErrors"] longValue]==0);assert([m[@"gpuErrors"] longValue]==0);
 [engine stop];assert(!engine.running);assert([engine startWithRefreshRate:60 error:&e]);[engine stop];
 MCVideoConfiguration *raw=[MCVideoConfiguration new];raw.inputWidth=1280;raw.inputHeight=720;raw.outputWidth=1920;raw.outputHeight=1080;raw.multiplier=4;raw.audioEnabled=NO;raw.presentation=MCVideoPresentationOriginal;
 MCVideoEngine *source=[[MCVideoEngine alloc]initWithConfiguration:raw layer:[CAMetalLayer layer] error:&e];assert([source startWithRefreshRate:120 error:&e]);double rawBase=CACurrentMediaTime();for(int i=0;i<6;i++){CVPixelBufferRef pb=sample(80+i);assert([source submitVideo:pb hostTime:rawBase+i*.0333333]);CVPixelBufferRelease(pb);[NSThread sleepForTimeInterval:.012];}
 for(int i=0;i<200;i++){[NSThread sleepForTimeInterval:.01];if([[source metrics][@"processed"] integerValue]>=6)break;}NSDictionary *rawMetrics=[source metrics];assert([rawMetrics[@"processed"] integerValue]>=6);assert([rawMetrics[@"scheduledFrames"] integerValue]==[rawMetrics[@"processed"] integerValue]);[source stop];
 MCVideoConfiguration *blend=[MCVideoConfiguration new];blend.inputWidth=1280;blend.inputHeight=720;blend.outputWidth=1920;blend.outputHeight=1080;blend.multiplier=4;blend.interpolationBackend=MCInterpolationBackendLinearBlend;blend.audioEnabled=NO;
 MCVideoEngine *soft=[[MCVideoEngine alloc]initWithConfiguration:blend layer:[CAMetalLayer layer] error:&e];assert([soft startWithRefreshRate:120 error:&e]);double blendBase=CACurrentMediaTime();for(int i=0;i<4;i++){CVPixelBufferRef pb=sample(45+i*15);assert([soft submitVideo:pb hostTime:blendBase+i*.0333333]);CVPixelBufferRelease(pb);[NSThread sleepForTimeInterval:.030];}
 for(int i=0;i<200;i++){[NSThread sleepForTimeInterval:.01];if([[soft metrics][@"processed"] integerValue]>=3)break;}NSDictionary *bm=[soft metrics];assert([bm[@"processed"] integerValue]>=3);assert([bm[@"scheduledFrames"] integerValue]>=12);assert([bm[@"gpuErrors"] integerValue]==0);[soft stop];
 MCVideoConfiguration *dedup=[MCVideoConfiguration new];dedup.inputWidth=1280;dedup.inputHeight=720;dedup.outputWidth=1920;dedup.outputHeight=1080;dedup.multiplier=1;dedup.audioEnabled=NO;dedup.duplicateFingerprintMethod=MCDuplicateFingerprintNEON;
 MCVideoEngine *verifier=[[MCVideoEngine alloc]initWithConfiguration:dedup layer:[CAMetalLayer layer] error:&e];assert([verifier startWithRefreshRate:60 error:&e]);CVPixelBufferRef same=sample(82),altered=sample(82);CVPixelBufferLockBaseAddress(altered,0);uint8_t *pixels=CVPixelBufferGetBaseAddressOfPlane(altered,0);pixels[CVPixelBufferGetBytesPerRowOfPlane(altered,0)+1]^=1;CVPixelBufferUnlockBaseAddress(altered,0);double verifyBase=CACurrentMediaTime();assert([verifier submitVideo:same hostTime:verifyBase]);assert([verifier submitVideo:same hostTime:verifyBase+.0167]);assert([verifier submitVideo:altered hostTime:verifyBase+.0334]);NSDictionary *dm=[verifier metrics];assert([dm[@"duplicates"] integerValue]==1);assert([dm[@"duplicateHashCollisions"] integerValue]>=1);CVPixelBufferRelease(same);CVPixelBufferRelease(altered);[verifier stop];
 puts("SDK integration: configuration, validation, duplicate detection, real GPU interpolation, lifecycle passed");
 }else{puts("SDK integration requires macOS 26+");return 2;}
 }return 0;}
