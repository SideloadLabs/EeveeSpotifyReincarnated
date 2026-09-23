// Private UIKit the SDK does not declare.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UIView (SGPrivate)
- (NSString *)recursiveDescription;
@end

@interface UIViewController (SGPrivate)
- (NSString *)_printHierarchy;
@end
