#import "MCFrameBudgetController.h"
#import <math.h>
@interface MCFrameBudgetController ()
@property (nonatomic, readwrite) NSInteger activeMultiplier;
@property (nonatomic, readwrite) NSInteger fallbackTransitions;
@property (nonatomic, readwrite) NSInteger recoveryProbes;
@property (nonatomic, readwrite) NSInteger cooldownPairs;
@property NSInteger preferredMultiplier;
@property NSInteger recoveryCleanStreak;
@property (nonatomic, readwrite) NSInteger slowStreak;
@end
@implementation MCFrameBudgetController
- (instancetype)initWithPreferredMultiplier:(NSInteger)preferredMultiplier {
    if ((self = [super init])) {
        _preferredMultiplier = preferredMultiplier == 4 ? 4 : 2;
        _activeMultiplier = _preferredMultiplier;
    }
    return self;
}
- (NSInteger)recordBatchSeconds:(double)duration
                 sourceInterval:(double)interval
                   thermalState:(NSInteger)thermalState {
    if (_preferredMultiplier != 4 || !isfinite(duration) || duration < 0 || !isfinite(interval) ||
        interval <= 0)
        return _activeMultiplier;
    if (_activeMultiplier == 4) {
        if (duration > MAX(.038, interval * 1.35))
            _slowStreak++;
        else
            _slowStreak = MAX(0, _slowStreak - 1);
        if (_slowStreak >= 4 || thermalState >= 2) {
            _activeMultiplier = 2;
            _cooldownPairs = 450;
            _recoveryCleanStreak = 0;
            _slowStreak = 0;
            _fallbackTransitions++;
        }
    } else {
        if (_cooldownPairs > 0)
            _cooldownPairs--;
        if (thermalState == 0 && duration <= interval * .8)
            _recoveryCleanStreak = MIN(30, _recoveryCleanStreak + 1);
        else
            _recoveryCleanStreak = 0;
        if (_cooldownPairs == 0 && _recoveryCleanStreak >= 30) {
            _activeMultiplier = 4;
            _slowStreak = 0;
            _recoveryProbes++;
        }
    }
    return _activeMultiplier;
}
@end
