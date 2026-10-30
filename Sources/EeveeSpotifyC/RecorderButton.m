// RecorderButton.m - REC button placed above the 74.67pt Lottie view, toast with share/copy, debug panel.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "EVRecorderInternal.h"

typedef NS_ENUM(NSInteger, EVRecState) { EVRecIdle, EVRecStarting, EVRecRecording, EVRecStopping };

#pragma mark - Helpers

// Passthrough window: only the views we add react to touches. Used for the toast and the floating fallback.
@interface EVRecWindow : UIWindow
@end
@implementation EVRecWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

static UIWindowScene *EVScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback) fallback = (UIWindowScene *)s;
    }
    return fallback;
}

static UIViewController *EVTopVC(void) {
    UIWindow *best = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if ([w isKindOfClass:EVRecWindow.class] || w.isHidden || !w.rootViewController) continue;
            if (w.isKeyWindow) return ({ UIViewController *vc = w.rootViewController;
                while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController; vc; });
            if (!best) best = w;
        }
    }
    UIViewController *vc = best.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

static NSString *EVChain(UIView *v) {
    NSMutableArray *parts = [NSMutableArray array];
    for (int i = 0; v && i < 7; i++, v = v.superview)
        [parts addObject:[NSString stringWithFormat:@"%@(%.0f,%.0f %.1fx%.1f)", NSStringFromClass(v.class), v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height]];
    return [parts componentsJoinedByString:@" < "];
}

static void EVCollectLottie(UIView *v, NSMutableArray *out, int depth) {
    if (depth > 60) return;
    if ([NSStringFromClass(v.class) containsString:@"LottieAnimationView"]) [out addObject:v];
    for (UIView *s in v.subviews) EVCollectLottie(s, out, depth + 1);
}

static NSArray<UIView *> *EVAllLottie(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows)
            if (![w isKindOfClass:EVRecWindow.class] && !w.isHidden) EVCollectLottie(w, all, 0);
    }
    return all;
}

// Lottie views of the target size (74.6667 x 74.6667); those at origin (0,0) come first.
static NSArray<UIView *> *EVLottieCandidates(void) {
    const CGFloat target = 74.6667, tol = 0.8;
    NSMutableArray *zero = [NSMutableArray array], *other = [NSMutableArray array];
    for (UIView *v in EVAllLottie()) {
        if (!v.window || v.isHidden || v.superview == nil) continue;
        if (fabs(v.bounds.size.width - target) > tol || fabs(v.bounds.size.height - target) > tol) continue;
        if (fabs(v.frame.origin.x) <= tol && fabs(v.frame.origin.y) <= tol) [zero addObject:v]; else [other addObject:v];
    }
    [zero addObjectsFromArray:other];
    return zero;
}

#pragma mark - Button

@interface EVRecButton : UIControl
@property (nonatomic, strong) UIView *ring, *dot;
- (void)showIdle;
- (void)showSolidRed;
- (void)showBlink;
- (void)showWarning;
@end

@implementation EVRecButton
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;
    _ring = [UIView new]; _ring.userInteractionEnabled = NO;
    _ring.layer.borderWidth = 2; _ring.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    _dot = [UIView new]; _dot.userInteractionEnabled = NO;
    [self addSubview:_ring]; [self addSubview:_dot];
    self.isAccessibilityElement = YES; self.accessibilityLabel = @"Record";
    [self showIdle];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGPoint c = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    self.ring.bounds = CGRectMake(0, 0, 30, 30); self.ring.center = c; self.ring.layer.cornerRadius = 15;
    self.dot.bounds = CGRectMake(0, 0, 18, 18); self.dot.center = c; self.dot.layer.cornerRadius = 9;
}
- (void)showIdle { [self.dot.layer removeAllAnimations]; self.dot.backgroundColor = UIColor.systemGreenColor; }
- (void)showSolidRed {
    [self.dot.layer removeAllAnimations];
    [UIView animateWithDuration:0.25 animations:^{ self.dot.backgroundColor = UIColor.systemRedColor; }];
}
- (void)showWarning { [self.dot.layer removeAllAnimations]; self.dot.backgroundColor = UIColor.systemOrangeColor; }
- (void)showBlink {
    [self.dot.layer removeAllAnimations];
    self.dot.backgroundColor = UIColor.systemRedColor;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
    a.fromValue = (id)UIColor.systemGrayColor.CGColor;
    a.toValue = (id)UIColor.systemRedColor.CGColor;
    a.duration = 0.6; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
    [self.dot.layer addAnimation:a forKey:@"blink"];
}
@end

