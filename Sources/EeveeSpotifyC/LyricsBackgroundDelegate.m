#import "Tweak.h"
#import <objc/runtime.h>

typedef void (^LyricsSessionCompletion)(void);
typedef BOOL (^LyricsSessionHandler)(NSString *, LyricsSessionCompletion);
typedef void (*LyricsSessionIMP)(id, SEL, UIApplication *, NSString *, LyricsSessionCompletion);

static LyricsSessionHandler lyricsHandler;
static NSMutableSet<Class> *lyricsDelegateClasses;

static void PrepareLyricsDelegate(id<UIApplicationDelegate> delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if ([lyricsDelegateClasses containsObject:cls]) return;
    SEL selector = @selector(application:handleEventsForBackgroundURLSession:completionHandler:);
    Method inherited = class_getInstanceMethod(cls, selector);
    // Leave dynamic forwarding to the host if there is no implementation to chain.
    if (!inherited && [delegate respondsToSelector:selector]) return;
    LyricsSessionIMP previous = inherited ? (LyricsSessionIMP)method_getImplementation(inherited) : NULL;
    const char *types = inherited ? method_getTypeEncoding(inherited) : "v@:@@@?";
    IMP implementation = imp_implementationWithBlock(
        ^(id self, UIApplication *application, NSString *identifier, LyricsSessionCompletion completion) {
        if (lyricsHandler(identifier, completion)) return;
        if (previous) previous(self, selector, application, identifier, completion);
        else completion();
    });
    class_replaceMethod(cls, selector, implementation, types);
    [lyricsDelegateClasses addObject:cls];
}

void EeveeInstallRetiredLyricsSessionDelegate(LyricsSessionHandler handler) {
    if (lyricsHandler) return;
    lyricsHandler = [handler copy];
    lyricsDelegateClasses = [NSMutableSet new];
    SEL setter = @selector(setDelegate:);
    Method method = class_getInstanceMethod(UIApplication.class, setter);
    if (!method) return;
    void (*previousSetter)(UIApplication *, SEL, id<UIApplicationDelegate>) = (void *)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(
        ^(UIApplication *application, id<UIApplicationDelegate> delegate) {
        PrepareLyricsDelegate(delegate);
        previousSetter(application, setter, delegate);
    }));
    UIApplication *application = UIApplication.sharedApplication;
    if (application.delegate) application.delegate = application.delegate;
}
