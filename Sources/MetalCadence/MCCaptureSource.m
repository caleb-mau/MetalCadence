#import "MetalCadence.h"
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
@interface MCCaptureSource () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property MCVideoEngine *engine;
@property AVCaptureSession *session;
@property AVCaptureVideoDataOutput *videoOutput;
@property AVCaptureAudioDataOutput *audioOutput;
@property dispatch_queue_t videoQueue,audioQueue;
@end
@implementation MCCaptureSource
+(NSArray<AVCaptureDevice*>*)videoDevices {return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal,AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices;}
-(instancetype)initWithEngine:(MCVideoEngine*)engine{if((self=[super init])){_engine=engine;_videoQueue=dispatch_queue_create("metalcadence.capture.video",DISPATCH_QUEUE_SERIAL);_audioQueue=dispatch_queue_create("metalcadence.capture.audio",DISPATCH_QUEUE_SERIAL);}return self;}
-(BOOL)startWithVideoDevice:(AVCaptureDevice*)video audioDevice:(AVCaptureDevice*)audio error:(NSError**)error{
 if(self.session)return YES;
 AVCaptureSession *s=[AVCaptureSession new];[s beginConfiguration];s.sessionPreset=AVCaptureSessionPresetHigh;
 NSError *e=nil;AVCaptureDeviceInput *v=[AVCaptureDeviceInput deviceInputWithDevice:video error:&e];if(!v||![s canAddInput:v]){[s commitConfiguration];if(error)*error=e?:[NSError errorWithDomain:@"MetalCadence.Capture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot open video device"}];return NO;}[s addInput:v];
 MCVideoConfiguration *c=self.engine.configuration;AVCaptureDeviceFormat *selected=nil;double rate=0;for(AVCaptureDeviceFormat *f in video.formats){CMVideoDimensions d=CMVideoFormatDescriptionGetDimensions(f.formatDescription);if(d.width!=c.inputWidth||d.height!=c.inputHeight)continue;for(AVFrameRateRange *r in f.videoSupportedFrameRateRanges){double hz=r.maxFrameRate>=59.9&&r.minFrameRate<=60?60:r.maxFrameRate;if(hz>rate&&hz<=60.1){selected=f;rate=hz;}}}
 if(!selected||![video lockForConfiguration:&e]){[s commitConfiguration];if(error)*error=e?:[NSError errorWithDomain:@"MetalCadence.Capture" code:2 userInfo:@{NSLocalizedDescriptionKey:@"No compatible capture format"}];return NO;}
 video.activeFormat=selected;video.activeVideoMinFrameDuration=CMTimeMakeWithSeconds(1/rate,60000);video.activeVideoMaxFrameDuration=video.activeVideoMinFrameDuration;[video unlockForConfiguration];
 AVCaptureVideoDataOutput *vo=[AVCaptureVideoDataOutput new];vo.videoSettings=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};vo.alwaysDiscardsLateVideoFrames=YES;[vo setSampleBufferDelegate:self queue:_videoQueue];if(![s canAddOutput:vo]){[s commitConfiguration];if(error)*error=[NSError errorWithDomain:@"MetalCadence.Capture" code:3 userInfo:@{NSLocalizedDescriptionKey:@"NV12 output unavailable"}];return NO;}[s addOutput:vo];self.videoOutput=vo;
 if(audio){AVCaptureDeviceInput *a=[AVCaptureDeviceInput deviceInputWithDevice:audio error:&e];if(!a||![s canAddInput:a]){[s commitConfiguration];if(error)*error=e?:[NSError errorWithDomain:@"MetalCadence.Capture" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Cannot open audio device"}];return NO;}[s addInput:a];AVCaptureAudioDataOutput *ao=[AVCaptureAudioDataOutput new];ao.audioSettings=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVSampleRateKey:@48000,AVNumberOfChannelsKey:@2,AVLinearPCMBitDepthKey:@32,AVLinearPCMIsFloatKey:@YES,AVLinearPCMIsNonInterleaved:@NO};[ao setSampleBufferDelegate:self queue:_audioQueue];if(![s canAddOutput:ao]){[s commitConfiguration];if(error)*error=[NSError errorWithDomain:@"MetalCadence.Capture" code:5 userInfo:@{NSLocalizedDescriptionKey:@"PCM output unavailable"}];return NO;}[s addOutput:ao];self.audioOutput=ao;}
 [s commitConfiguration];self.session=s;[s startRunning];return s.running;
}
-(void)stop{[self.session stopRunning];[self.videoOutput setSampleBufferDelegate:nil queue:NULL];[self.audioOutput setSampleBufferDelegate:nil queue:NULL];self.session=nil;self.videoOutput=nil;self.audioOutput=nil;}
-(void)captureOutput:(AVCaptureOutput*)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection*)connection{
 CMTime t=CMSampleBufferGetPresentationTimeStamp(sample);CMClockRef clock=self.session.synchronizationClock;if(clock)t=CMSyncConvertTime(t,clock,CMClockGetHostTimeClock());double pts=CMTimeGetSeconds(t);if(!isfinite(pts))return;
 if(output==self.videoOutput){CVPixelBufferRef b=CMSampleBufferGetImageBuffer(sample);if(b)[self.engine submitVideo:b hostTime:pts];return;}
 const AudioStreamBasicDescription *asbd=CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));if(!asbd||asbd->mSampleRate!=48000||asbd->mChannelsPerFrame!=2||!(asbd->mFormatFlags&kAudioFormatFlagIsFloat)||(asbd->mFormatFlags&kAudioFormatFlagIsNonInterleaved)||asbd->mBitsPerChannel!=32)return;
 CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);NSUInteger count=CMSampleBufferGetNumSamples(sample);if(!block||count>4800||!count)return;float pcm[9600];if(CMBlockBufferCopyDataBytes(block,0,count*2*sizeof(float),pcm)==kCMBlockBufferNoErr)[self.engine submitAudio:pcm frameCount:count hostTime:pts];
}
@end
