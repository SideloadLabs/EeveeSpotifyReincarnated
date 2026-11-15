#pragma once
#import <UIKit/UIKit.h>
// Active-page-only geometry events; no timer or per-frame polling.
@interface SAPOfflineLibraryChrome : NSObject
@property(nonatomic,copy) dispatch_block_t changed;
- (void)attachToView:(UIView *)view;
- (void)detach;
- (CGFloat)coverageInView:(UIView *)view;
@end
