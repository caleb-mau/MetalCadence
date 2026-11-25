#import <Foundation/Foundation.h>
#import "MCFrameBudgetController.h"
#include <assert.h>
int main() {
    @autoreleasepool {
        MCFrameBudgetController *p =
            [[MCFrameBudgetController alloc] initWithPreferredMultiplier:4];
        assert(p.activeMultiplier == 4);
        for (int i = 0; i < 4; i++)
            [p recordBatchSeconds:.05 sourceInterval:1. / 30 thermalState:0];
        assert(p.activeMultiplier == 2 && p.fallbackTransitions == 1 && p.cooldownPairs == 450);
        for (int i = 0; i < 450; i++)
            [p recordBatchSeconds:.020 sourceInterval:1. / 30 thermalState:1];
        assert(p.activeMultiplier == 2 && p.recoveryProbes == 0);
        [p recordBatchSeconds:.020 sourceInterval:1. / 30 thermalState:0];
        assert(p.activeMultiplier == 4 && p.recoveryProbes == 1);
        [p recordBatchSeconds:.041 sourceInterval:1. / 30 thermalState:0];
        [p recordBatchSeconds:.022 sourceInterval:1. / 30 thermalState:0];
        assert(p.activeMultiplier == 4);
        MCFrameBudgetController *sustained =
            [[MCFrameBudgetController alloc] initWithPreferredMultiplier:4];
        for (int i = 0; i < 200; i++)
            [sustained recordBatchSeconds:.041 sourceInterval:1. / 30 thermalState:0];
        assert(sustained.activeMultiplier == 4);
        for (int i = 0; i < 4; i++)
            [sustained recordBatchSeconds:.065 sourceInterval:1. / 30 thermalState:1];
        assert(sustained.activeMultiplier == 2);
        puts("Frame budget controller: 8 assertions passed");
    }
}