#pragma mark - Toast

@interface EVToastView : UIVisualEffectView
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *titleLabel, *subLabel;
@end

@implementation EVToastView
- (instancetype)init {
    self = [super initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    if (!self) return nil;
    self.layer.cornerRadius = 14; self.clipsToBounds = YES;
    _thumb = [UIImageView new]; _thumb.layer.cornerRadius = 8; _thumb.clipsToBounds = YES;
    _thumb.contentMode = UIViewContentModeScaleAspectFill;
    [_thumb.widthAnchor constraintEqualToConstant:44].active = YES;
    [_thumb.heightAnchor constraintEqualToConstant:44].active = YES;
    _titleLabel = [UILabel new]; _titleLabel.font = [UIFont boldSystemFontOfSize:15]; _titleLabel.textColor = UIColor.whiteColor;
    _subLabel = [UILabel new]; _subLabel.font = [UIFont systemFontOfSize:12]; _subLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _subLabel.numberOfLines = 3;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subLabel]];
    texts.axis = UILayoutConstraintAxisVertical; texts.spacing = 2;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_thumb, texts]];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 12; row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [row.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10]]];
    return self;
}
@end

#pragma mark - Debug panel

@interface EVDebugVC : UIViewController
@property (nonatomic, strong) UITextView *text;
@property (nonatomic, strong) NSTimer *timer;
@end

#pragma mark - UI controller

@interface EVRecUI : NSObject
@property (nonatomic, strong) EVRecButton *button;
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic, assign) EVRecState state;
@property (nonatomic, assign) NSUInteger token, toastToken;
@property (nonatomic, assign) BOOL floating;
@property (nonatomic, assign) NSTimeInterval anchorMissingSince;
@property (nonatomic, assign) NSUInteger candidateCount;
@property (nonatomic, copy) NSString *hostDesc;
@property (nonatomic, strong) EVRecWindow *toastWindow, *floatWindow;
@property (nonatomic, strong) EVToastView *toast;
@property (nonatomic, strong) NSArray<NSURL *> *shareFiles;
@property (nonatomic, strong) NSURL *lastFolder;
@property (nonatomic, copy) NSString *toastSummary;
+ (instancetype)shared;
- (void)start;
- (void)nextAnchor;
- (void)dumpLottieToLog;
- (void)shareURLs:(NSArray<NSURL *> *)urls;
- (void)showToastTitle:(NSString *)title sub:(NSString *)sub image:(UIImage *)img duration:(NSTimeInterval)d;
- (NSArray<NSString *> *)uiDebugLines;
- (NSArray<NSURL *> *)latestShareables;
- (NSURL *)latestFolder;
@end

@implementation EVRecUI

+ (instancetype)shared {
    static EVRecUI *u; static dispatch_once_t o;
    dispatch_once(&o, ^{ u = [EVRecUI new]; });
    return u;
}

- (void)start {
    self.button = [[EVRecButton alloc] initWithFrame:CGRectMake(0, 0, 74.6667, 74.6667)];
    [self.button addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressButton:)];
    lp.minimumPressDuration = 0.8;
    [self.button addGestureRecognizer:lp];
    [self.button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(reconcile) name:EeveeRecorderStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(finished:) name:EeveeRecorderDidFinishNotification object:nil];
    [nc addObserver:self selector:@selector(appActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appInactive) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(appTerminate) name:UIApplicationWillTerminateNotification object:nil];
    EVLogSetAppState(UIApplication.sharedApplication.applicationState == UIApplicationStateActive ? 0 : 2);

    [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:YES block:^(NSTimer *t) { [self scanTick]; [self reconcile]; }];
    EVI("UI", @"UI started");
    [self scanTick];
}

