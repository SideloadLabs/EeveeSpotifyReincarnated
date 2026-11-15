// Artist-page download button for the stock Eevee build (moved out of the Eevee dylib).
// Native artist downloads use a non-arranged control in Spotify's existing action row.
// Spotify owns the row and its arranged views; none of those views are moved or hidden here.
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import "ArtistDownloadsUI.h"
#import "ArtistPageButton.h"

static void SAPArtistPageForEachView(UIView *root, void (^visit)(UIView *)) {
    if (!root) return;
    visit(root);
    for (UIView *child in root.subviews) SAPArtistPageForEachView(child, visit);
}

static UIView *SAPArtistPageDownloadGlyph(UIColor *color) {
    Class cls = NSClassFromString(@"SPTEncoreIcon");
    SEL download = NSSelectorFromString(@"download");
    if ([cls respondsToSelector:download]) {
        id icon = ((id (*)(id, SEL))objc_msgSend)(cls, download);
        Class viewClass = NSClassFromString(@"SPTEncoreIconView");
        SEL init = NSSelectorFromString(@"initWithIcon:");
        if (icon && [viewClass instancesRespondToSelector:init]) {
            void *allocated = ((void *(*)(id, SEL))objc_msgSend)(viewClass, @selector(alloc));
            UIView *view = CFBridgingRelease(((void *(*)(void *, SEL, id))objc_msgSend)(allocated, init, icon));
            SEL setColor = NSSelectorFromString(@"setForegroundColor:");
            if ([view respondsToSelector:setColor]) ((void (*)(id, SEL, id))objc_msgSend)(view, setColor, color);
            if (view) return view;
        }
    }
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]];
    view.tintColor = color;
    view.contentMode = UIViewContentModeCenter;
    return view;
}

static char kNativeArtistDownloadContext;
static NSString *const kArtistMenuPrefix = @"Components.UI.ContextMenuButton-";
static NSString *const kArtistPageIdentifier = @"creator-page";
static NSString *const kShuffleIdentifier = @"Components.UI.ShuffleButton";
static NSString *const kTitleIdentifier = @"Encore.AdaptiveTitle";

static NSCharacterSet *invalidArtistIdentifierCharacters(void) {
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [NSCharacterSet characterSetWithCharactersInString:
            @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"].invertedSet;
    });
    return invalid;
}

static NSString *artistURI(NSString *value) {
    NSString *prefix = @"spotify:artist:";
    if (![value isKindOfClass:NSString.class] || ![value hasPrefix:prefix]) return nil;
    NSString *identifier = [value substringFromIndex:prefix.length];
    return identifier.length == 22 && [identifier rangeOfCharacterFromSet:invalidArtistIdentifierCharacters()].location == NSNotFound
        ? value : nil;
}

static SEL pageURISelector(void) {
    static SEL selector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ selector = NSSelectorFromString(@"spt_pageURI"); });
    return selector;
}

// The glass appearance moves More into UINavigationItem, outside the header tree.
// Resolve that native identity first; the named creative-work model is the fallback.
static NSString *navigationArtistURI(UIViewController *controller) {
    for (UIBarButtonItem *item in controller.navigationItem.rightBarButtonItems) {
        NSString *identifier = item.accessibilityIdentifier;
        if ([identifier hasPrefix:kArtistMenuPrefix]) {
            NSString *uri = artistURI([@"spotify:artist:" stringByAppendingString:[identifier substringFromIndex:kArtistMenuPrefix.length]]);
            if (uri) return uri;
        }
        __block NSString *uri = nil;
        SAPArtistPageForEachView(item.customView, ^(UIView *view) {
            NSString *identifier = view.accessibilityIdentifier;
            if (!uri && [identifier hasPrefix:kArtistMenuPrefix])
                uri = artistURI([@"spotify:artist:" stringByAppendingString:[identifier substringFromIndex:kArtistMenuPrefix.length]]);
        });
        if (uri) return uri;
    }
    return nil;
}

static NSString *modelArtistURI(UIViewController *controller) {
    static Class identity;
    static SEL selector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        identity = NSClassFromString(@"EeveePixieArtistIdentity");
        selector = NSSelectorFromString(@"artistURI:");
    });
    if (![identity respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL, id))objc_msgSend)(identity, selector, controller);
    return artistURI(value);
}

