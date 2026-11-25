#import <Foundation/Foundation.h>
#import "MCLatencyController.h"
#include <assert.h>
#include <math.h>
static uint64_t scramble(uint64_t *seed) {
    *seed += 0x9e3779b97f4a7c15ULL;
    uint64_t z = *seed;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}
int main(void) {
    @autoreleasepool {
        int tests = 0;
        for (int hzIndex = 0; hzIndex < 3; hzIndex++) {
            double hz = (double[]){60, 120, 165}[hzIndex];
            for (int sourceIndex = 0; sourceIndex < 2; sourceIndex++) {
                double source = (double[]){30, 60}[sourceIndex];
                MCLatencyController *c =
                    [[MCLatencyController alloc] initWithMinimumDelay:.010
                                                         maximumDelay:.125
                                                         initialDelay:.075
                                                               policy:MCFramePolicyMinimumBoost];
                uint64_t seed = 0xC011A79 + hzIndex * 19 + sourceIndex;
                for (int i = 0; i < 250; i++) {
                    double jitter = (double)(scramble(&seed) % 9000) / 1e6;
                    double age = (source == 30 ? .047 : .021) + jitter;
                    [c observeReadyAge:age
                          refreshPeriod:1. / hz
                         outputInterval:1. / (source * 2)
                           queuedFrames:0
                        totalSuperseded:0
                          totalOverflow:0];
                }
                NSDictionary *m = [c metrics];
                assert([m[@"latencyObservations"] integerValue] == 250);
                assert(c.currentDelay < .075);
                assert(c.currentDelay > .010);
                assert([m[@"latencySelectedReadyMs"] doubleValue] > 0);
                MCLatencyEstimate estimate = [c estimate];
                assert(fabs(estimate.readyPrediction * 1000 -
                            [m[@"latencySelectedReadyMs"] doubleValue]) < 1e-8);
                assert(fabs(estimate.deadlineSafety * 1000 -
                            [m[@"latencyBaseSafetyMs"] doubleValue] -
                            [m[@"latencyPressureSafetyMs"] doubleValue]) < 1e-8);
                printf("LATENCY PROFILE source=%.0f display=%.0f delay=%.3fms safety=%.3fms\n",
                       source,
                       hz,
                       c.currentDelay * 1000,
                       [m[@"latencyBaseSafetyMs"] doubleValue]);
                tests++;
            }
        }
        MCLatencyController *pressure =
            [[MCLatencyController alloc] initWithMinimumDelay:.008
                                                 maximumDelay:.120
                                                 initialDelay:.065
                                                       policy:MCFramePolicyMinimumBoost];
        for (int i = 0; i < 200; i++)
            [pressure observeReadyAge:.046
                        refreshPeriod:1. / 165
                       outputInterval:1. / 60
                         queuedFrames:0
                      totalSuperseded:0
                        totalOverflow:0];
        double stable = pressure.currentDelay;
        for (int i = 0; i < 8; i++)
            [pressure observeReadyAge:.072
                        refreshPeriod:1. / 165
                       outputInterval:1. / 60
                         queuedFrames:7
                      totalSuperseded:i * 2 + 2
                        totalOverflow:0];
        double pushed = pressure.currentDelay;
        assert(pushed > stable + .010);
        assert([pressure metrics][@"latencyPressureEvents"].integerValue >= 8);
        assert(pushed <= .120);
        for (int i = 0; i < 300; i++)
            [pressure observeReadyAge:.046
                        refreshPeriod:1. / 165
                       outputInterval:1. / 60
                         queuedFrames:0
                      totalSuperseded:16
                        totalOverflow:0];
        assert(pressure.currentDelay < pushed);
        tests++;
        MCLatencyController *audio =
            [[MCLatencyController alloc] initWithMinimumDelay:.010
                                                 maximumDelay:.120
                                                 initialDelay:.020
                                                       policy:MCFramePolicySmooth];
        for (int i = 0; i < 110; i++) {
            [audio observeAudioSchedulingAge:.028];
            [audio observeReadyAge:.009
                     refreshPeriod:1. / 165
                    outputInterval:1. / 60
                      queuedFrames:0
                   totalSuperseded:0
                     totalOverflow:0];
        }
        assert(audio.currentDelay >= .034);
        assert([audio metrics][@"latencyAudioObservations"].integerValue == 110);
        for (int i = 0; i < 150; i++) {
            [audio observeAudioSchedulingAge:.008];
            [audio observeReadyAge:.009
                     refreshPeriod:1. / 165
                    outputInterval:1. / 60
                      queuedFrames:0
                   totalSuperseded:0
                     totalOverflow:0];
        }
        assert(audio.currentDelay < .025);
        tests++;
        double audioDelayBeforeMiss = audio.currentDelay;
        [audio recordAudioDeadlineMiss];
        for (int i = 0; i < 12; i++) {
            [audio observeAudioSchedulingAge:.021];
            [audio observeReadyAge:.009
                     refreshPeriod:1. / 165
                    outputInterval:1. / 60
                      queuedFrames:0
                   totalSuperseded:0
                     totalOverflow:0];
        }
        assert(audio.currentDelay > audioDelayBeforeMiss);
        assert([audio metrics][@"latencyAudioDeadlineMisses"].integerValue == 1);
        tests++;

        MCLatencyController *interactive =
            [[MCLatencyController alloc] initWithMinimumDelay:.005
                                                 maximumDelay:.125
                                                 initialDelay:.018
                                                       policy:MCFramePolicyMinimumBoost];

        for (int i = 0; i < 120; i++) {
            [interactive observeAudioSchedulingAge:.070];
            [interactive observeReadyAge:.009
                           refreshPeriod:1. / 165
                          outputInterval:1. / 60
                            queuedFrames:0
                         totalSuperseded:0
                           totalOverflow:0];
        }

        NSDictionary *interactiveMetrics = [interactive metrics];
        assert([interactiveMetrics[@"latencyAudioFloorMs"] doubleValue] >= 70);
        assert([interactiveMetrics[@"latencyEffectiveAudioFloorMs"] doubleValue] < 35);
        assert(interactive.currentDelay < .035);
        tests++;

        MCLatencyController *raw =
            [[MCLatencyController alloc] initWithMinimumDelay:.005
                                                 maximumDelay:.090
                                                 initialDelay:.020
                                                       policy:MCFramePolicyLowestLatency];
        for (int i = 0; i < 80; i++)
            [raw observeReadyAge:.009
                   refreshPeriod:1. / 120
                  outputInterval:1. / 60
                    queuedFrames:0
                 totalSuperseded:0
                   totalOverflow:0];
        assert(raw.currentDelay < .020);
        tests++;
        NSLog(@"Latency controller passed %d profile, pressure and native-60 tests", tests);
    }
    return 0;
}