#pragma mark app state

- (void)appActive { EVLogSetAppState(0); EVI("UI", @"app active"); [self scanTick]; [self reconcile]; }
- (void)appInactive { EVLogSetAppState(1); }
- (void)appBackground {
    EVLogSetAppState(2);
    EVI("UI", @"app in background (recording=%d) - capture, metadata and writer keep running", EeveeAudioRecorderIsRecording());
}
- (void)appTerminate {
    EVW("UI", @"app terminating");
    if (EeveeAudioRecorderIsRecording()) EeveeAudioRecorderStop();   // closes the WAV; splitting resumes next launch
    EVLogFlush();
}

#pragma mark anchoring

- (void)scanTick {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    UIView *a = self.anchor;
    if (a && (!a.window || a.isHidden)) { [self.button removeFromSuperview]; self.anchor = nil; a = nil; }
    if (!a) {
        NSArray<UIView *> *c = EVLottieCandidates();
        self.candidateCount = c.count;
        if (c.count) {
            NSInteger i = MIN(MAX(EVSettingInt(@"anchorIndex", 0), 0), (NSInteger)c.count - 1);
            a = c[(NSUInteger)i];
            self.anchor = a;
            EVI("Anchor", @"using Lottie candidate %ld of %lu: %@", (long)i, (unsigned long)c.count, EVChain(a));
        }
    }
    if (a) {
        self.anchorMissingSince = 0;
        if (self.floating) [self hideFloating];
        [self placeAboveAnchor];
    } else {
        NSTimeInterval now = CACurrentMediaTime();
        if (!self.anchorMissingSince) { self.anchorMissingSince = now; EVW("Anchor", @"no Lottie view of 74.67x74.67 on screen yet"); }
        if (!self.floating && EVSettingBool(@"floatingFallback", YES) && now - self.anchorMissingSince > 20) {
            EVW("Anchor", @"anchor not found for 20 s - using the floating fallback");
            [self dumpLottieToLog];
            [self showFloating];
        }
    }
}

- (void)placeAboveAnchor {
    UIView *A = self.anchor, *sv = A.superview;
    if (!sv) return;
    CGRect fr = A.frame;
    CGRect options[2] = {CGRectOffset(fr, 0, -fr.size.height), CGRectOffset(fr, 0, fr.size.height)};
    NSString *names[2] = {@"above", @"below"};
    UIView *host = nil; CGRect rect = CGRectZero; NSString *where = nil;
    for (int pass = 0; pass < 2 && !host; pass++) {
        UIView *h = sv; CGRect r = options[pass];
        for (int i = 0; i < 8 && h; i++) {
            if (CGRectContainsRect(h.bounds, r)) { host = h; rect = r; where = names[pass]; break; }
            UIView *p = h.superview;
            if (!p) break;
            r = [h convertRect:r toView:p]; h = p;
        }
    }
    if (!host && A.window) {
        host = A.window; rect = [sv convertRect:options[0] toView:A.window]; where = @"above (window level)";
    }
    if (!host) return;
    if (self.button.superview != host) {
        [self.button removeFromSuperview];
        [host addSubview:self.button];
        self.hostDesc = [NSString stringWithFormat:@"%@ %@ in %@", where, NSStringFromCGRect(rect), NSStringFromClass(host.class)];
        EVI("Anchor", @"button placed %@", self.hostDesc);
    }
    self.button.frame = rect;
    self.button.hidden = A.isHidden || A.alpha < 0.05;
    self.button.alpha = A.alpha;
    [host bringSubviewToFront:self.button];
}

