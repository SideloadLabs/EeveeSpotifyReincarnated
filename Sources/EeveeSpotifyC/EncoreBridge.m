#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Tweak.h"

UIImage *EeveeRenderTemplate(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.width < 2 || size.height < 2) return nil;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [view.layer renderInContext:context.CGContext];
    }];
    CGImageRef cg = image.CGImage;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    NSMutableData *alpha = [NSMutableData dataWithLength:width * height];
    CGContextRef context = CGBitmapContextCreate(alpha.mutableBytes, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(context);
    const uint8_t *bytes = alpha.bytes;
    for (size_t i = 0; i < alpha.length; i++) {
        if (bytes[i] > 16) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

UIImage *EeveeEncoreIconImage(UIView *live, BOOL active) {
    CGSize size = live.bounds.size;
    Ivar ivar = class_getInstanceVariable(live.class, "icon");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    id icon = type && type[0] == '@' ? object_getIvar(live, ivar) : nil;
    Class viewClass = NSClassFromString(@"SPTEncoreIconView");
    if (!icon || !viewClass || size.width < 2) return nil;

    UIView *view = ((id (*)(id, SEL, id))objc_msgSend)([viewClass alloc], @selector(initWithIcon:), icon);
    view.frame = (CGRect){CGPointZero, size};
    SEL setters[] = {@selector(setForegroundColor:), NSSelectorFromString(@"setActiveForegroundColor:")};
    for (int i = 0; i < 2; i++) {
        if ([view respondsToSelector:setters[i]]) ((void (*)(id, SEL, id))objc_msgSend)(view, setters[i], UIColor.whiteColor);
    }
    SEL setActive = NSSelectorFromString(@"setIsActive:");
    if ([view respondsToSelector:setActive]) ((void (*)(id, SEL, BOOL))objc_msgSend)(view, setActive, active);
    [view layoutIfNeeded];
    return EeveeRenderTemplate(view);
}

// Spotify's tab items answer a tap recognizer, so replay its target-action pairs like a real touch would.
// A control is pressed through the actions registered on it, which is what UIKit runs after a real touch. The tap
// recognizer a button carries belongs to the system's own machinery (pointer, focus, menus); replaying it never
// reaches those actions.
static BOOL EeveePressControl(UIControl *control) {
    UIControlEvents registered = control.allControlEvents;
    if (!control.enabled || !(registered & (UIControlEventTouchUpInside | UIControlEventPrimaryActionTriggered))) return NO;
    [control sendActionsForControlEvents:UIControlEventTouchUpInside | UIControlEventPrimaryActionTriggered];
    return YES;
}

BOOL EeveeFireTap(UIView *root) {
    if ([root isKindOfClass:UIControl.class]) {
        [(UIControl *)root sendActionsForControlEvents:UIControlEventTouchUpInside | UIControlEventPrimaryActionTriggered];
        return YES;
    }
    Ivar targetsIvar = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
    if (!targetsIvar) return NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:view.subviews];
        if ([view isKindOfClass:UIControl.class] && EeveePressControl((UIControl *)view)) return YES;
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            if (![recognizer isKindOfClass:UITapGestureRecognizer.class] || !recognizer.enabled) continue;
            BOOL fired = NO;
            for (id pair in object_getIvar(recognizer, targetsIvar)) {
                Ivar targetIvar = class_getInstanceVariable([pair class], "_target");
                Ivar actionIvar = class_getInstanceVariable([pair class], "_action");
                if (!targetIvar || !actionIvar) continue;
                id target = object_getIvar(pair, targetIvar);
                SEL action = *(SEL *)((char *)(__bridge void *)pair + ivar_getOffset(actionIvar));
                if (!target || !action || ![target respondsToSelector:action]) continue;
                ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
                fired = YES;
            }
            if (fired) return YES;
        }
        if ([view isKindOfClass:UIControl.class] && view != root) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }
    return NO;
}

static char kColorSinkKey;

