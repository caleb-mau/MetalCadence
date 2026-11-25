#import "MetalCadence.h"
#include <assert.h>
int main() {
    @autoreleasepool {
        double a[] = {1.0, 1.0166667, 1.0333333};
        assert(MCSelectDueFrame(a, 0, 1.0, .025) == -1);
        assert(MCSelectDueFrame(a, 3, .98, .025) == -1);
        assert(MCSelectDueFrame(a, 3, 1.017, .025) == 0);
        assert(MCSelectDueFrame(a, 3, 1.031, .025) == 1);
        assert(MCSelectDueFrame(a, 3, 1.100, .025) == 2);
        MCFrame *frame = [[MCFrame alloc] initWithID:7 pts:1.25 payload:@"test"];
        assert(frame.identifier == 7 && frame.pts == 1.25 && [frame.payload isEqual:@"test"]);
        puts("6 MetalCadence policy assertions passed");
    }
}
