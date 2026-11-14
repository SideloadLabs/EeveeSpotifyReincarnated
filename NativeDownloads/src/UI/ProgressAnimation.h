#pragma once
#import <QuartzCore/QuartzCore.h>
#include <math.h>

// Keep the model at the real reported value; Core Animation interpolates only
// its presentation. One keyed animation bounds work during frequent updates.
static inline void SAPSetProgressRing(CAShapeLayer *ring,double progress,BOOL animated) {
    double target=isfinite(progress)?fmin(1,fmax(0,progress)):0;
    double previous=ring.strokeEnd;
    if(animated && target==previous)return;
    double visible=((CAShapeLayer *)ring.presentationLayer).strokeEnd;
    if(!ring.presentationLayer)visible=previous;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    ring.strokeEnd=target;
    [CATransaction commit];
    if(!animated || target<=previous) {
        [ring removeAnimationForKey:@"pixie.progress"];return;
    }
    CABasicAnimation *animation=[CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    animation.fromValue=@(visible);animation.toValue=@(target);animation.duration=.3;
    animation.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [ring addAnimation:animation forKey:@"pixie.progress"];
}
