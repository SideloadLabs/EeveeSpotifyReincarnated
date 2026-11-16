// Host-only declarations: the startup probe never creates or uses UIKit views.
#import <Foundation/Foundation.h>
@class UIView, UIViewController, UIImage, UIColor;
@interface UIButton : NSObject
@property(nonatomic,getter=isHidden) BOOL hidden;
@end