// Instance-only subclass of the view's layer, so Spotify's later repaints (UIView or CALayer setter) land in the sink.
BOOL EeveeInterceptBackground(UIView *view, void (^sink)(UIColor *color)) {
    CALayer *layer = view.layer;
    Class original = object_getClass(layer);
    NSString *originalName = NSStringFromClass(original);
    objc_setAssociatedObject(layer, &kColorSinkKey, sink, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if ([originalName hasPrefix:@"EeveeBG_"]) return YES;
    if ([originalName containsString:@"."] || [originalName hasPrefix:@"NSKVONotifying_"]) return NO;

    NSString *name = [@"EeveeBG_" stringByAppendingString:originalName];
    Class subclass = NSClassFromString(name);
    if (!subclass) {
        subclass = objc_allocateClassPair(original, name.UTF8String, 0);
        if (!subclass) return NO;
        IMP setter = imp_implementationWithBlock(^(CALayer *self_, CGColorRef color) {
            void (^current)(UIColor *) = objc_getAssociatedObject(self_, &kColorSinkKey);
            if (current && color && CGColorGetAlpha(color) > 0.01) current([UIColor colorWithCGColor:color]);
            struct objc_super parent = {self_, original};
            ((void (*)(struct objc_super *, SEL, CGColorRef))objc_msgSendSuper)(&parent, @selector(setBackgroundColor:), current ? NULL : color);
        });
        class_addMethod(subclass, @selector(setBackgroundColor:), setter, "v@:^{CGColor=}");
        class_addMethod(subclass, @selector(class), imp_implementationWithBlock(^Class(id self_) { return original; }), "#@:");
        objc_registerClassPair(subclass);
    }
    CGColorRef existing = CGColorRetain(layer.backgroundColor);
    object_setClass(layer, subclass);
    layer.backgroundColor = existing;
    CGColorRelease(existing);
    return YES;
}

static char kPinsKey;

// Instance-only subclass that forces an object setter to a pinned value, e.g. keeping a label white when Spotify repaints it.
BOOL EeveePinSetter(id object, SEL setter, id value) {
    Class current = object_getClass(object);
    NSString *currentName = NSStringFromClass(current);
    BOOL pinned = [currentName hasPrefix:@"EeveePin_"];
    if (!pinned && ([currentName containsString:@"."] || [currentName hasPrefix:@"NSKVONotifying_"] || [currentName hasPrefix:@"EeveeBG_"])) return NO;

    Class original = pinned ? class_getSuperclass(current) : current;
    Class subclass = current;
    if (!pinned) {
        NSString *name = [@"EeveePin_" stringByAppendingString:currentName];
        subclass = NSClassFromString(name);
        if (!subclass) {
            subclass = objc_allocateClassPair(original, name.UTF8String, 0);
            if (!subclass) return NO;
            class_addMethod(subclass, @selector(class), imp_implementationWithBlock(^Class(id self_) { return original; }), "#@:");
            objc_registerClassPair(subclass);
        }
    }

    Method own = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(subclass, &count);
    for (unsigned int i = 0; i < count; i++) if (method_getName(methods[i]) == setter) own = methods[i];
    free(methods);
    if (!own) {
        NSString *key = NSStringFromSelector(setter);
        IMP imp = imp_implementationWithBlock(^(id self_, id incoming) {
            id forced = [objc_getAssociatedObject(self_, &kPinsKey) objectForKey:key];
            struct objc_super parent = {self_, original};
            ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&parent, setter, forced ?: incoming);
        });
        class_addMethod(subclass, setter, imp, "v@:@");
    }

    NSMutableDictionary *pins = objc_getAssociatedObject(object, &kPinsKey) ?: [NSMutableDictionary dictionary];
    pins[NSStringFromSelector(setter)] = value;
    objc_setAssociatedObject(object, &kPinsKey, pins, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!pinned) object_setClass(object, subclass);
    ((void (*)(id, SEL, id))objc_msgSend)(object, setter, value);
    return YES;
}
