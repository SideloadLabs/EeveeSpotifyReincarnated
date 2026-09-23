#import "SPWRuntime.h"
Class SPWClass(NSString *className) { return className.length ? NSClassFromString(className) : Nil; }
BOOL SPWClassExists(NSString *className) { return SPWClass(className) != Nil; }
BOOL SPWSelectorExists(NSString *className, SEL selector, BOOL classMethod) {
    Class cls = SPWClass(className);
    if (!cls || !selector) return NO;
    return classMethod ? class_respondsToSelector(object_getClass(cls), selector)
                       : class_respondsToSelector(cls, selector);
}
