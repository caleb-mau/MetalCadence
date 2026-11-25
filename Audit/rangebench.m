#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import "MetalCadence.h"
#include <assert.h>
#include <math.h>
@interface MCVideoEngine (RangeBenchmark)
-(CVPixelBufferRef)normalizeFullRange:(CVPixelBufferRef)input;
@end
static int cmp(const void *a,const void *b){double x=*(const double*)a,y=*(const double*)b;return x<y?-1:x>y?1:0;}
int main(){@autoreleasepool{
 MCVideoConfiguration *config=[MCVideoConfiguration new];config.inputWidth=1920;config.inputHeight=1080;config.outputWidth=2560;config.outputHeight=1440;config.multiplier=1;config.audioEnabled=NO;
 NSError *error=nil;MCVideoEngine *engine=[[MCVideoEngine alloc]initWithConfiguration:config layer:[CAMetalLayer layer] error:&error];assert(engine);
 NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
 CVPixelBufferRef original=NULL;assert(CVPixelBufferCreate(NULL,1920,1080,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,(__bridge CFDictionaryRef)attrs,&original)==kCVReturnSuccess);
 CVPixelBufferLockBaseAddress(original,0);
 for(int plane=0;plane<2;plane++){uint8_t *data=CVPixelBufferGetBaseAddressOfPlane(original,plane);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(original,plane),height=CVPixelBufferGetHeightOfPlane(original,plane),width=CVPixelBufferGetWidthOfPlane(original,plane)*(plane?2:1);
 for(int y=0;y<height;y++)for(int x=0;x<width;x++)data[y*stride+x]=plane?(uint8_t)(128+(x+y)%50-25):(uint8_t)((x*13+y*7)%256);}
 CVPixelBufferUnlockBaseAddress(original,0);
 const int n=150;double times[n];for(int i=0;i<n;i++){CFTimeInterval t=CACurrentMediaTime();CVPixelBufferRef out=[engine normalizeFullRange:original];times[i]=(CACurrentMediaTime()-t)*1000;assert(out&&CVPixelBufferGetPixelFormatType(out)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);CVPixelBufferRelease(out);}
 qsort(times,n,sizeof(double),cmp);
 double p50=times[(n-1)/2],p95=times[(int)((n-1)*.95)],p99=times[(int)((n-1)*.99)];
 printf("RANGEBENCH NV12 1920x1080 full-to-video normalize: N=%d P50=%.3fms P95=%.3fms P99=%.3fms throughput=%.2f GB/s (input bytes only)\n",n,p50,p95,p99,1920.*1080*1.5/(p50/1000)/1e9);
 CVPixelBufferRelease(original);return 0;
}}