- (void)showFloating {
    UIWindowScene *scene = EVScene();
    if (!scene) return;
    EVRecWindow *w = [[EVRecWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelAlert + 100; w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc; w.hidden = NO;
    self.floatWindow = w; self.floating = YES;
    [self.button removeFromSuperview];
    [vc.view addSubview:self.button];
    self.button.frame = CGRectMake(w.bounds.size.width - 90, MAX(w.safeAreaInsets.top, 40) + 60, 74.6667, 74.6667);
}

- (void)hideFloating {
    self.floating = NO;
    [self.button removeFromSuperview];
    self.floatWindow.hidden = YES; self.floatWindow = nil;
    EVI("Anchor", @"anchor found - floating fallback hidden");
}

- (void)pan:(UIPanGestureRecognizer *)g {
    if (!self.floating) return;
    UIView *v = g.view, *sv = v.superview;
    CGPoint t = [g translationInView:sv];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    c.x = MIN(MAX(c.x, 37), sv.bounds.size.width - 37);
    c.y = MIN(MAX(c.y, sv.safeAreaInsets.top + 37), sv.bounds.size.height - sv.safeAreaInsets.bottom - 37);
    v.center = c;
    [g setTranslation:CGPointZero inView:sv];
}

- (void)nextAnchor {
    NSArray *c = EVLottieCandidates();
    if (!c.count) { EVW("Anchor", @"next anchor: no candidates"); return; }
    NSInteger next = (EVSettingInt(@"anchorIndex", 0) + 1) % (NSInteger)c.count;
    EVSetSettingInt(@"anchorIndex", next);
    [self.button removeFromSuperview]; self.anchor = nil;
    EVI("Anchor", @"anchor index -> %ld of %lu", (long)next, (unsigned long)c.count);
    [self scanTick];
}

- (void)dumpLottieToLog {
    NSArray<UIView *> *all = EVAllLottie();
    EVI("Anchor", @"%lu Lottie view(s) in the hierarchy:", (unsigned long)all.count);
    NSUInteger n = 0;
    for (UIView *v in all) {
        if (++n > 40) break;
        EVI("Anchor", @"  #%lu visible=%d %@", (unsigned long)n, v.window != nil && !v.isHidden, EVChain(v));
    }
}

#pragma mark state / actions

- (void)reconcile {
    BOOL rec = EeveeAudioRecorderIsRecording();
    if (self.state == EVRecIdle && rec) { self.state = EVRecRecording; self.token++; [self.button showBlink]; }
    else if (self.state == EVRecRecording && !rec) {
        self.token++; self.state = EVRecIdle; [self.button showIdle];
        NSString *err = EeveeAudioRecorderLastError();
        if (err.length) [self showToastTitle:@"Recording stopped" sub:err image:nil duration:10];
    }
}

- (void)tap {
    if (self.state == EVRecStarting || self.state == EVRecStopping) return;
    EVI("UI", @"button tapped in state %ld", (long)self.state);
    if (self.state == EVRecIdle) {
        self.state = EVRecStarting;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL ok = EeveeAudioRecorderStart();
            dispatch_async(dispatch_get_main_queue(), ^{ [self startFinished:ok]; });
        });
    } else {
        self.state = EVRecStopping; self.token++;
        [self.button showIdle];
        [self showToastTitle:@"Stopped" sub:@"Splitting into tracks..." image:nil duration:4];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            EeveeAudioRecorderStop();
            dispatch_async(dispatch_get_main_queue(), ^{ self.state = EVRecIdle; [self.button showIdle]; });
        });
    }
}

- (void)startFinished:(BOOL)ok {
    if (!ok) {
        NSString *err = EeveeAudioRecorderLastError() ?: @"Unknown error. See the log (long-press the button).";
        [self.button showWarning];
        [self showToastTitle:@"Could not start recording" sub:err image:nil duration:12];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.state = EVRecIdle; [self.button showIdle];
        });
        return;
    }
    self.state = EVRecRecording;
    NSUInteger t = ++self.token;
    [self.button showIdle];                                   // green
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.token != t || self.state != EVRecRecording) return;
        [self.button showSolidRed];                           // then red
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.token != t || self.state != EVRecRecording) return;
            [self.button showBlink];                          // then blinking gray/red
        });
    });
}

- (void)longPressButton:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) EeveeRecorderPresentDebugPanel();
}

