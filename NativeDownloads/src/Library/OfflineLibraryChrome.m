#import "OfflineLibraryChrome.h"
#import "OfflineLibraryChromeGeometry.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSHashTable<SAPOfflineLibraryChrome *> *listeners;
static void notifyLayout(void) {
    for(SAPOfflineLibraryChrome *listener in listeners.allObjects)if(listener.changed)listener.changed();
}
static void followLayout(Class cls,SEL selector) {
    if(!cls)return;static NSMutableSet *installed;static dispatch_once_t once;
    dispatch_once(&once,^{installed=NSMutableSet.set;});
    NSString *key=[NSString stringWithFormat:@"%@:%@",NSStringFromClass(cls),NSStringFromSelector(selector)];
    if([installed containsObject:key])return;
    Method method=class_getInstanceMethod(cls,selector);if(!method)return;
    IMP original=method_getImplementation(method);
    // Override this exact Spotify/Vitrine class only. Preserve its full mod chain,
    // including inherited implementations; never replace UIView/UIViewController.
    IMP replacement=imp_implementationWithBlock(^(id object){
        ((void(*)(id,SEL))original)(object,selector);
        if(listeners.count)notifyLayout();
    });
    if(!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls,selector),replacement);
    [installed addObject:key];
}
@interface SAPOfflineLibraryChrome ()
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic,strong) NSHashTable<UIView *> *views;
@property(nonatomic) BOOL attached;
@end
@implementation SAPOfflineLibraryChrome
- (void)collectViews:(UIView *)view depth:(NSUInteger)depth {
    if(depth>5)return;
    if([NSStringFromClass(view.class)isEqual:@"SGRTabBarHost"])[self.views addObject:view];
    for(UIView *child in view.subviews)[self collectViews:child depth:depth+1];
}
- (void)collect:(UIViewController *)controller depth:(NSUInteger)depth {
    if(!controller || depth>20)return;
    NSString *name=NSStringFromClass(controller.class);
    if([name containsString:@"NowPlayingBarContainerViewController"] || [name containsString:@"NowPlayingBarViewController"])
        if(controller.isViewLoaded)[self.views addObject:controller.view];
    if([controller isKindOfClass:UITabBarController.class]) {
        UITabBar *tab=((UITabBarController *)controller).tabBar;[self.views addObject:tab];[self collectViews:tab depth:0];
    }
    if([name isEqual:@"NavigationUI_TabBarImpl.TabBarContainerImpl"] || [name isEqual:@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"]) {
        SEL selector=NSSelectorFromString(@"tabBarView");
        if([controller respondsToSelector:selector]) {
            id bar=((id(*)(id,SEL))objc_msgSend)(controller,selector);
            if([bar isKindOfClass:UIView.class]){[self.views addObject:bar];[self collectViews:bar depth:0];}
        }
    }
    for(UIViewController *child in controller.childViewControllers)[self collect:child depth:depth+1];
}
- (void)attachToView:(UIView *)view {
    UIWindow *window=view.window;if(!window)return;
    if(self.attached && self.window==window)return;
    self.attached=YES;self.window=window;self.views=[NSHashTable weakObjectsHashTable];
    [self collect:window.rootViewController depth:0];
    static dispatch_once_t once;dispatch_once(&once,^{listeners=[NSHashTable weakObjectsHashTable];});
    [listeners addObject:self];
    for(NSString *name in @[@"NowPlaying_BarImpl.NowPlayingBarContainerViewController",@"_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController",@"NowPlaying_BarImpl.NowPlayingBarViewController",@"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",@"NavigationUI_TabBarImpl.TabBarContainerImpl",@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"])
        followLayout(NSClassFromString(name),@selector(viewDidLayoutSubviews));
    followLayout(NSClassFromString(@"SGRTabBarHost"),@selector(layoutSubviews));
}
- (void)detach {self.attached=NO;[listeners removeObject:self];}
- (void)dealloc {[listeners removeObject:self];}
- (CGFloat)coverageInView:(UIView *)view {
    UIWindow *window=view.window;if(!window)return view.safeAreaInsets.bottom;
    CGRect viewport=[view convertRect:view.bounds toView:window];NSMutableArray *rectangles=NSMutableArray.array;
    for(UIView *bar in self.views) {
        BOOL visible=bar.window==window;
        for(UIView *parent=bar;visible && parent;parent=parent.superview)if(parent.hidden || parent.alpha<.01)visible=NO;
        if(visible)[rectangles addObject:[NSValue valueWithCGRect:[bar convertRect:bar.bounds toView:window]]];
    }
    typedef CGRect(*CardFrame)(UIView *,CGFloat *);static CardFrame frame;static dispatch_once_t once;
    dispatch_once(&once,^{frame=(CardFrame)dlsym(RTLD_DEFAULT,"SGRNowPlayingCardFrameIn");});
    if(frame){CGRect card=frame(window,NULL);if(!CGRectIsNull(card))[rectangles addObject:[NSValue valueWithCGRect:card]];}
    CGFloat safeBottom=MIN(CGRectGetMaxY(viewport)-view.safeAreaInsets.bottom,CGRectGetMaxY(window.bounds)-window.safeAreaInsets.bottom);
    return SAPOfflineChromeCoverage(viewport,safeBottom,rectangles);
}
@end
