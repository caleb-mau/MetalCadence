#import "MetalCadence.h"
#import <os/lock.h>
#import <math.h>
NSInteger MCSelectDueFrame(const double *pts, NSUInteger count, double target, double lateLimit){NSInteger last=-1;for(NSUInteger i=0;i<count&&pts[i]<=target+.001;i++){last=(NSInteger)i;if(target-pts[i]<=lateLimit)return (NSInteger)i;}return last;}
@implementation MCFrame
-(instancetype)initWithID:(int64_t)i pts:(CFTimeInterval)p payload:(id)payload{if((self=[super init])){_identifier=i;_pts=p;_ready=CACurrentMediaTime();_payload=payload;}return self;}
@end
@interface MCDisplayScheduler () {
 os_unfair_lock _lock;
 NSMutableArray<MCFrame*> *_queue;
 CAMetalDisplayLink *_link;
 CAMetalLayer *_layer;
 id<MTLCommandQueue> _commandQueue;
 MCEncodeBlock _encode;
 NSInteger _inFlight;
 int64_t _lastID;
 BOOL _running;
 uint64_t _callbacks,_submitted,_presented,_overflow,_superseded,_skipped,_busy,_errors,_missedDeadline,_noFrame;
 double _lastPresented,_gapSum,_gpuSum,_readyAgeSum,_ptsErrorSum;
 NSMutableArray<NSNumber*> *_gaps;
}
@end
@implementation MCDisplayScheduler
-(instancetype)initWithLayer:(CAMetalLayer*)layer device:(id<MTLDevice>)device capacity:(NSUInteger)capacity maxInFlight:(NSUInteger)maxInFlight encode:(MCEncodeBlock)encode{
 if((self=[super init])){_lock=OS_UNFAIR_LOCK_INIT;_layer=layer;_commandQueue=[device newCommandQueue];_capacity=MAX(2,capacity);_maxInFlight=MAX(1,MIN(2,maxInFlight));_maxFrameLateness=.025;_queue=[NSMutableArray new];_gaps=[NSMutableArray new];_lastID=INT64_MIN;_encode=[encode copy];}return self;
}
-(void)startWithRefreshRate:(float)hz{NSAssert(NSThread.isMainThread,@"start on main thread");[self stop];os_unfair_lock_lock(&_lock);_running=YES;os_unfair_lock_unlock(&_lock);_layer.displaySyncEnabled=YES;_layer.maximumDrawableCount=3;_link=[[CAMetalDisplayLink alloc]initWithMetalLayer:_layer];_link.delegate=self;_link.preferredFrameLatency=1;float rate=MAX(30,hz);_link.preferredFrameRateRange=CAFrameRateRangeMake(rate,rate,rate);[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];}
-(void)stop{NSAssert(NSThread.isMainThread,@"stop on main thread");[_link invalidate];_link=nil;os_unfair_lock_lock(&_lock);_running=NO;[_queue removeAllObjects];os_unfair_lock_unlock(&_lock);}
-(BOOL)submit:(MCFrame*)f{if(!isfinite(f.pts))return NO;os_unfair_lock_lock(&_lock);if(!_running||f.identifier<=_lastID){os_unfair_lock_unlock(&_lock);return NO;}for(MCFrame *old in _queue)if(old.identifier==f.identifier){os_unfair_lock_unlock(&_lock);return NO;}NSUInteger i=0;while(i<_queue.count&&_queue[i].pts<=f.pts)i++;[_queue insertObject:f atIndex:i];if(_queue.count>_capacity){[_queue removeObjectAtIndex:0];_overflow++;}os_unfair_lock_unlock(&_lock);return YES;}
-(void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)update{
 @autoreleasepool{
 double now=CACurrentMediaTime(),target=update.targetPresentationTimestamp;
 os_unfair_lock_lock(&_lock);_callbacks++;if(!_running||_inFlight>=_maxInFlight){_busy++;os_unfair_lock_unlock(&_lock);return;}
 if(!update.drawable){_noFrame++;os_unfair_lock_unlock(&_lock);return;}
 double pts[_queue.count?:1];for(NSUInteger i=0;i<_queue.count;i++)pts[i]=_queue[i].pts;NSInteger selected=MCSelectDueFrame(pts,_queue.count,target,self.maxFrameLateness);MCFrame *f=selected>=0?_queue[selected]:nil;NSUInteger n=selected>=0?(NSUInteger)selected+1:0;
 if(!f){_skipped++;os_unfair_lock_unlock(&_lock);return;}
 [_queue removeObjectsInRange:NSMakeRange(0,n)];if(n>1)_superseded+=n-1;
 if(f.identifier<=_lastID){_superseded++;os_unfair_lock_unlock(&_lock);return;}
 _lastID=f.identifier;_inFlight++;_submitted++;if(now>update.targetTimestamp)_missedDeadline++;os_unfair_lock_unlock(&_lock);
 id<CAMetalDrawable> d=update.drawable;id<MTLCommandBuffer> cb=[_commandQueue commandBuffer];if(!cb){os_unfair_lock_lock(&_lock);_inFlight--;_errors++;os_unfair_lock_unlock(&_lock);return;}
 _encode(cb,d,f);
 [d addPresentedHandler:^(id<MTLDrawable> drawable){double t=drawable.presentedTime;os_unfair_lock_lock(&self->_lock);if(t>0){self->_presented++;self->_readyAgeSum+=MAX(0,t-f.ready);self->_ptsErrorSum+=t-f.pts;if(self->_lastPresented>0&&t>self->_lastPresented){double g=(t-self->_lastPresented)*1000;self->_gapSum+=g;[self->_gaps addObject:@(g)];if(self->_gaps.count>600)[self->_gaps removeObjectAtIndex:0];}self->_lastPresented=MAX(t,self->_lastPresented);}os_unfair_lock_unlock(&self->_lock);}];
 [cb addCompletedHandler:^(id<MTLCommandBuffer> c){os_unfair_lock_lock(&self->_lock);self->_inFlight--;self->_gpuSum+=MAX(0,c.GPUEndTime-c.GPUStartTime);if(c.status==MTLCommandBufferStatusError)self->_errors++;os_unfair_lock_unlock(&self->_lock);}];
 [cb commit];[d present];
 }
}
-(NSDictionary*)metrics{os_unfair_lock_lock(&_lock);NSArray *g=[_gaps copy];NSDictionary *base=@{@"callbacks":@(_callbacks),@"submitted":@(_submitted),@"presented":@(_presented),@"overflow":@(_overflow),@"superseded":@(_superseded),@"idleRefreshes":@(_skipped),@"busyRefreshes":@(_busy),@"noDrawable":@(_noFrame),@"errors":@(_errors),@"callbackDeadlineMisses":@(_missedDeadline),@"queued":@(_queue.count),@"inFlight":@(_inFlight),@"displayGPUms":@(_gpuSum*1000/MAX(1,_submitted)),@"readyToPresentMs":@(_readyAgeSum*1000/MAX(1,_presented)),@"ptsErrorMs":@(_ptsErrorSum*1000/MAX(1,_presented))};os_unfair_lock_unlock(&_lock);NSMutableDictionary *m=[base mutableCopy];NSArray *sorted=[g sortedArrayUsingSelector:@selector(compare:)];m[@"gapP95Ms"]=sorted.count?sorted[(NSUInteger)floor((sorted.count-1)*.95)]:@0;return m;}
@end
