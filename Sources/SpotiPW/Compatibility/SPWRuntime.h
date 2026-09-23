#import <Foundation/Foundation.h>
#import <objc/runtime.h>
FOUNDATION_EXPORT BOOL SPWClassExists(NSString *className);
FOUNDATION_EXPORT BOOL SPWSelectorExists(NSString *className, SEL selector, BOOL classMethod);
FOUNDATION_EXPORT Class SPWClass(NSString *className);