// The page and presenter classes are stable across a layout pass. Cache only method metadata;
// the page URI itself is read again when identity needs refreshing.
static Method pageURIMethodForClass(Class cls) {
    static NSMapTable<Class, id> *methods;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        methods = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                        valueOptions:NSPointerFunctionsStrongMemory];
    });

    @synchronized (methods) {
        id cached = [methods objectForKey:cls];
        if (cached) return (Method)[cached pointerValue];

        SEL selector = pageURISelector();
        Method method = class_getInstanceMethod(cls, selector);
        char type[16] = {0};
        BOOL valid = method && method_getNumberOfArguments(method) == 2;
        if (valid) {
            method_getReturnType(method, type, sizeof(type));
            valid = type[0] == '@';
        }
        if (valid) [methods setObject:[NSValue valueWithPointer:method] forKey:cls];
        return valid ? method : NULL;
    }
}

@interface SAPArtistPageArtistDownloadContext : NSObject
@property(nonatomic, weak) UIView *header, *menu, *shuffle, *titleView, *row, *page;
@property(nonatomic, weak) UIView *menuParent, *shuffleParent;
@property(nonatomic, weak) UIView *constraintMenu, *constraintRow;
@property(nonatomic, weak) UILabel *titleLabel;
@property(nonatomic, weak) UIViewController *presenter, *uriResponder;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic) BOOL externallyHosted;
@property(nonatomic, copy) NSArray<NSLayoutConstraint *> *constraints;
@property(nonatomic, copy) NSString *uri, *name, *menuIdentifier, *headerURI;
- (void)open;
@end

static BOOL isDescendant(UIView *view, UIView *ancestor) {
    return view && ancestor && view != ancestor && [view isDescendantOfView:ancestor];
}

static UIView *creatorPageForHeader(UIView *header, SAPArtistPageArtistDownloadContext *context) {
    UIView *cached = context.page;
    if ([cached.accessibilityIdentifier isEqualToString:kArtistPageIdentifier] && isDescendant(header, cached)) {
        for (UIView *view = header; view && view != cached; view = view.superview) {
            if ([view.accessibilityIdentifier isEqualToString:kArtistPageIdentifier]) return view;
        }
        return cached;
    }
    for (UIView *view = header; view; view = view.superview) {
        if ([view.accessibilityIdentifier isEqualToString:kArtistPageIdentifier]) return view;
    }
    return nil;
}

static BOOL isHorizontalActionRow(UIView *row, UIView *header, UIView *menu, UIView *shuffle) {
    if (!row || row == header || !isDescendant(row, header) || !isDescendant(menu, row) || !isDescendant(shuffle, row)) return NO;
    return ![row isKindOfClass:UIStackView.class] || ((UIStackView *)row).axis == UILayoutConstraintAxisHorizontal;
}

static UIView *commonActionRow(UIView *header, UIView *menu, UIView *shuffle) {
    for (UIView *row = menu.superview; row && row != header; row = row.superview) {
        if ([shuffle isDescendantOfView:row] && isHorizontalActionRow(row, header, menu, shuffle)) return row;
    }
    return nil;
}

static BOOL cachedAnchorsValid(SAPArtistPageArtistDownloadContext *context, UIView *header) {
    UIView *menu = context.menu, *shuffle = context.shuffle, *title = context.titleView;
    UILabel *label = context.titleLabel;
    if (context.externallyHosted) {
        UIView *page = creatorPageForHeader(header, context);
        if (context.header != header || (title && !isDescendant(title, header))) return NO;
        if (menu) return isDescendant(menu, page) && [menu.accessibilityIdentifier hasPrefix:kArtistMenuPrefix];
        return context.uri != nil;
    }
    if (context.header != header || !isDescendant(menu, header) || ![menu.accessibilityIdentifier hasPrefix:kArtistMenuPrefix] ||
        !isDescendant(shuffle, header) || ![shuffle.accessibilityIdentifier isEqualToString:kShuffleIdentifier] ||
        !isDescendant(title, header) || ![title.accessibilityIdentifier isEqualToString:kTitleIdentifier] ||
        !(label == title || isDescendant(label, title)) ||
        context.menuParent != menu.superview || context.shuffleParent != shuffle.superview) return NO;
    if (!isHorizontalActionRow(context.row, header, menu, shuffle)) return NO;
    return YES;
}