- (void)finished:(NSNotification *)n {
    NSArray<NSURL *> *files = n.userInfo[@"files"];
    NSArray<NSDictionary *> *tracks = n.userInfo[@"tracks"];
    NSString *err = n.userInfo[@"error"];
    id folder = n.userInfo[@"folder"];
    if ([folder isKindOfClass:NSURL.class]) self.lastFolder = folder;
    NSMutableArray *share = [NSMutableArray array];
    UIImage *thumb = nil;
    for (NSURL *u in files) {
        NSString *e = u.pathExtension.lowercaseString;
        if ([e isEqualToString:@"wav"] || [e isEqualToString:@"m4a"] || [e isEqualToString:@"aiff"] || [e isEqualToString:@"flac"] || [e isEqualToString:@"mp3"] || [e isEqualToString:@"jpg"]) [share addObject:u];
        if (!thumb && [e isEqualToString:@"jpg"]) thumb = [UIImage imageWithContentsOfFile:u.path];
    }
    self.shareFiles = share;
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *t in tracks)
        [lines addObject:[NSString stringWithFormat:@"%@%@ [%@]", [t[@"artist"] length] ? [t[@"artist"] stringByAppendingString:@" - "] : @"", t[@"title"], EVFormatTime([t[@"durationMs"] doubleValue] / 1000.0)]];
    self.toastSummary = [lines componentsJoinedByString:@"\n"];
    NSString *folderName = [folder isKindOfClass:NSURL.class] ? [(NSURL *)folder lastPathComponent] : @"";
    if (!tracks.count) {
        [self showToastTitle:@"Recording failed" sub:err.length ? err : @"Nothing was saved." image:nil duration:12];
    } else {
        NSString *sub = [NSString stringWithFormat:@"Documents/Recordings/%@%@\nTap to share - hold to copy", folderName, err.length ? [@"\nWarning: " stringByAppendingString:err] : @""];
        [self showToastTitle:[NSString stringWithFormat:@"Saved %lu track%@", (unsigned long)tracks.count, tracks.count == 1 ? @"" : @"s"]
                         sub:sub image:thumb duration:14];
    }
}

#pragma mark toast / share

- (void)showToastTitle:(NSString *)title sub:(NSString *)sub image:(UIImage *)img duration:(NSTimeInterval)d {
    EVI("UI", @"toast: %@ | %@", title, sub);
    UIWindowScene *scene = EVScene();
    if (!scene) return;
    if (!self.toastWindow) {
        EVRecWindow *w = [[EVRecWindow alloc] initWithWindowScene:scene];
        w.windowLevel = UIWindowLevelAlert + 50; w.backgroundColor = UIColor.clearColor;
        UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.clearColor;
        w.rootViewController = vc; w.hidden = NO;
        self.toastWindow = w;
    }
    UIView *root = self.toastWindow.rootViewController.view;
    [self.toast removeFromSuperview];
    EVToastView *t = [EVToastView new];
    t.titleLabel.text = title; t.subLabel.text = sub;
    t.thumb.image = img; t.thumb.hidden = (img == nil);
    t.translatesAutoresizingMaskIntoConstraints = NO;
    [t addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toastTapped)]];
    [t addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(toastHeld:)]];
    [root addSubview:t];
    [NSLayoutConstraint activateConstraints:@[
        [t.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [t.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [t.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor constant:-90]]];
    self.toast = t;
    t.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ t.alpha = 1; }];
    NSUInteger tok = ++self.toastToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.toastToken == tok) [self hideToast];
    });
}

- (void)hideToast {
    EVToastView *t = self.toast;
    [UIView animateWithDuration:0.3 animations:^{ t.alpha = 0; } completion:^(BOOL f) {
        [t removeFromSuperview];
        if (self.toast == t) { self.toast = nil; self.toastWindow.hidden = YES; self.toastWindow = nil; }
    }];
}

- (void)toastTapped {
    if (self.shareFiles.count) [self shareURLs:self.shareFiles]; else [self hideToast];
}

- (void)toastHeld:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSString *s = self.toastSummary.length ? self.toastSummary : (self.toast.titleLabel.text ?: @"");
    UIPasteboard.generalPasteboard.string = s;
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    self.toast.titleLabel.text = @"Copied to clipboard";
    EVI("UI", @"summary copied to clipboard");
}

