#import <Foundation/Foundation.h>
#import "MetalCadence.h"
#include <assert.h>
int main() {
    @autoreleasepool {
        MCWorkloadProfile *game = [MCWorkloadProfile interactiveGameWithSourceFPS:30
                                                                       displayFPS:120];
        MCWorkloadPlan *p = [[MCWorkloadPlan alloc] initWithProfile:game];
        assert(p.multiplier == 2 && p.targetFreshFPS == 60 && p.minimumDelay < .045);
        MCVideoConfiguration *c = [MCVideoConfiguration configurationWithProfile:game];
        c.gpuTextureBudgetMiB = 384;
        c.maxCachedTexturesPerPool = 16;
        c.preallocatedTexturesPerPool = 8;
        c.maxConcurrentGPUBatches = 3;
        c.preferFreshestFrame = YES;
        c.skipRedundantPresentations = YES;
        c.dedicatedPresentationThread = YES;
        c.heldRefreshDrawEvery = 3;
        c.presentationLatenessRefreshes = 2.25;
        MCVideoConfiguration *copied = [c copy];
        assert(copied.gpuTextureBudgetMiB == 384);
        assert(copied.maxCachedTexturesPerPool == 16);
        assert(copied.preallocatedTexturesPerPool == 8);
        assert(copied.maxConcurrentGPUBatches == 3);
        assert(copied.preferFreshestFrame == YES);
        assert(copied.skipRedundantPresentations == YES);
        assert(copied.dedicatedPresentationThread == YES);
        assert(copied.heldRefreshDrawEvery == 3);
        assert(copied.presentationLatenessRefreshes == 2.25);
        assert(c.multiplier == 2 && c.profile.kind == MCWorkloadKindInteractiveGame);
        game.policy = MCFramePolicyMaximumThroughput;
        assert([[MCWorkloadPlan alloc] initWithProfile:game].multiplier == 4);
        assert([MCVideoConfiguration configurationWithProfile:game].adaptiveMultiplier);
        assert(((MCVideoConfiguration *)[[MCVideoConfiguration configurationWithProfile:game] copy])
                   .adaptiveMultiplier);
        game.policy = MCFramePolicyEnergySaver;
        assert([[MCWorkloadPlan alloc] initWithProfile:game].multiplier == 1);
        game.policy = MCFramePolicyMinimumBoost;
        game.sourceFPS = 60;
        game.minimumFreshFPS = 61;
        game.preferredFreshFPS = 120;
        assert([[MCWorkloadPlan alloc] initWithProfile:game].multiplier == 2);
        game.kind = MCWorkloadKindRemoteDesktop;
        game.policy = MCFramePolicyLowestLatency;
        assert([[MCWorkloadPlan alloc] initWithProfile:game].minimumDelay == .006);
        game.producer = MCProducerKindCPURenderer;
        assert(((MCWorkloadProfile *)[game copy]).producer == MCProducerKindCPURenderer);
        puts("Workload profiles: 7 assertions passed");
    }
}
