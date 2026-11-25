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
    dispatch_queue_t _lateLatchQueue;
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
    metalcadence::FixedTimingWindow<> _sourceToReadyWindow, _readyToPresentWindow;
    metalcadence::FixedTimingWindow<> _scheduledWaitWindow;
    // Fine-grained scheduler profiling. Distinguish CPU execution from time
    // intentionally awaiting a presentation target or GPU/display callback.
    metalcadence::FixedTimingWindow<256> _submitLockWaitWindow, _submitMutationWindow;
    metalcadence::FixedTimingWindow<256> _callbackLockWaitWindow, _callbackLockHeldWindow;
    metalcadence::FixedTimingWindow<256> _callbackSelectionWindow, _drawableLookupWindow;
    metalcadence::FixedTimingWindow<256> _commandBufferWindow, _callbackHandlerSetupWindow;
    metalcadence::FixedTimingWindow<256> _presentCommitWindow, _callbackTotalWindow;
    // Host-clock deadline slack for deciding whether late-latching can ever
    // be safe without missing the OS display link's submission deadline.
    metalcadence::FixedTimingWindow<256> _submissionDeadlineLeadWindow;
    metalcadence::FixedTimingWindow<256> _submissionDeadlineSlackWindow;
    metalcadence::FixedTimingWindow<256> _actualLateLatchWindow;
    uint64_t _lateLatchFallbacks;
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
        _lateLatchDelaySeconds = 0;
        _lateLatchQueue =
            dispatch_queue_create("com.metalcadence.presentation.late-latch",
                                  dispatch_queue_attr_make_with_qos_class(
                                      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        _selectionMode = MCFrameSelectionSmooth;
        _maximumPendingFrames = _capacity;
        _queue = [NSMutableArray arrayWithCapacity:_capacity];

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
    const double lockAttempt = CACurrentMediaTime();
    os_unfair_lock_lock(&_lock);
    const double lockAcquired = CACurrentMediaTime();
    _submitLockWaitWindow.record((lockAcquired - lockAttempt) * 1000);
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
    _submitMutationWindow.record((CACurrentMediaTime() - lockAcquired) * 1000);
    os_unfair_lock_unlock(&_lock);
    return YES;
}
- (void)renderScheduledUpdate:(CAMetalDisplayLinkUpdate *)update
            callbackTimestamp:(double)callbackTimestamp
             capturedDrawable:(id<CAMetalDrawable>)preacquiredDrawable {
    @autoreleasepool {
        double now = CACurrentMediaTime(), target = update.targetPresentationTimestamp;
        const double lockAttempt = CACurrentMediaTime();
        os_unfair_lock_lock(&_lock);
        const double lockAcquired = CACurrentMediaTime();
        _callbackLockWaitWindow.record((lockAcquired - lockAttempt) * 1000);
        _callbacks++;
        if (_lastCallback > 0 && callbackTimestamp > _lastCallback) {
            _callbackGapWindow.record((callbackTimestamp - _lastCallback) * 1000);
        }
        _lastCallback = callbackTimestamp;
        _callbackLeadWindow.record((target - callbackTimestamp) * 1000);
        _submissionDeadlineLeadWindow.record((update.targetTimestamp - callbackTimestamp) * 1000);
        _actualLateLatchWindow.record((now - callbackTimestamp) * 1000);
        if (now > update.targetTimestamp) {
            _missedDeadline++;
        }
        if (!_running || _inFlight >= _maxInFlight) {
            _busy++;
            os_unfair_lock_unlock(&_lock);
            return;
        }
        const double drawableAttempt = CACurrentMediaTime();
        id<CAMetalDrawable> drawable = preacquiredDrawable ?: update.drawable;
        _drawableLookupWindow.record((CACurrentMediaTime() - drawableAttempt) * 1000);
        if (!drawable) {
            _noFrame++;
            os_unfair_lock_unlock(&_lock);
            return;
        }
        const double selectionStart = CACurrentMediaTime();
        const auto strategy = self.selectionMode == MCFrameSelectionInteractive
                                  ? metalcadence::DeadlineMode::Interactive
                                  : metalcadence::DeadlineMode::Smooth;
        NSInteger selected =
            metalcadence::selectDueBy(
                [self](std::size_t i) {
                    return self->_queue[i].pts;
                },
                _queue.count,
                target,
                MIN(self.maxFrameLateness,
                    _refreshPeriod * MAX(.5, MIN(4.0, self.latenessRefreshAllowance))),
                strategy)
                .index;
        _callbackSelectionWindow.record((CACurrentMediaTime() - selectionStart) * 1000);
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
        _callbackLockHeldWindow.record((CACurrentMediaTime() - lockAcquired) * 1000);
        os_unfair_lock_unlock(&_lock);
        id<CAMetalDrawable> d = drawable;
        const double commandBufferAttempt = CACurrentMediaTime();
        id<MTLCommandBuffer> cb = [_commandQueue commandBuffer];
        const double commandBufferMs = (CACurrentMediaTime() - commandBufferAttempt) * 1000;
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

        const double handlerStart = CACurrentMediaTime();
        [d addPresentedHandler:^(id<MTLDrawable> drawable) {
            double t = drawable.presentedTime;
            BOOL notifyFresh = NO;
            os_unfair_lock_lock(&self->_lock);
            if (t > 0) {
                self->_presented++;
                if (f.identifier > self->_lastDisplayedID) {
                    notifyFresh = YES;
                    self->_lastDisplayedID = f.identifier;
                    self->_freshPresented++;
                    self->_selectToPresentWindow.record(MAX(0, t - now) * 1000);
                    self->_presentationTargetErrorWindow.record((t - target) * 1000);
                    if (f.sourceTime > 0 && t >= f.sourceTime) {
                        self->_sourceLatencyWindow.record((t - f.sourceTime) * 1000);
                    }
                    if (f.sourceTime > 0 && f.ready >= f.sourceTime) {
                        self->_sourceToReadyWindow.record((f.ready - f.sourceTime) * 1000);
                    }
                    self->_readyToPresentWindow.record(MAX(0, t - f.ready) * 1000);
                    self->_scheduledWaitWindow.record(MAX(0, f.pts - f.ready) * 1000);
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
            if (notifyFresh) {
                MCFramePresentedBlock callback = self.onFreshFramePresented;
                if (callback)
                    callback(f.sourceTime, t, f.identifier);
            }
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
        const double handlerSetupMs = (CACurrentMediaTime() - handlerStart) * 1000;
        const double presentCommitStart = CACurrentMediaTime();
        [cb presentDrawable:d];
        [cb commit];
        const double commitEnd = CACurrentMediaTime();
        os_unfair_lock_lock(&_lock);
        _commandBufferWindow.record(commandBufferMs);
        _callbackHandlerSetupWindow.record(handlerSetupMs);
        _presentCommitWindow.record((commitEnd - presentCommitStart) * 1000);
        _submissionDeadlineSlackWindow.record((update.targetTimestamp - commitEnd) * 1000);
        _callbackTotalWindow.record((commitEnd - now) * 1000);
        os_unfair_lock_unlock(&_lock);
    }
}
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    (void)link;
    const double callbackTimestamp = CACurrentMediaTime();
    double requestedDelay = self.lateLatchDelaySeconds;
    if (requestedDelay > 0 && _lateLatchQueue) {
        // Apple requires presenting the display-link drawable before its
        // targetTimestamp. P05 available slack is about 16 ms at 60 Hz on M5.
        // Hold at least 6 ms for dispatch jitter, CPU encode and GPU submit.
        double untilDeadline = update.targetTimestamp - callbackTimestamp;
        double delay = MIN(requestedDelay, MAX(0., untilDeadline - .006));
        if (delay >= .001) {
            id<CAMetalDrawable> drawable = update.drawable;
            if (drawable) {
                CAMetalDisplayLinkUpdate *capturedUpdate = update;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               _lateLatchQueue,
                               ^{
                                   [self renderScheduledUpdate:capturedUpdate
                                             callbackTimestamp:callbackTimestamp
                                              capturedDrawable:drawable];
                               });
                return;
            }
        }
        os_unfair_lock_lock(&_lock);
        _lateLatchFallbacks++;
        os_unfair_lock_unlock(&_lock);
    }
    [self renderScheduledUpdate:update callbackTimestamp:callbackTimestamp capturedDrawable:nil];
}
- (MCSchedulerPressure)pressureCounters {
    const double now = CACurrentMediaTime();
    os_unfair_lock_lock(&_lock);
    NSUInteger overdue = metalcadence::overdueCount(
        [self](std::size_t i) {
            return self->_queue[i].pts;
        },
        _queue.count,
        now);
    MCSchedulerPressure snapshot = {_superseded,
                                    _superseded - _interactiveSuperseded,
                                    _overflow,
                                    _missedDeadline,
                                    _queue.count,
                                    overdue,
                                    _lastCallback > 0 ? MAX(0, now - _lastCallback) * 1000 : 0};
    os_unfair_lock_unlock(&_lock);
    return snapshot;
}
- (NSDictionary *)pressureSnapshot {
    MCSchedulerPressure snapshot = [self pressureCounters];
    return @{
        @"superseded" : @(snapshot.superseded),
        @"reactiveSuperseded" : @(snapshot.reactiveSuperseded),
        @"overflow" : @(snapshot.overflow),
        @"queued" : @(snapshot.queued),
        @"overdue" : @(snapshot.overdue),
        @"callbackDeadlineMisses" : @(snapshot.callbackDeadlineMisses),
        @"callbackAgeMs" : @(snapshot.callbackAgeMs)
    };
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
    auto sourceToReady = _sourceToReadyWindow;
    auto readyToPresent = _readyToPresentWindow;
    auto scheduledWait = _scheduledWaitWindow;
    auto submitLockWait = _submitLockWaitWindow;
    auto submitMutation = _submitMutationWindow;
    auto callbackLockWait = _callbackLockWaitWindow;
    auto callbackLockHeld = _callbackLockHeldWindow;
    auto callbackSelection = _callbackSelectionWindow;
    auto drawableLookup = _drawableLookupWindow;
    auto commandBuffer = _commandBufferWindow;
    auto handlerSetup = _callbackHandlerSetupWindow;
    auto presentCommit = _presentCommitWindow;
    auto callbackTotal = _callbackTotalWindow;
    auto submissionDeadlineLead = _submissionDeadlineLeadWindow;
    auto submissionDeadlineSlack = _submissionDeadlineSlackWindow;
    auto actualLateLatch = _actualLateLatchWindow;
    const auto snapshot_lateLatchFallbacks = _lateLatchFallbacks;
    const auto snapshot_lateLatchRequestMs = self.lateLatchDelaySeconds * 1000;
    const auto snapshot_callbackAgeMs =
        _lastCallback > 0 ? (CACurrentMediaTime() - _lastCallback) * 1000 : 0;
    const auto snapshot_callbacks = _callbacks;
    const auto snapshot_submitted = _submitted;
    const auto snapshot_presented = _freshPresented;
    const auto snapshot_displayRefreshPresentations = _presented;
    const auto snapshot_heldRefreshes = _heldRefreshes;
    const auto snapshot_redundantDrawsSkipped = _redundantDrawsSkipped;
    const auto snapshot_skipHeldDraws = self.skipHeldDraws;
    const auto snapshot_heldRefreshDrawEvery = self.heldRefreshDrawEvery;
    const auto snapshot_overflow = _overflow;
    const auto snapshot_superseded = _superseded;
    const auto snapshot_interactiveSuperseded = _interactiveSuperseded;
    const auto snapshot_selectionMode = self.selectionMode;
    const auto snapshot_maximumPendingFrames = self.maximumPendingFrames;
    const auto snapshot_latenessRefreshAllowance = self.latenessRefreshAllowance;
    const auto snapshot_dedicatedRenderThread = self.useDedicatedRenderThread;
    const auto snapshot_idleRefreshes = _skipped;
    const auto snapshot_busyRefreshes = _busy;
    const auto snapshot_noDrawable = _noFrame;
    const auto snapshot_errors = _errors;
    const auto snapshot_callbackDeadlineMisses = _missedDeadline;
    const auto snapshot_queued = _queue.count;
    const auto snapshot_inFlight = _inFlight;
    const auto snapshot_displayGPUms = _gpuSum * 1000 / MAX(1, _submitted);
    const auto snapshot_readyToPresentMs = _readyAgeSum * 1000 / MAX(1, _freshPresented);
    const auto snapshot_ptsErrorMs = _ptsErrorSum * 1000 / MAX(1, _freshPresented);
    os_unfair_lock_unlock(&_lock);
    NSDictionary *base = @{
        @"callbackAgeMs" : @(snapshot_callbackAgeMs),
        @"callbacks" : @(snapshot_callbacks),
        @"submitted" : @(snapshot_submitted),
        @"presented" : @(snapshot_presented),
        @"displayRefreshPresentations" : @(snapshot_displayRefreshPresentations),
        @"heldRefreshes" : @(snapshot_heldRefreshes),
        @"redundantDrawsSkipped" : @(snapshot_redundantDrawsSkipped),
        @"skipHeldDraws" : @(snapshot_skipHeldDraws),
        @"heldRefreshDrawEvery" : @(snapshot_heldRefreshDrawEvery),
        @"overflow" : @(snapshot_overflow),
        @"superseded" : @(snapshot_superseded),
        @"interactiveSuperseded" : @(snapshot_interactiveSuperseded),
        @"selectionMode" : @(snapshot_selectionMode),
        @"maximumPendingFrames" : @(snapshot_maximumPendingFrames),
        @"latenessRefreshAllowance" : @(snapshot_latenessRefreshAllowance),
        @"dedicatedRenderThread" : @(snapshot_dedicatedRenderThread),
        @"idleRefreshes" : @(snapshot_idleRefreshes),
        @"busyRefreshes" : @(snapshot_busyRefreshes),
        @"noDrawable" : @(snapshot_noDrawable),
        @"errors" : @(snapshot_errors),
        @"callbackDeadlineMisses" : @(snapshot_callbackDeadlineMisses),
        @"queued" : @(snapshot_queued),
        @"inFlight" : @(snapshot_inFlight),
        @"displayGPUms" : @(snapshot_displayGPUms),
        @"readyToPresentMs" : @(snapshot_readyToPresentMs),
        @"ptsErrorMs" : @(snapshot_ptsErrorMs)
    };
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
    m[@"sourceToReadyP50Ms"] = @(sourceToReady.percentile(.50));
    m[@"sourceToReadyP95Ms"] = @(sourceToReady.percentile(.95));
    m[@"readyToPresentP50Ms"] = @(readyToPresent.percentile(.50));
    m[@"readyToPresentP95Ms"] = @(readyToPresent.percentile(.95));
    m[@"scheduledWaitP50Ms"] = @(scheduledWait.percentile(.50));
    m[@"scheduledWaitP95Ms"] = @(scheduledWait.percentile(.95));
    // Stage durations describe CPU work within a scheduler callback.
    // Scheduled waiting, GPU execution and physical scanout are separate.
    m[@"schedulerSubmitLockWaitP95Ms"] = @(submitLockWait.percentile(.95));
    m[@"schedulerSubmitLockWaitP99Ms"] = @(submitLockWait.percentile(.99));
    m[@"schedulerSubmitMutationP95Ms"] = @(submitMutation.percentile(.95));
    m[@"schedulerCallbackLockWaitP95Ms"] = @(callbackLockWait.percentile(.95));
    m[@"schedulerCallbackLockWaitP99Ms"] = @(callbackLockWait.percentile(.99));
    m[@"schedulerCallbackLockHeldP95Ms"] = @(callbackLockHeld.percentile(.95));
    m[@"schedulerSelectionP50Ms"] = @(callbackSelection.percentile(.50));
    m[@"schedulerSelectionP95Ms"] = @(callbackSelection.percentile(.95));
    m[@"schedulerDrawableLookupP95Ms"] = @(drawableLookup.percentile(.95));
    m[@"schedulerDrawableLookupP99Ms"] = @(drawableLookup.percentile(.99));
    m[@"schedulerCommandBufferP95Ms"] = @(commandBuffer.percentile(.95));
    m[@"schedulerHandlerSetupP95Ms"] = @(handlerSetup.percentile(.95));
    m[@"schedulerPresentCommitP95Ms"] = @(presentCommit.percentile(.95));
    m[@"schedulerCallbackTotalP50Ms"] = @(callbackTotal.percentile(.50));
    m[@"schedulerCallbackTotalP95Ms"] = @(callbackTotal.percentile(.95));
    m[@"schedulerCallbackTotalP99Ms"] = @(callbackTotal.percentile(.99));
    m[@"schedulerLateLatchRequestedMs"] = @(snapshot_lateLatchRequestMs);
    m[@"schedulerLateLatchActualP50Ms"] = @(actualLateLatch.percentile(.50));
    m[@"schedulerLateLatchActualP95Ms"] = @(actualLateLatch.percentile(.95));
    m[@"schedulerLateLatchFallbacks"] = @(snapshot_lateLatchFallbacks);
    m[@"schedulerSubmissionDeadlineLeadP05Ms"] = @(submissionDeadlineLead.percentile(.05));
    m[@"schedulerSubmissionDeadlineLeadP50Ms"] = @(submissionDeadlineLead.percentile(.50));
    m[@"schedulerSubmissionDeadlineLeadP95Ms"] = @(submissionDeadlineLead.percentile(.95));
    m[@"schedulerSubmissionDeadlineSlackP05Ms"] = @(submissionDeadlineSlack.percentile(.05));
    m[@"schedulerSubmissionDeadlineSlackP50Ms"] = @(submissionDeadlineSlack.percentile(.50));
    m[@"schedulerDrawnSamples"] = @(callbackTotal.size());
    m[@"schedulerCallbackSamples"] = @(callbackLockWait.size());
    m[@"schedulerSubmitSamples"] = @(submitMutation.size());
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