static void cacheAnchors(SAPArtistPageArtistDownloadContext *context, UIView *header) {
    __block UIView *menu = nil, *shuffle = nil, *title = nil;
    __block UILabel *label = nil;
    SAPArtistPageForEachView(header, ^(UIView *view) {
        NSString *identifier = view.accessibilityIdentifier;
        if (!menu && [identifier hasPrefix:kArtistMenuPrefix]) menu = view;
        if (!shuffle && [identifier isEqualToString:kShuffleIdentifier]) shuffle = view;
        if (!title && [identifier isEqualToString:kTitleIdentifier]) title = view;
        if (title && !label && [view isKindOfClass:UILabel.class] && (view == title || isDescendant(view, title))) {
            label = (UILabel *)view;
        }
    });

    if (context.externallyHosted && !menu) {
        // The glass header keeps More in the page's navigation area, outside its controls.
        UIView *page = creatorPageForHeader(header, context);
        static Class imageHeaderClass;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ imageHeaderClass = NSClassFromString(@"_TtC35CreativeWorkPlatform_ImageHeaderKit15ImageHeaderView"); });
        __block UIView *identityRoot = nil;
        SAPArtistPageForEachView(page, ^(UIView *view) {
            if (!identityRoot && imageHeaderClass && [view isKindOfClass:imageHeaderClass]) identityRoot = view;
        });
        // Restrict URI fallback to this artist header, never a track's menu below it.
        SAPArtistPageForEachView(identityRoot, ^(UIView *view) {
            if (!menu && [view.accessibilityIdentifier hasPrefix:kArtistMenuPrefix]) menu = view;
        });
    }
    UIView *row = commonActionRow(header, menu, shuffle);
    BOOL changedIdentitySource = context.menu != menu || ![context.menuIdentifier isEqualToString:menu.accessibilityIdentifier];
    context.header = header;
    context.menu = menu;
    context.shuffle = shuffle;
    context.menuParent = menu.superview;
    context.shuffleParent = shuffle.superview;
    context.titleView = title;
    context.titleLabel = label;
    context.row = row;
    context.menuIdentifier = [menu.accessibilityIdentifier copy];
    if (changedIdentitySource) {
        context.headerURI = artistURI([context.menuIdentifier hasPrefix:kArtistMenuPrefix]
            ? [@"spotify:artist:" stringByAppendingString:[context.menuIdentifier substringFromIndex:kArtistMenuPrefix.length]] : nil);
        context.uriResponder = nil;
    }
}

static NSString *controllerArtistURI(UIViewController *controller) {
    Method method = pageURIMethodForClass(object_getClass(controller));
    if (method) {
        id value = ((id (*)(id, SEL))objc_msgSend)(controller, pageURISelector());
        NSString *uri = [value isKindOfClass:NSURL.class] ? artistURI([value absoluteString]) : artistURI(value);
        if (uri) return uri;
    }
    return navigationArtistURI(controller) ?: modelArtistURI(controller);
}

static NSString *freshPageURI(UIView *page, SAPArtistPageArtistDownloadContext *context, UIViewController **presenterOut) {
    UIViewController *firstPresenter = nil;
    for (UIResponder *responder = page; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *controller = (UIViewController *)responder;
        if (!firstPresenter) firstPresenter = controller;
        NSString *uri = controllerArtistURI(controller);
        if (!uri) continue;
        context.uriResponder = controller;
        if (presenterOut) *presenterOut = controller;
        return uri;
    }
    // A child template's responder chain can end before the owning creative-work controller.
    for (UIViewController *controller = firstPresenter.parentViewController; controller; controller = controller.parentViewController) {
        NSString *uri = controllerArtistURI(controller);
        if (!uri) continue;
        context.uriResponder = controller;
        if (presenterOut) *presenterOut = controller;
        return uri;
    }
    context.uriResponder = nil;
    if (presenterOut) *presenterOut = firstPresenter;
    return nil;
}

static void setUnavailable(SAPArtistPageArtistDownloadContext *context) {
    if (!context) return;
    context.uri = nil;
    if (!context.button.hidden) context.button.hidden = YES;
    if (context.button.enabled) context.button.enabled = NO;
}

