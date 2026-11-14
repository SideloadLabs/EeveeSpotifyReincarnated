#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
// Window-coordinate viewport and visible bottom chrome rectangles.
static inline CGFloat SAPOfflineChromeCoverage(CGRect viewport,CGFloat safeBottom,NSArray<NSValue *> *rectangles) {
    CGFloat top=MIN(CGRectGetMaxY(viewport),MAX(CGRectGetMinY(viewport),safeBottom));
    for(NSValue *value in rectangles) {
        CGRect rect;[value getValue:&rect size:sizeof(rect)];
        if(CGRectIsNull(rect) || CGRectIsInfinite(rect) || !isfinite(rect.origin.y) ||
           rect.size.width<viewport.size.width*.45 || rect.size.height<=0 ||
           rect.size.height>viewport.size.height*.45 || CGRectGetMinY(rect)<CGRectGetMidY(viewport) ||
           !CGRectIntersectsRect(viewport,rect))continue;
        top=MIN(top,CGRectGetMinY(rect));
    }
    return MAX(0,CGRectGetMaxY(viewport)-top);
}
