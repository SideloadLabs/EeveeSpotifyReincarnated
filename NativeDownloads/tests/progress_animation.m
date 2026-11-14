#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "ProgressAnimation.h"
#include <assert.h>
#include <math.h>

// A controlled presentation layer lets us retarget an in-flight animation
// without a window server, sleeping, or assuming frame timing on the host.
@interface ProgressTestLayer : CAShapeLayer
@property(nonatomic,strong) CAShapeLayer *visibleLayer;
@end
@implementation ProgressTestLayer
- (id)presentationLayer { return self.visibleLayer; }
@end

int main(void) { @autoreleasepool {
    ProgressTestLayer *ring=[ProgressTestLayer layer];
    SAPSetProgressRing(ring,.2,NO);
    assert(fabs(ring.strokeEnd-.2)<.0001 && !ring.animationKeys.count);
    SAPSetProgressRing(ring,.6,YES);
    CABasicAnimation *animation=(id)[ring animationForKey:@"pixie.progress"];
    assert(animation && fabs([animation.fromValue doubleValue]-.2)<.0001);
    assert(fabs([animation.toValue doubleValue]-.6)<.0001 && ring.strokeEnd==.6);
    assert(animation.duration>0 && animation.duration<=.4 && !animation.repeatCount);

    // Retarget from what is visible, rather than jumping to the old target.
    ring.visibleLayer=[CAShapeLayer layer];ring.visibleLayer.strokeEnd=.35;
    SAPSetProgressRing(ring,.8,YES);
    animation=(id)[ring animationForKey:@"pixie.progress"];
    assert(fabs([animation.fromValue doubleValue]-.35)<.0001);
    assert(fabs([animation.toValue doubleValue]-.8)<.0001 && ring.strokeEnd==.8);
    ring.visibleLayer.strokeEnd=.45;
    SAPSetProgressRing(ring,.8,YES);
    animation=(id)[ring animationForKey:@"pixie.progress"];
    assert(fabs([animation.fromValue doubleValue]-.35)<.0001); // no restart

    SAPSetProgressRing(ring,0,YES); // new operation / corrected denominator
    assert(ring.strokeEnd==0 && !ring.animationKeys.count);
    SAPSetProgressRing(ring,.9,YES);
    SAPSetProgressRing(ring,.9,NO); // Reduce Motion or detached view
    assert(ring.strokeEnd==.9 && !ring.animationKeys.count);
    SAPSetProgressRing(ring,INFINITY,NO);
    assert(ring.strokeEnd==0 && !ring.animationKeys.count);
    SAPSetProgressRing(ring,NAN,YES);assert(ring.strokeEnd==0);
    SAPSetProgressRing(ring,2,NO);assert(ring.strokeEnd==1);
    SAPSetProgressRing(ring,-1,NO);assert(ring.strokeEnd==0);
    puts("PASS: exact ring targets, continuous retarget, duplicate updates, reset and reduced motion");
} return 0; }