static void updateDownloads(UIView *header);

@implementation SAPArtistPageArtistDownloadContext
- (void)open {
    UIView *header = self.header;
    if (!header) return;
    updateDownloads(header);
    if (!self.button.hidden && self.button.enabled && self.uri && self.presenter) {
        SAPShowArtistDownloads(self.uri, self.name ?: @"Artist", self.presenter);
    }
}
@end

static void updateDownloads(UIView *header) {
    if (!header) return;
    SAPArtistPageArtistDownloadContext *context = objc_getAssociatedObject(header, &kNativeArtistDownloadContext);
    UIView *page = creatorPageForHeader(header, context);
    if (!page) {
        setUnavailable(context);
        if (context) context.page = nil;
        return;
    }

    if (!context || !cachedAnchorsValid(context, header)) {
        if (!context) {
            context = [SAPArtistPageArtistDownloadContext new];
            context.header = header;
            objc_setAssociatedObject(header, &kNativeArtistDownloadContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        cacheAnchors(context, header);
    }

    UIView *menu = context.menu, *shuffle = context.shuffle, *row = context.row;
    NSString *menuIdentifier = menu.accessibilityIdentifier;
    if (![context.menuIdentifier isEqualToString:menuIdentifier]) {
        context.menuIdentifier = [menuIdentifier copy];
        context.headerURI = artistURI([menuIdentifier hasPrefix:kArtistMenuPrefix]
            ? [@"spotify:artist:" stringByAppendingString:[menuIdentifier substringFromIndex:kArtistMenuPrefix.length]] : nil);
    }

    if ((!context.externallyHosted && (!menu || !shuffle || !isHorizontalActionRow(row, header, menu, shuffle))) ) {
        setUnavailable(context);
        return;
    }

    // Read the page URI on every update, including layout passes. The view anchors and method
    // metadata are cached, but a reused controller can change identity without changing views.
    UIViewController *presenter = nil;
    NSString *pageURI = freshPageURI(page, context, &presenter);
    context.page = page;
    context.presenter = presenter;

    NSString *uri = pageURI && context.headerURI && ![pageURI isEqualToString:context.headerURI]
        ? nil : pageURI ?: context.headerURI;
    if (!uri || !presenter) {
        setUnavailable(context);
        return;
    }

    if (!context.button) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        UIColor *color = [UIColor colorWithWhite:1 alpha:0.7];
        UIView *glyph = SAPArtistPageDownloadGlyph(color);
        glyph.translatesAutoresizingMaskIntoConstraints = NO;
        glyph.userInteractionEnabled = NO;
        glyph.accessibilityElementsHidden = YES;
        [button addSubview:glyph];
        [NSLayoutConstraint activateConstraints:@[
            [glyph.widthAnchor constraintEqualToConstant:24],
            [glyph.heightAnchor constraintEqualToConstant:24],
            [glyph.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
            [glyph.centerYAnchor constraintEqualToAnchor:button.centerYAnchor]
        ]];
        button.tintColor = color;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.accessibilityIdentifier = @"PixieNativeArtistDownload";
        button.accessibilityLabel = @"Artist downloads";
        [button addTarget:context action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        context.button = button;
    }

    context.uri = uri;
    context.presenter = presenter;
    NSString *name = context.titleLabel.text;
    if (![context.name isEqualToString:name]) context.name = name;
    if (context.externallyHosted) {
        if (context.button.hidden) context.button.hidden = NO;
        if (!context.button.enabled) context.button.enabled = YES;
        return;
    }
    if (context.constraintRow != row || context.constraintMenu != menu || context.button.superview != row) {
        [NSLayoutConstraint deactivateConstraints:context.constraints ?: @[]];
        if (context.button.superview != row) {
            [context.button removeFromSuperview];
            [row addSubview:context.button];
        }
        context.menu = menu;
        context.row = row;
        context.constraintMenu = menu;
        context.constraintRow = row;
        context.constraints = @[
            [context.button.leadingAnchor constraintEqualToAnchor:menu.trailingAnchor],
            [context.button.centerYAnchor constraintEqualToAnchor:menu.centerYAnchor],
            [context.button.widthAnchor constraintEqualToConstant:44],
            [context.button.heightAnchor constraintEqualToConstant:44]
        ];
        [NSLayoutConstraint activateConstraints:context.constraints];
    }

    CGRect menuFrame = [menu convertRect:menu.bounds toView:row];
    CGRect shuffleFrame = [shuffle convertRect:shuffle.bounds toView:row];
    BOOL fits = CGRectGetWidth(menuFrame) > 0 && CGRectGetMaxX(menuFrame) + 44 <= CGRectGetMinX(shuffleFrame) + 0.5;
    if (context.button.hidden == fits) context.button.hidden = !fits;
    if (!context.button.enabled) context.button.enabled = YES;
}

static void SAPArtistPageUpdateArtistDownloads(UIView *header, UIButton *externalButton) {
    if (!header) return;
    if (externalButton) {
        SAPArtistPageArtistDownloadContext *context = objc_getAssociatedObject(header, &kNativeArtistDownloadContext);
        if (!context) {
            context = [SAPArtistPageArtistDownloadContext new];
            context.header = header;
            objc_setAssociatedObject(header, &kNativeArtistDownloadContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (context.button != externalButton) {
            [context.button removeTarget:context action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
            context.button = externalButton;
            [externalButton addTarget:context action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        }
        context.externallyHosted = YES;
    }
    updateDownloads(header);
}

// Hooks that used to live in Eevee: relayout the button when Spotify lays out the artist header
// or its action stack. Original implementations always run first.
static void (*originalHeaderLayout)(id, SEL);
static void (*originalStackLayout)(id, SEL);
static Class artistHeaderClass;

static void headerLayout(UIView *self, SEL _cmd) {
    originalHeaderLayout(self, _cmd);
    SAPArtistPageUpdateArtistDownloads(self, nil);
}

static void stackLayout(UIStackView *self, SEL _cmd) {
    originalStackLayout(self, _cmd);
    UIView *header = self.superview;
    if (header && artistHeaderClass && [header isKindOfClass:artistHeaderClass]) SAPArtistPageUpdateArtistDownloads(header, nil);
}

// With Eevee's Liquid Glass playlist pages the artist header's own controls are hidden and Eevee's
// action row hosts the button (through SAPUpdateArtistDownloadsExternal); hooking the header too
// would add a second, invisible button over Spotify's hidden controls.
static BOOL eeveeGlassArtistActive(void) {
    if (@available(iOS 26.0, *)) {
        NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:@"eeveeLiquidGlassOptions"];
        id options = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![options isKindOfClass:NSDictionary.class]) return NO;
        id playlist = options[@"playlist"];
        return [options[@"enabled"] boolValue] && !([playlist isKindOfClass:NSNumber.class] && ![playlist boolValue]);
    }
    return NO;
}

void SAPInstallArtistPageButton(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ SAPInstallArtistPageButton(); }); return; }
    static BOOL installed;
    if (installed || eeveeGlassArtistActive()) return;
    Class header = NSClassFromString(@"_TtC35CreativeWorkPlatform_ImageHeaderKit15ImageHeaderView");
    SEL layout = @selector(layoutSubviews);
    Method headerMethod = header ? class_getInstanceMethod(header, layout) : NULL;
    Method stackMethod = class_getInstanceMethod(UIStackView.class, layout);
    if (!headerMethod || !stackMethod) return;
    installed = YES;
    artistHeaderClass = header;
    originalHeaderLayout = (void (*)(id, SEL))method_getImplementation(headerMethod);
    originalStackLayout = (void (*)(id, SEL))method_getImplementation(stackMethod);
    class_replaceMethod(header, layout, (IMP)headerLayout, method_getTypeEncoding(headerMethod));
    class_replaceMethod(UIStackView.class, layout, (IMP)stackLayout, method_getTypeEncoding(stackMethod));
}

void SAPUpdateArtistDownloadsExternal(UIView *header, UIButton *externalButton) {
    SAPArtistPageUpdateArtistDownloads(header, externalButton);
}

NSString *SAPArtistURIForHeader(UIView *header) {
    SAPArtistPageArtistDownloadContext *context = header ? objc_getAssociatedObject(header, &kNativeArtistDownloadContext) : nil;
    return context.uri;
}
