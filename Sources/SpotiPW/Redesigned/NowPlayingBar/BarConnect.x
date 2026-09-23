// The device button of the now playing bar, hidden on request. The redesign keeps Spotify's own buttons
// on its glass card, so the button and the way to hide it are the native look's, copied over.
//
// Tree (trees/test6.txt): the button row is a UIStackView holding Connect_EntryPointsImpl.ConnectStateView
// (the connected device) and .ConnectButtonView, each wrapped; hiding the wrapper closes the gap.
// The ConnectStateView under the title ("playing on ...") sits in InformationContainer and stays.
#import "Core/SGCore.h"
#import "NowPlayingBar.h"

static BOOL insideClass(UIView *view, NSString *marker) {
    for (UIView *v = view; v; v = v.superview) if ([NSStringFromClass(v.class) containsString:marker]) return YES;
    return NO;
}

static void hideConnectButton(UIView *bar) {
    SGForEachView(bar, ^(UIView *v) {
        NSString *name = NSStringFromClass(v.class);
        if (![name containsString:@"ConnectButtonView"] && ![name containsString:@"ConnectStateView"]) return;
        if (insideClass(v, @"InformationContainer")) return;
        UIView *item = v;
        while (item.superview && ![item.superview isKindOfClass:UIStackView.class]) item = item.superview;
        if (item.superview && !item.hidden) item.hidden = YES;
    });
}

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    hideConnectButton(((UIViewController *)self).view);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGHidden(SGRHideBarConnect)) return;
    %init;
    SGRequireClasses(@[@"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController"]);
}
