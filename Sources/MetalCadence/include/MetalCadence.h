#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
NS_ASSUME_NONNULL_BEGIN
/// Returns the index of the earliest due frame within the lateness limit, or -1 if no frame is due.
FOUNDATION_EXPORT NSInteger MCSelectDueFrame(const double *pts, NSUInteger count, double target, double lateLimit);
@interface MCFrame : NSObject
@property(nonatomic,readonly) int64_t identifier;
@property(nonatomic,readonly) CFTimeInterval pts;
@property(nonatomic,readonly) CFTimeInterval ready;
@property(nonatomic,readonly) CFTimeInterval sourceTime;
@property(nonatomic,readonly,strong) id payload;
-(instancetype)initWithID:(int64_t)identifier pts:(CFTimeInterval)pts payload:(id)payload;
-(instancetype)initWithID:(int64_t)identifier pts:(CFTimeInterval)pts sourceTime:(CFTimeInterval)sourceTime payload:(id)payload;
@end
typedef void (^MCEncodeBlock)(id<MTLCommandBuffer> commandBuffer,id<CAMetalDrawable> drawable,MCFrame *frame);
/// A bounded, timestamp-based Metal presentation engine. All timestamps are host-clock seconds (CACurrentMediaTime).
/// Start/stop on the main thread; submit from any producer thread. Encode must be nonblocking.
@interface MCDisplayScheduler : NSObject <CAMetalDisplayLinkDelegate>
@property(nonatomic,readonly) NSUInteger capacity;
@property(nonatomic,readonly) NSUInteger maxInFlight;
@property(nonatomic) CFTimeInterval maxFrameLateness;
-(instancetype)initWithLayer:(CAMetalLayer*)layer device:(id<MTLDevice>)device capacity:(NSUInteger)capacity maxInFlight:(NSUInteger)maxInFlight encode:(MCEncodeBlock)encode;
-(void)startWithRefreshRate:(float)refreshRate;
-(void)stop;
-(BOOL)submit:(MCFrame*)frame;
-(NSDictionary<NSString*,NSNumber*>*)metrics;
@end
NS_ASSUME_NONNULL_END

#import "MCWorkloadProfile.h"
#import "MCFrameBudgetController.h"
#import "MCVideoEngine.h"
