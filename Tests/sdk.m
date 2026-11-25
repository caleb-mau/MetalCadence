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
 c.inputWidth=1279;NSError *e=nil;assert(![[MCVideoEngine alloc]initWithConfiguration:c layer:[CAMetalLayer layer] error:&e]&&e);
 c.inputWidth=1280;c.inputHeight=720;c.outputWidth=1920;c.outputHeight=1080;c.audioEnabled=NO;
 MCVideoEngine *engine=[[MCVideoEngine alloc]initWithConfiguration:c layer:[CAMetalLayer layer] error:&e];assert(engine);assert([engine startWithRefreshRate:60 error:&e]);
 CVPixelBufferRef a=sample(64),b=sample(100);double now=CACurrentMediaTime();assert([engine submitVideo:a hostTime:now]);assert([engine submitVideo:a hostTime:now+.0167]);assert([engine submitVideo:b hostTime:now+.0333]);assert(![engine submitVideo:b hostTime:now+.020]);assert(![engine submitVideo:NULL hostTime:now+.04]);
 CVPixelBufferRelease(a);CVPixelBufferRelease(b);
 [NSThread sleepForTimeInterval:.15];NSDictionary *m=[engine metrics];assert([m[@"duplicates"] longValue]==1);assert([m[@"invalid"] longValue]==2);assert([m[@"received"] longValue]==4);assert([m[@"processed"] longValue]==1);assert([m[@"interpolationErrors"] longValue]==0);assert([m[@"gpuErrors"] longValue]==0);
 [engine stop];assert(!engine.running);assert([engine startWithRefreshRate:60 error:&e]);[engine stop];puts("SDK integration: configuration, validation, duplicate detection, real GPU interpolation, lifecycle passed");
 }else{puts("SDK integration requires macOS 26+");return 2;}
 }return 0;}
