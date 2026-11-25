#import "MetalCadence.h"
#if !__has_feature(objc_arc)
#error MetalCadence requires ARC
#endif
#import <os/lock.h>
#include "internal/MCDeadlineSelection.hpp"
#include "internal/MCFixedTimingWindow.hpp"
#import <math.h>
NSInteger MCSelectDueFrameWithMode(const double *pts,
                                   NSUInteger count,
                                   double target,
                                   double lateLimit,
                                   MCFrameSelectionMode mode) {
    metalcadence::DeadlineMode strategy = mode == MCFrameSelectionInteractive
                                              ? metalcadence::DeadlineMode::Interactive
                                              : metalcadence::DeadlineMode::Smooth;
    return (NSInteger)metalcadence::selectDue(pts, count, target, lateLimit, strategy).index;
}

NSInteger MCSelectDueFrame(const double *pts, NSUInteger count, double target, double lateLimit) {
    return MCSelectDueFrameWithMode(pts, count, target, lateLimit, MCFrameSelectionSmooth);
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
    NSThread *_renderThread;
    CFRunLoopRef _renderRunLoop;
    dispatch_semaphore_t _renderThreadReady, _renderThreadExited;
    BOOL _renderThreadStarting;
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
    metalcadence::FixedTimingWindow<> _gapWindow, _sourceLatencyWindow;
    metalcadence::FixedTimingWindow<> _callbackGapWindow, _callbackLeadWindow;
    metalcadence::FixedTimingWindow<> _readyToSelectWindow, _selectToPresentWindow;
    metalcadence::FixedTimingWindow<> _encodeCostWindow, _gpuQueueWaitWindow;
    metalcadence::FixedTimingWindow<> _presentationTargetErrorWindow;
    uint64_t _interactiveSuperseded;
    uint64_t _redundantDrawsSkipped;
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
        _latenessRefreshAllowance = 1.5;
        _heldRefreshDrawEvery = 1;
        _selectionMode = MCFrameSelectionSmooth;
        _maximumPendingFrames = _capacity;
        _queue = [NSMutableArray new];

        _lastID = INT64_MIN;
        _lastDisplayedID = INT64_MIN;
        _encode = [encode copy];
    }
    return self;
}
// Render-link lifetime must be owned by the run loop on which the display
// link was registered. Avoid calling NSRunLoop methods from another thread.
- (CAMetalDisplayLink *)newDisplayLinkWithRate:(float)rate {
    CAMetalDisplayLink *link = [[CAMetalDisplayLink alloc] initWithMetalLayer:_layer];
    link.delegate = self;
    link.preferredFrameLatency = 1;
    link.preferredFrameRateRange = CAFrameRateRangeMake(rate, rate, rate);
    return link;
}

