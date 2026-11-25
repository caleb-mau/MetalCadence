#import "MetalCadence.h"
#if !__has_feature(objc_arc)
#error MetalCadence requires ARC
#endif
#import <os/lock.h>
#import <math.h>
NSInteger MCSelectDueFrame(const double *pts, NSUInteger count, double target, double lateLimit) {
    NSInteger last = -1;
    for (NSUInteger i = 0; i < count && pts[i] <= target + .001; i++) {
        last = (NSInteger)i;
        if (target - pts[i] <= lateLimit)
            return (NSInteger)i;
    }
    return last;
}
@implementation MCFrame
- (instancetype)initWithID:(int64_t)i pts:(CFTimeInterval)p payload:(id)payload {
    return [self initWithID:i pts:p sourceTime:0 payload:payload];
}
- (instancetype)initWithID:(int64_t)i
                       pts:(CFTimeInterval)p
                sourceTime:(CFTimeInterval)sourceTime
                   payload:(id)payload {
    if ((self = [super init])) {
        _identifier = i;
        _pts = p;
        _sourceTime = sourceTime;
        _ready = CACurrentMediaTime();
        _payload = payload;
    }
    return self;
}
@end
@interface MCDisplayScheduler () {
    os_unfair_lock _lock;
    NSMutableArray<MCFrame *> *_queue;
    CAMetalDisplayLink *_link;
    CAMetalLayer *_layer;
    id<MTLCommandQueue> _commandQueue;
    MCEncodeBlock _encode;
    MCFrame *_held;
    NSInteger _inFlight;
    int64_t _lastID, _lastDisplayedID;
    BOOL _running;
    uint64_t _callbacks, _submitted, _presented, _overflow, _superseded, _skipped, _busy, _errors,
        _missedDeadline, _noFrame, _heldRefreshes, _freshPresented;
    double _lastPresented, _lastCallback, _gapSum, _gpuSum, _readyAgeSum, _ptsErrorSum,
        _refreshPeriod;
    NSMutableArray<NSNumber *> *_gaps, *_sourceLatencies;
}
@end
@implementation MCDisplayScheduler
- (instancetype)initWithLayer:(CAMetalLayer *)layer
                       device:(id<MTLDevice>)device
                     capacity:(NSUInteger)capacity
                  maxInFlight:(NSUInteger)maxInFlight
                       encode:(MCEncodeBlock)encode {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _layer = layer;
        _commandQueue = [device newCommandQueue];
        _capacity = MAX(2, capacity);
        _maxInFlight = MAX(1, MIN(2, maxInFlight));
        _maxFrameLateness = .025;
        _queue = [NSMutableArray new];
        _gaps = [NSMutableArray new];
        _sourceLatencies = [NSMutableArray new];
        _lastID = INT64_MIN;
        _lastDisplayedID = INT64_MIN;
        _encode = [encode copy];
    }
    return self;
}
- (void)startWithRefreshRate:(float)hz {
    NSAssert(NSThread.isMainThread, @"start on main thread");
    [_link invalidate];
    _link = nil;
    os_unfair_lock_lock(&_lock);
    _running = YES;
    _refreshPeriod = 1.0 / MAX(30, hz);
    os_unfair_lock_unlock(&_lock);
    _layer.displaySyncEnabled = YES;
    _layer.maximumDrawableCount = 3;
    _link = [[CAMetalDisplayLink alloc] initWithMetalLayer:_layer];
    _link.delegate = self;
    _link.preferredFrameLatency = 1;
    float rate = MAX(30, hz);
    _link.preferredFrameRateRange = CAFrameRateRangeMake(rate, rate, rate);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)stop {
    NSAssert(NSThread.isMainThread, @"stop on main thread");
    [_link invalidate];
    _link = nil;
    os_unfair_lock_lock(&_lock);
    _running = NO;
    [_queue removeAllObjects];
    _held = nil;
    os_unfair_lock_unlock(&_lock);
}
- (BOOL)submit:(MCFrame *)f {
    if (!isfinite(f.pts))
        return NO;
    os_unfair_lock_lock(&_lock);
    if (!_running || f.identifier <= _lastID) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    for (MCFrame *old in _queue)
        if (old.identifier == f.identifier) {
            os_unfair_lock_unlock(&_lock);
            return NO;
        }
    NSUInteger i = 0;
    while (i < _queue.count && _queue[i].pts <= f.pts)
        i++;
    [_queue insertObject:f atIndex:i];
    if (_queue.count > _capacity) {
        [_queue removeObjectAtIndex:0];
        _overflow++;
    }
    os_unfair_lock_unlock(&_lock);
    return YES;
}
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    @autoreleasepool {
        double now = CACurrentMediaTime(), target = update.targetPresentationTimestamp;
        os_unfair_lock_lock(&_lock);
        _callbacks++;
        if (!_running || _inFlight >= _maxInFlight) {
            _busy++;
            os_unfair_lock_unlock(&_lock);
            return;
        }
        if (!update.drawable) {
            _noFrame++;
            os_unfair_lock_unlock(&_lock);
            return;
        }
        double pts[_queue.count ?: 1];
        for (NSUInteger i = 0; i < _queue.count; i++)
            pts[i] = _queue[i].pts;
        NSInteger selected = MCSelectDueFrame(
            pts, _queue.count, target, MIN(self.maxFrameLateness, _refreshPeriod * 1.5));
        MCFrame *f = selected >= 0 ? _queue[selected] : nil;
        NSUInteger n = selected >= 0 ? (NSUInteger)selected + 1 : 0;
        BOOL fresh = f && f.identifier > _lastID;
        if (n) {
            [_queue removeObjectsInRange:NSMakeRange(0, n)];
            if (n > 1)
                _superseded += n - 1;
        }
        if (fresh) {
            _lastID = f.identifier;
            _held = f;
        } else {
            _skipped++;
            f = _held;
            if (f)
                _heldRefreshes++;
        }
        if (!f) {
            os_unfair_lock_unlock(&_lock);
            return;
        }
        _inFlight++;
        _submitted++;
        if (now > update.targetTimestamp)
            _missedDeadline++;
        os_unfair_lock_unlock(&_lock);
        id<CAMetalDrawable> d = update.drawable;
        id<MTLCommandBuffer> cb = [_commandQueue commandBuffer];
        if (!cb) {
            os_unfair_lock_lock(&_lock);
            _inFlight--;
            _errors++;
            os_unfair_lock_unlock(&_lock);
            return;
        }
        _encode(cb, d, f);
        [d addPresentedHandler:^(id<MTLDrawable> drawable) {
            double t = drawable.presentedTime;
            os_unfair_lock_lock(&self->_lock);
            if (t > 0) {
                self->_presented++;
                if (f.identifier > self->_lastDisplayedID) {
                    self->_lastDisplayedID = f.identifier;
                    self->_freshPresented++;
                    if (f.sourceTime > 0 && t >= f.sourceTime) {
                        [self->_sourceLatencies addObject:@((t - f.sourceTime) * 1000)];
                        if (self->_sourceLatencies.count > 600)
                            [self->_sourceLatencies removeObjectAtIndex:0];
                    }
                    self->_readyAgeSum += MAX(0, t - f.ready);
                    self->_ptsErrorSum += t - f.pts;
                    if (self->_lastPresented > 0 && t > self->_lastPresented) {
                        double g = (t - self->_lastPresented) * 1000;
                        self->_gapSum += g;
                        [self->_gaps addObject:@(g)];
                        if (self->_gaps.count > 600)
                            [self->_gaps removeObjectAtIndex:0];
                    }
                    self->_lastPresented = MAX(t, self->_lastPresented);
                }
            }
            os_unfair_lock_unlock(&self->_lock);
        }];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            (void)f.payload;
            os_unfair_lock_lock(&self->_lock);
            self->_inFlight--;
            self->_gpuSum += MAX(0, c.GPUEndTime - c.GPUStartTime);
            if (c.status == MTLCommandBufferStatusError)
                self->_errors++;
            os_unfair_lock_unlock(&self->_lock);
        }];
        [cb presentDrawable:d];
        [cb commit];
    }
}
- (NSDictionary *)pressureSnapshot {
    os_unfair_lock_lock(&_lock);
    NSDictionary *d = @{
        @"superseded" : @(_superseded),
        @"overflow" : @(_overflow),
        @"queued" : @(_queue.count),
        @"callbackDeadlineMisses" : @(_missedDeadline),
        @"callbackAgeMs" : @(_lastCallback > 0 ? (CACurrentMediaTime() - _lastCallback) * 1000 : 0)
    };
    os_unfair_lock_unlock(&_lock);
    return d;
}
- (NSDictionary *)metrics {
    os_unfair_lock_lock(&_lock);
    NSArray *g = [_gaps copy], *latencies = [_sourceLatencies copy];
    NSDictionary *base = @{
        @"callbackAgeMs" : @(_lastCallback > 0 ? (CACurrentMediaTime() - _lastCallback) * 1000 : 0),
        @"callbacks" : @(_callbacks),
        @"submitted" : @(_submitted),
        @"presented" : @(_freshPresented),
        @"displayRefreshPresentations" : @(_presented),
        @"heldRefreshes" : @(_heldRefreshes),
        @"overflow" : @(_overflow),
        @"superseded" : @(_superseded),
        @"idleRefreshes" : @(_skipped),
        @"busyRefreshes" : @(_busy),
        @"noDrawable" : @(_noFrame),
        @"errors" : @(_errors),
        @"callbackDeadlineMisses" : @(_missedDeadline),
        @"queued" : @(_queue.count),
        @"inFlight" : @(_inFlight),
        @"displayGPUms" : @(_gpuSum * 1000 / MAX(1, _submitted)),
        @"readyToPresentMs" : @(_readyAgeSum * 1000 / MAX(1, _freshPresented)),
        @"ptsErrorMs" : @(_ptsErrorSum * 1000 / MAX(1, _freshPresented))
    };
    os_unfair_lock_unlock(&_lock);
    NSMutableDictionary *m = [base mutableCopy];
    NSArray *sorted = [g sortedArrayUsingSelector:@selector(compare:)];
    m[@"gapP95Ms"] = sorted.count ? sorted[(NSUInteger)floor((sorted.count - 1) * .95)] : @0;
    m[@"gapP99Ms"] = sorted.count ? sorted[(NSUInteger)floor((sorted.count - 1) * .99)] : @0;
    NSArray *l = [latencies sortedArrayUsingSelector:@selector(compare:)];
    m[@"sourceToPresentP95Ms"] = l.count ? l[(NSUInteger)floor((l.count - 1) * .95)] : @0;
    m[@"sourceToPresentP99Ms"] = l.count ? l[(NSUInteger)floor((l.count - 1) * .99)] : @0;
    return m;
}
@end