- (void)shareURLs:(NSArray<NSURL *> *)urls {
    UIViewController *top = EVTopVC();
    if (!top || !urls.count) { EVW("UI", @"cannot present share sheet (top=%@ items=%lu)", top, (unsigned long)urls.count); return; }
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    vc.popoverPresentationController.sourceView = top.view;
    vc.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2, top.view.bounds.size.height - 40, 1, 1);
    [top presentViewController:vc animated:YES completion:nil];
}

#pragma mark helpers for the debug panel

- (NSURL *)latestFolder {
    if (self.lastFolder) return self.lastFolder;
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:EVRecordingsRoot() includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSArray *sorted = [dirs sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent compare:b.lastPathComponent]; }];
    return sorted.lastObject;
}

- (NSArray<NSURL *> *)latestShareables {
    if (self.shareFiles.count) return self.shareFiles;
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[self latestFolder] ?: EVRecordingsRoot() includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *e = u.pathExtension.lowercaseString;
        if ([e isEqualToString:@"wav"] || [e isEqualToString:@"m4a"] || [e isEqualToString:@"aiff"] || [e isEqualToString:@"flac"] || [e isEqualToString:@"mp3"] || [e isEqualToString:@"jpg"]) [out addObject:u];
    }
    return out;
}

- (NSArray<NSString *> *)uiDebugLines {
    NSMutableArray *l = [NSMutableArray arrayWithObject:@"== UI =="];
    [l addObject:[NSString stringWithFormat:@"state=%ld floating=%d lottie candidates (74.67): %lu, index %ld",
                  (long)self.state, self.floating, (unsigned long)self.candidateCount, (long)EVSettingInt(@"anchorIndex", 0)]];
    [l addObject:[NSString stringWithFormat:@"anchor: %@", self.anchor ? EVChain(self.anchor) : @"none"]];
    [l addObject:[NSString stringWithFormat:@"button host: %@", self.hostDesc ?: @"-"]];
    [l addObject:[NSString stringWithFormat:@"settings: verbose=%d floatingFallback=%d keepSession=%d forceInline=%d probeDriver=%d",
                  EVSettingBool(@"verbose", NO), EVSettingBool(@"floatingFallback", YES), EVSettingBool(@"keepSession", NO),
                  EVSettingBool(@"forceInline", NO), EVSettingBool(@"probeDriver", NO)]];
    return l;
}

@end

#pragma mark - Debug panel implementation

@implementation EVDebugVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recorder debug";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.text = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.text.editable = NO; self.text.alwaysBounceVertical = YES;
    self.text.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    [self.view addSubview:self.text];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Close" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Tools" style:UIBarButtonItemStylePlain target:self action:@selector(tools)],
        [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)]];
    [self refresh];
    __weak typeof(self) ws = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [ws refresh]; }];
}

- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self.timer invalidate]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSString *)fullText {
    return [NSString stringWithFormat:@"%@\n\n== Log (last 120 lines) ==\n%@", EeveeRecorderDebugReport(),
            [EVLogTail(120) componentsJoinedByString:@"\n"]];
}

- (void)refresh {
    UITextView *tv = self.text;
    BOOL atBottom = tv.contentOffset.y >= tv.contentSize.height - tv.bounds.size.height - 40;
    BOOL first = tv.text.length == 0;
    CGPoint off = tv.contentOffset;
    tv.text = [self fullText];
    [tv layoutIfNeeded];
    if (first || atBottom) [tv scrollRangeToVisible:NSMakeRange(tv.text.length, 0)];
    else tv.contentOffset = off;
}

- (void)copyAll {
    UIPasteboard.generalPasteboard.string = [self fullText];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (UIAlertController *)sheetTitle:(NSString *)t {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 80, 1, 1);
    return a;
}