- (void)renderThreadEntry:(NSNumber *)rateNumber {
    @autoreleasepool {
        float rate = rateNumber.floatValue;
        NSThread.currentThread.name = @"MetalCadence.Presentation";
        CAMetalDisplayLink *link = [self newDisplayLinkWithRate:rate];

        NSRunLoop *runLoop = NSRunLoop.currentRunLoop;
        [link addToRunLoop:runLoop forMode:NSRunLoopCommonModes];

        os_unfair_lock_lock(&_lock);
        _link = link;
        _renderRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
        _renderThreadStarting = NO;
        os_unfair_lock_unlock(&_lock);

        dispatch_semaphore_signal(_renderThreadReady);

        while (!NSThread.currentThread.isCancelled) {
            @autoreleasepool {
                [runLoop runMode:NSDefaultRunLoopMode
                      beforeDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
            }
        }

        [link invalidate];
        os_unfair_lock_lock(&_lock);
        if (_renderRunLoop) {
            CFRelease(_renderRunLoop);
            _renderRunLoop = NULL;
        }
        _link = nil;
        os_unfair_lock_unlock(&_lock);
        dispatch_semaphore_signal(_renderThreadExited);
    }
}

- (BOOL)teardownDisplayLink {
    NSThread *thread = _renderThread;
    if (thread) {
        [thread cancel];

        os_unfair_lock_lock(&_lock);
        CFRunLoopRef runLoop = _renderRunLoop;
        if (runLoop) {
            CFRetain(runLoop);
        }
        os_unfair_lock_unlock(&_lock);

        if (runLoop) {
            CFRunLoopStop(runLoop);
            CFRunLoopWakeUp(runLoop);
            CFRelease(runLoop);
        }

        long result = dispatch_semaphore_wait(_renderThreadExited,
                                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (result != 0) {
            // Keep the thread/semaphore retained. Its exit handler must not
            // signal a deallocated semaphore if shutdown is delayed.
            NSLog(@"MetalCadence: presentation run loop did not stop within timeout");
            return NO;
        }
        _renderThread = nil;
        _renderThreadReady = nil;
        _renderThreadExited = nil;
        return YES;
    }

    [_link invalidate];
    _link = nil;
    return YES;
}

- (void)startWithRefreshRate:(float)hz {
    NSAssert(NSThread.isMainThread, @"start on main thread");
    if (![self teardownDisplayLink]) {
        return;
    }

    float rate = MAX(30, hz);
    os_unfair_lock_lock(&_lock);
    _running = YES;
    _refreshPeriod = 1.0 / rate;
    _lastCallback = 0;
    os_unfair_lock_unlock(&_lock);

    _layer.displaySyncEnabled = YES;
    _layer.maximumDrawableCount = 3;

    if (self.useDedicatedRenderThread) {
        _renderThreadReady = dispatch_semaphore_create(0);
        _renderThreadExited = dispatch_semaphore_create(0);
        _renderThreadStarting = YES;
        _renderThread = [[NSThread alloc] initWithTarget:self
                                                selector:@selector(renderThreadEntry:)
                                                  object:@(rate)];
        _renderThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_renderThread start];

        long result = dispatch_semaphore_wait(_renderThreadReady,
                                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (result != 0) {
            NSLog(@"MetalCadence: presentation thread startup timed out");
            os_unfair_lock_lock(&_lock);
            _running = NO;
            os_unfair_lock_unlock(&_lock);
            [self teardownDisplayLink];
            return;
        }
    } else {
        _link = [self newDisplayLinkWithRate:rate];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"stop on main thread");
    os_unfair_lock_lock(&_lock);
    _running = NO;
    os_unfair_lock_unlock(&_lock);

    [self teardownDisplayLink];

    os_unfair_lock_lock(&_lock);
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
    if (_queue.count > MIN(_capacity, MAX(2, _maximumPendingFrames))) {
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
        if (_lastCallback > 0 && now > _lastCallback) {
            _callbackGapWindow.record((now - _lastCallback) * 1000);
        }
        _lastCallback = now;
        _callbackLeadWindow.record((target - now) * 1000);
        if (now > update.targetTimestamp) {
            _missedDeadline++;
        }
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
        NSInteger selected = MCSelectDueFrameWithMode(
            pts,
            _queue.count,
            target,
            MIN(self.maxFrameLateness,
                _refreshPeriod * MAX(.5, MIN(4.0, self.latenessRefreshAllowance))),
            self.selectionMode);
        MCFrame *f = selected >= 0 ? _queue[selected] : nil;
        NSUInteger n = selected >= 0 ? (NSUInteger)selected + 1 : 0;
        BOOL fresh = f && f.identifier > _lastID;
        if (n) {
            [_queue removeObjectsInRange:NSMakeRange(0, n)];
            if (n > 1) {
                _superseded += n - 1;
                if (self.selectionMode == MCFrameSelectionInteractive) {
                    _interactiveSuperseded += n - 1;
                }
            }
        }
        if (fresh) {
            _readyToSelectWindow.record(MAX(0, now - f.ready) * 1000);
            _lastID = f.identifier;
            _held = f;
        } else {
            _skipped++;
            f = _held;
            if (f)
                _heldRefreshes++;
        }
        BOOL shouldSkipHeldDraw =
            !fresh && (self.skipHeldDraws || (self.heldRefreshDrawEvery > 1 &&
                                              _heldRefreshes % self.heldRefreshDrawEvery != 0));

        if (!f || shouldSkipHeldDraw) {
            if (f && shouldSkipHeldDraw) {
                _redundantDrawsSkipped++;
            }
            os_unfair_lock_unlock(&_lock);
            return;
        }
        _inFlight++;
        _submitted++;
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
        double encodeStarted = CACurrentMediaTime();
        _encode(cb, d, f);
        double encodeCostMs = (CACurrentMediaTime() - encodeStarted) * 1000;
        os_unfair_lock_lock(&_lock);
        _encodeCostWindow.record(encodeCostMs);
        os_unfair_lock_unlock(&_lock);

        [d addPresentedHandler:^(id<MTLDrawable> drawable) {
            double t = drawable.presentedTime;
            os_unfair_lock_lock(&self->_lock);
            if (t > 0) {
                self->_presented++;
                if (f.identifier > self->_lastDisplayedID) {
                    self->_lastDisplayedID = f.identifier;
                    self->_freshPresented++;
                    self->_selectToPresentWindow.record(MAX(0, t - now) * 1000);
                    self->_presentationTargetErrorWindow.record((t - target) * 1000);
                    if (f.sourceTime > 0 && t >= f.sourceTime) {
                        self->_sourceLatencyWindow.record((t - f.sourceTime) * 1000);
                    }
                    self->_readyAgeSum += MAX(0, t - f.ready);
                    self->_ptsErrorSum += t - f.pts;
                    if (self->_lastPresented > 0 && t > self->_lastPresented) {
                        double g = (t - self->_lastPresented) * 1000;
                        self->_gapSum += g;
                        self->_gapWindow.record(g);
                    }
                    self->_lastPresented = MAX(t, self->_lastPresented);
                }
            }
            os_unfair_lock_unlock(&self->_lock);
        }];
        double committedAt = CACurrentMediaTime();
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            (void)f.payload;
            os_unfair_lock_lock(&self->_lock);
            self->_inFlight--;
            self->_gpuSum += MAX(0, c.GPUEndTime - c.GPUStartTime);
            if (c.GPUStartTime > 0 && c.GPUStartTime >= committedAt) {
                self->_gpuQueueWaitWindow.record((c.GPUStartTime - committedAt) * 1000);
            }
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
        @"reactiveSuperseded" : @(_superseded - _interactiveSuperseded),
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
    auto g = _gapWindow;
    auto latencies = _sourceLatencyWindow;
    auto callbackGaps = _callbackGapWindow;
    auto callbackLead = _callbackLeadWindow;
    auto readyToSelect = _readyToSelectWindow;
    auto selectToPresent = _selectToPresentWindow;
    auto encodeCost = _encodeCostWindow;
    auto gpuQueueWait = _gpuQueueWaitWindow;
    auto targetError = _presentationTargetErrorWindow;
    NSDictionary *base = @{
        @"callbackAgeMs" : @(_lastCallback > 0 ? (CACurrentMediaTime() - _lastCallback) * 1000 : 0),
        @"callbacks" : @(_callbacks),
        @"submitted" : @(_submitted),
        @"presented" : @(_freshPresented),
        @"displayRefreshPresentations" : @(_presented),
        @"heldRefreshes" : @(_heldRefreshes),
        @"redundantDrawsSkipped" : @(_redundantDrawsSkipped),
        @"skipHeldDraws" : @(self.skipHeldDraws),
        @"heldRefreshDrawEvery" : @(self.heldRefreshDrawEvery),
        @"overflow" : @(_overflow),
        @"superseded" : @(_superseded),
        @"interactiveSuperseded" : @(_interactiveSuperseded),
        @"selectionMode" : @(self.selectionMode),
        @"maximumPendingFrames" : @(self.maximumPendingFrames),
        @"latenessRefreshAllowance" : @(self.latenessRefreshAllowance),
        @"dedicatedRenderThread" : @(self.useDedicatedRenderThread),
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
    m[@"gapP50Ms"] = @(g.percentile(.50));
    m[@"gapP95Ms"] = @(g.percentile(.95));
    m[@"gapP99Ms"] = @(g.percentile(.99));
    m[@"sourceToPresentP50Ms"] = @(latencies.percentile(.50));
    m[@"sourceToPresentP95Ms"] = @(latencies.percentile(.95));
    m[@"sourceToPresentP99Ms"] = @(latencies.percentile(.99));
    m[@"callbackGapP95Ms"] = @(callbackGaps.percentile(.95));
    m[@"callbackGapP99Ms"] = @(callbackGaps.percentile(.99));
    m[@"callbackLeadP50Ms"] = @(callbackLead.percentile(.50));
    m[@"callbackLeadP95Ms"] = @(callbackLead.percentile(.95));
    m[@"readyToSelectP50Ms"] = @(readyToSelect.percentile(.50));
    m[@"readyToSelectP95Ms"] = @(readyToSelect.percentile(.95));
    m[@"readyToSelectP99Ms"] = @(readyToSelect.percentile(.99));
    m[@"selectToPresentP95Ms"] = @(selectToPresent.percentile(.95));
    m[@"selectToPresentP99Ms"] = @(selectToPresent.percentile(.99));
    m[@"encodeCostP50Ms"] = @(encodeCost.percentile(.50));
    m[@"encodeCostP95Ms"] = @(encodeCost.percentile(.95));
    m[@"gpuQueueWaitP95Ms"] = @(gpuQueueWait.percentile(.95));
    m[@"gpuQueueWaitP99Ms"] = @(gpuQueueWait.percentile(.99));
    m[@"presentationTargetErrorP95Ms"] = @(targetError.percentile(.95));
    m[@"presentationTargetErrorP99Ms"] = @(targetError.percentile(.99));
    return m;
}
@end
