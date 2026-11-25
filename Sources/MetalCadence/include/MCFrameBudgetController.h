#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// A deterministic, side-effect free frame-budget planner for runtime degradation.
/// Intended to run serially from the media processing completion queue.
@interface MCFrameBudgetController : NSObject
@property (nonatomic, readonly) NSInteger activeMultiplier;
@property (nonatomic, readonly) NSInteger fallbackTransitions;
@property (nonatomic, readonly) NSInteger recoveryProbes;
@property (nonatomic, readonly) NSInteger cooldownPairs;
@property (nonatomic, readonly) NSInteger slowStreak;
- (instancetype)initWithPreferredMultiplier:(NSInteger)preferredMultiplier;
/// Returns the multiplier for the next source-frame pair.
/// Source interval and batch duration are in seconds, and thermalState is
/// NSProcessInfo.thermalState (0=nominal, 1=fair, 2=serious, 3=critical).
- (NSInteger)recordBatchSeconds:(double)duration
                 sourceInterval:(double)interval
                   thermalState:(NSInteger)thermalState;
@end
NS_ASSUME_NONNULL_END
