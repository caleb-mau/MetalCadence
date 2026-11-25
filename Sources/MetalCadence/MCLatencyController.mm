#import "MCLatencyController.h"
#import <math.h>
@interface MCLatencyController ()
@property NSMutableArray<NSNumber *> *samples;
@property NSMutableArray<NSNumber *> *audioSamples;
@property double audioReadyP95, audioReadyP99, audioMinimumDelay, audioRecoverySafety;
@property double effectiveAudioFloor;
@property NSUInteger audioCleanPackets, audioDeadlineMisses;
@property NSUInteger audioObservations;
@property double minimumDelay, maximumDelay, initialDelay, delay, baseSafety, pressureSafety;
@property double quantileReady, p50Ready, p90Ready, p95Ready, predictedDelay, refreshPeriod,
    phaseInterval;
@property MCFramePolicy policy;
@property uint64_t previousSuperseded, previousOverflow;
@property NSUInteger goodSamples, lateSamples, highPressureSamples;
@property NSUInteger observationCount, raisingAdjustments, loweringAdjustments;
@end
@implementation MCLatencyController
- (instancetype)initWithMinimumDelay:(double)minimum
                        maximumDelay:(double)maximum
                        initialDelay:(double)initial
                              policy:(MCFramePolicy)policy {
    if (!(self = [super init]))
        return nil;
    _minimumDelay = isfinite(minimum) ? MAX(0, minimum) : .012;
    _maximumDelay = isfinite(maximum) ? MAX(_minimumDelay, maximum) : .125;
    _initialDelay = isfinite(initial) ? MAX(_minimumDelay, MIN(_maximumDelay, initial)) : .075;
    _delay = _initialDelay;
    _policy = policy;
    _samples = [NSMutableArray arrayWithCapacity:96];
    _audioSamples = [NSMutableArray arrayWithCapacity:96];
    return self;
}
- (double)percentile:(NSArray<NSNumber *> *)sorted fraction:(double)fraction {
    if (!sorted.count)
        return 0;
    NSUInteger i = (NSUInteger)floor((sorted.count - 1) * MAX(0, MIN(1, fraction)));
    return sorted[i].doubleValue;
}
- (void)observeAudioSchedulingAge:(double)sourceAge {
    if (!isfinite(sourceAge) || sourceAge < 0 || sourceAge > .2)
        return;

    @synchronized(self) {
        [_audioSamples addObject:@(sourceAge)];
        if (_audioSamples.count > 96)
            [_audioSamples removeObjectAtIndex:0];

        NSArray<NSNumber *> *sorted = [_audioSamples sortedArrayUsingSelector:@selector(compare:)];
        _audioReadyP95 = [self percentile:sorted fraction:.95];
        _audioReadyP99 = [self percentile:sorted fraction:.99];
        _audioObservations++;
        _audioCleanPackets++;

        // Allow recovery headroom to decay only after sustained clean packets.
        if (_audioCleanPackets > 180)
            _audioRecoverySafety = MAX(0, _audioRecoverySafety - .000005);

        _audioMinimumDelay =
            MIN(_maximumDelay, MAX(_minimumDelay, _audioReadyP99 + .012 + _audioRecoverySafety));
    }
}
- (void)recordAudioDeadlineMiss {
    @synchronized(self) {
        _audioDeadlineMisses++;
        _audioCleanPackets = 0;
        _audioRecoverySafety = MIN(.030, _audioRecoverySafety + .006);
        _audioMinimumDelay =
            MIN(_maximumDelay, MAX(_minimumDelay, _audioReadyP99 + .012 + _audioRecoverySafety));
    }
}
- (double)observeReadyAge:(double)readyAge
            refreshPeriod:(double)refreshPeriod
           outputInterval:(double)outputInterval
             queuedFrames:(NSUInteger)queuedFrames
          totalSuperseded:(uint64_t)totalSuperseded
            totalOverflow:(uint64_t)totalOverflow {
    @synchronized(self) {
        if (!isfinite(readyAge) || readyAge < 0 || readyAge > 2)
            return _delay;
        double refresh =
            isfinite(refreshPeriod) ? MAX(1. / 240, MIN(1. / 24, refreshPeriod)) : 1. / 60;
        double phase = isfinite(outputInterval) ? MAX(1. / 240, MIN(.1, outputInterval)) : 1. / 60;
        [_samples addObject:@(readyAge)];
        if (_samples.count > 96)
            [_samples removeObjectAtIndex:0];
        _observationCount++;
        NSArray<NSNumber *> *sorted = [_samples sortedArrayUsingSelector:@selector(compare:)];
        _p50Ready = [self percentile:sorted fraction:.50];
        _p90Ready = [self percentile:sorted fraction:.90];
        _p95Ready = [self percentile:sorted fraction:.95];
        double percentile = .85;
        switch (_policy) {
        case MCFramePolicyLowestLatency:
            percentile = .75;
            break;
        case MCFramePolicySmooth:
            percentile = .95;
            break;
        case MCFramePolicyMaximumThroughput:
            percentile = .90;
            break;
        case MCFramePolicyEnergySaver:
            percentile = .80;
            break;
        default:
            percentile = .85;
            break;
        }
        _quantileReady = [self percentile:sorted fraction:percentile];
        _refreshPeriod = refresh;
        _phaseInterval = phase;
        switch (_policy) {
        case MCFramePolicyLowestLatency:
            _baseSafety = MAX(.0015, refresh * .35 + phase * .08);
            break;
        case MCFramePolicySmooth:
            _baseSafety = MAX(.003, refresh * 1.35 + phase * .22);
            break;
        case MCFramePolicyMaximumThroughput:
            _baseSafety = MAX(.0025, refresh * 1.0 + phase * .16);
            break;
        case MCFramePolicyEnergySaver:
            _baseSafety = MAX(.002, refresh * .75);
            break;
        default:
            _baseSafety = MAX(.002, refresh * .70 + phase * .12);
            break;
        }
        uint64_t newlySuperseded =
            totalSuperseded >= _previousSuperseded ? totalSuperseded - _previousSuperseded : 0;
        uint64_t newlyOverflow =
            totalOverflow >= _previousOverflow ? totalOverflow - _previousOverflow : 0;
        _previousSuperseded = totalSuperseded;
        _previousOverflow = totalOverflow;
        if (newlySuperseded || newlyOverflow || queuedFrames > 5) {
            double pressure =
                MAX(1, MIN(4, newlySuperseded + newlyOverflow + (queuedFrames > 5 ? 1 : 0)));
            _pressureSafety = MIN(refresh * 3.0, _pressureSafety + refresh * .45 * pressure);
            _goodSamples = 0;
            _highPressureSamples++;
        } else {
            _goodSamples++;
            if (_goodSamples > 20)
                _pressureSafety = MAX(0, _pressureSafety - refresh * .012);
        }
        if (readyAge > _delay - .001)
            _lateSamples++;
        double videoGoal = _quantileReady + _baseSafety + _pressureSafety;
        double audioGoal = _audioMinimumDelay;

        // A late capture/audio burst must not hold interactive video hostage.
        // Smooth playback is allowed to trade responsiveness for continuity.
        if (_policy == MCFramePolicyLowestLatency) {
            audioGoal = MIN(audioGoal, videoGoal + .006);
        } else if (_policy == MCFramePolicyMinimumBoost) {
            audioGoal = MIN(audioGoal, videoGoal + .012);
        }

        _effectiveAudioFloor = audioGoal;
        double goal = MAX(_minimumDelay, MIN(_maximumDelay, MAX(videoGoal, audioGoal)));
        _predictedDelay = goal;
        // Rapid response to missed deadlines, but bounded to avoid audible A/V jumps.
        if (goal > _delay) {
            double correction = MAX(.0015, (goal - _delay) * .55);
            _delay = MIN(_maximumDelay, _delay + MIN(.008, correction));
            _raisingAdjustments++;
        } else if (goal < _delay) {
            // Decrease a few milliseconds per second to preserve audio scheduling continuity.
            _delay = MAX(goal, _delay - .00045);
            _loweringAdjustments++;
        }
        return _delay;
    }
}
- (double)currentDelay {
    @synchronized(self) {
        return _delay;
    }
}
- (NSDictionary<NSString *, NSNumber *> *)metrics {
    @synchronized(self) {
        return @{
            @"latencyControllerDelayMs" : @(_delay * 1000),
            @"latencyControllerGoalMs" : @(_predictedDelay * 1000),
            @"latencyReadyP50Ms" : @(_p50Ready * 1000),
            @"latencyReadyP90Ms" : @(_p90Ready * 1000),
            @"latencyReadyP95Ms" : @(_p95Ready * 1000),
            @"latencyAudioReadyP95Ms" : @(_audioReadyP95 * 1000),
            @"latencyAudioReadyP99Ms" : @(_audioReadyP99 * 1000),
            @"latencyAudioRecoverySafetyMs" : @(_audioRecoverySafety * 1000),
            @"latencyAudioDeadlineMisses" : @(_audioDeadlineMisses),
            @"latencyAudioFloorMs" : @(_audioMinimumDelay * 1000),
            @"latencyEffectiveAudioFloorMs" : @(_effectiveAudioFloor * 1000),
            @"latencyAudioObservations" : @(_audioObservations),
            @"latencySelectedReadyMs" : @(_quantileReady * 1000),
            @"latencyBaseSafetyMs" : @(_baseSafety * 1000),
            @"latencyPressureSafetyMs" : @(_pressureSafety * 1000),
            @"latencyRefreshMs" : @(_refreshPeriod * 1000),
            @"latencyPhaseMs" : @(_phaseInterval * 1000),
            @"latencyObservations" : @(_observationCount),
            @"latencyLateReadyCount" : @(_lateSamples),
            @"latencyPressureEvents" : @(_highPressureSamples),
            @"latencyRaised" : @(_raisingAdjustments),
            @"latencyLowered" : @(_loweringAdjustments)
        };
    }
}
@end