- (void)tools {
    EVRecUI *ui = [EVRecUI shared];
    UIAlertController *a = [self sheetTitle:@"Recorder tools"];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Options..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ws options]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Share log file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        EVLogFlush(); [ui shareURLs:@[[NSURL fileURLWithPath:EVLogPath()]]]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Share last recording" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [ui shareURLs:[ui latestShareables]]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Export last session as AAC (.m4a)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ws exportLast:@"aac"]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Export last session as Lossless (ALAC .m4a)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ws exportLast:@"alac"]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Export last session as AIFF (.aiff)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ws exportLast:@"aiff"]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Dump Lottie views to log" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ui dumpLottieToLog]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Next anchor candidate" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ui nextAnchor]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Clear log" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { EVLogClear(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)exportLast:(NSString *)fmt {
    EVRecUI *ui = [EVRecUI shared];
    NSURL *folder = [ui latestFolder];
    if (!folder) { [ui showToastTitle:@"Nothing to export" sub:@"No recording folder found." image:nil duration:5]; return; }
    [ui showToastTitle:@"Exporting..." sub:folder.lastPathComponent image:nil duration:6];
    EVExportFolder(folder, fmt, ^(NSArray<NSURL *> *files, NSURL *f, NSArray<NSDictionary *> *tracks, NSString *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (files.count) { ui.shareFiles = files; }
            [ui showToastTitle:files.count ? [NSString stringWithFormat:@"Exported %lu file%@", (unsigned long)files.count, files.count == 1 ? @"" : @"s"] : @"Export failed"
                           sub:err.length ? err : @"Tap to share" image:nil duration:12];
        });
    });
}

- (void)options {
    UIAlertController *a = [self sheetTitle:@"Options (tap to toggle)"];
    __weak typeof(self) ws = self;
    NSArray *toggles = @[
        @[@"verbose", @"Verbose logging", @NO],
        @[@"floatingFallback", @"Floating button if anchor not found", @YES],
        @[@"keepSession", @"Keep full session WAV", @NO],
        @[@"waitForTrackStart", @"Wait for next track beginning", @NO],
        @[@"forceInline", @"Force inline hook (needs JIT)", @NO],
        @[@"probeDriver", @"Probe audio driver (next launch)", @NO]];
    for (NSArray *t in toggles) {
        BOOL on = EVSettingBool(t[0], [t[2] boolValue]);
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ %@", on ? @"[x]" : @"[ ]", t[1]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            EVSetSettingBool(t[0], !on); EVI("UI", @"option %@ -> %d", t[0], !on); [ws options]; }]];
    }
    NSString *fm = EVSettingString(@"exportFormats", @"");
    for (NSArray *f in @[@[@"aac", @"Also export AAC .m4a"], @[@"alac", @"Also export Lossless .m4a"], @[@"aiff", @"Also export AIFF .aiff"]]) {
        BOOL on = [[fm componentsSeparatedByString:@","] containsObject:f[0]];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ %@", on ? @"[x]" : @"[ ]", f[1]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSMutableArray *parts = [NSMutableArray array];
            for (NSString *p in [fm componentsSeparatedByString:@","]) if (p.length && ![p isEqualToString:f[0]]) [parts addObject:p];
            if (!on) [parts addObject:f[0]];
            EVSetSettingString(@"exportFormats", [parts componentsJoinedByString:@","]); [ws options]; }]];
    }
    NSInteger lat = EVSettingInt(@"metaLatencyMs", 0);
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Track-start latency: %ld ms  (+25)", (long)lat] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        EVSetSettingInt(@"metaLatencyMs", lat + 25); [ws options]; }]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Track-start latency: %ld ms  (-25)", (long)lat] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        EVSetSettingInt(@"metaLatencyMs", lat - 25); [ws options]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - Public API

NSString *EeveeRecorderDebugReport(void) {
    NSMutableArray *l = [NSMutableArray array];
    [l addObjectsFromArray:EVCoreDebugLines()];
    [l addObjectsFromArray:EVMetaDebugLines()];
    [l addObjectsFromArray:[[EVRecUI shared] uiDebugLines]];
    [l addObject:[NSString stringWithFormat:@"log file: %@", EVLogPath()]];
    [l addObject:[NSString stringWithFormat:@"recordings: %@", EVRecordingsRoot().path]];
    return [l componentsJoinedByString:@"\n"];
}

void EeveeRecorderPresentDebugPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = EVTopVC();
        if (!top) { EVW("UI", @"debug panel: no view controller to present from"); return; }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[EVDebugVC new]];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

__attribute__((constructor)) static void evUIInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[EVRecUI shared] start];
    });
}
