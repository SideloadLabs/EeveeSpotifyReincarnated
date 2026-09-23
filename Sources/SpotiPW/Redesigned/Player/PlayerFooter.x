// Player redesign: the footer as the Music app's row of three glyphs, lyrics, devices and queue, spread
// evenly across the player, and no share button.
//
// Spotify's footer is Connect with the device's name at the leading edge, share, and the queue at the
// trailing edge. Connect and the queue stay Spotify's controls (the device sheet, the remote device
// tint, the Jam avatars) and are only moved, by a translation of the arranged view that holds each: a
// transform survives the stack view laying them out again, and moving the holder keeps its touches
// inside its own bounds. The device name goes transparent, since the glyph alone sits in the middle.
// Spotify has no lyrics control down here, so that one is the Kit's glyph button, and it turns the
// lyrics in the player on and off (PlayerLyrics.x): filled while they are up, dimmed and dead for a
// track that has none.
//
// The row sits lower than Spotify puts it, just over the home indicator the way the Music app's does
// (issue #54): the footer unit's view is translated down, the controls follow it part of the way, and a
// band of the redesign's hands the touches below the bottom stack's bounds back to the row.
//
// Tree (trees/clean/player/01.txt:295-320): FooterElementsUnit's view 402x44 > UIStackView 382x44 >
// ElementView > ConnectButtonOutputSwitcherViewHolder id=Components.ConnectButtonOutputSwitcher 153x36
// (a 19x19 UIImageView glyph and a MarqueeLabel with the device name), a spacer, a hidden media trimmer,
// ElementView > EncoreButton id=ShareButtonNowPlayingView 44x44, ElementView > Queue control
// id=QueueButtonNowPlaying 47x32.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

static const CGFloat kLyricsGlyphSize = 20;
// Filled and at full strength while the lyrics are up, the way the Music app marks the control that is on.
static NSString *const kLyricsSymbol = @"quote.bubble", *const kLyricsSymbolOpen = @"quote.bubble.fill";
// Where the three glyphs sit, as parts of the footer's width.
static const CGFloat kLeading = 0.2, kMiddle = 0.5, kTrailing = 0.8;
static const CGFloat kGlyphMaxWidth = 30;

// Issue #54: Spotify ends its bottom stack 61pt above the screen's bottom (01.txt:127, 576.67 + 236 of
// 874), so the row's middle sat 83pt up, well clear of the home indicator, and the controls crowded it.
// The Music app keeps that row just over the home indicator: its middle this far above the safe area's
// bottom, and never less than kRowMinBottom above the screen's on a phone without a home indicator.
static const CGFloat kRowAboveSafeArea = 20, kRowMinBottom = 34;
// The controls follow a share of the row's move when nothing stands between them, so the gaps above
// and below them even out instead of all the room opening under them.
static const CGFloat kControlsShare = 0.3;

static char kConnectKey, kShareKey, kTrimmerKey, kQueueKey, kLyricsGlyphKey, kReachKey;
static __weak SGRGlyphButton *sg_lyricsGlyph;

// The view the footer's stack view arranges around `view`.
static UIView *arrangedAround(UIView *view, UIView *host) {
    for (UIView *v = view; v && v != host; v = v.superview) {
        if ([v.superview isKindOfClass:UIStackView.class]) return v;
    }
    return nil;
}

// Where `point` of `view` is in the host with the arranged view's own transform left out.
static CGFloat untransformedX(UIView *arranged, UIView *view, CGPoint point, UIView *host) {
    CGPoint local = [view convertPoint:point toView:arranged];
    CGPoint inRow = CGPointMake(arranged.center.x + local.x - CGRectGetMidX(arranged.bounds), arranged.center.y);
    return [arranged.superview convertPoint:inRow toView:host].x;
}

static CGFloat moveTo(UIView *arranged, UIView *view, CGPoint point, UIView *host, CGFloat x) {
    if (!arranged) return -1;
    CGFloat from = untransformedX(arranged, view, point, host);
    CGAffineTransform transform = CGAffineTransformMakeTranslation(round(x - from), 0);
    if (!CGAffineTransformEqualToTransform(arranged.transform, transform)) arranged.transform = transform;
    return from;
}

#pragma mark - lyrics

void SGRPlayerLyricsChanged(void) {
    SGRGlyphButton *glyph = sg_lyricsGlyph;
    if (!glyph) return;
    BOOL enabled = SGRPlayerLyricsAvailable() || SGRPlayerLyricsOpen(), open = SGRPlayerLyricsOpen();
    BOOL wasOpen = [glyph.glyph.symbol isEqualToString:kLyricsSymbolOpen];
    if (glyph.enabled == enabled && wasOpen == open) return;
    // Lyrics turn up once the player has fetched them, well after the footer laid out: a fade, not a pop.
    // While the player opens or closes the glyph and the lyrics come and go together, so nothing animates.
    BOOL animated = glyph.window && !SGRPlayerIsTransitioning();
    [glyph.glyph setSymbol:open ? kLyricsSymbolOpen : kLyricsSymbol animated:animated];
    void (^mark)(void) = ^{
        glyph.enabled = enabled;
        glyph.glyph.tintColor = open ? SGRPrimary() : SGRSecondary();
    };
    if (animated) SGRAnimate(SGRMotionFade, mark, nil);
    else mark();
}

static SGRGlyphButton *lyricsGlyphIn(UIView *host) {
    SGRGlyphButton *glyph = objc_getAssociatedObject(host, &kLyricsGlyphKey);
    if (!glyph) {
        glyph = [SGRGlyphButton buttonWithSymbol:kLyricsSymbol pointSize:kLyricsGlyphSize title:@"Lyrics"];
        glyph.glyph.tintColor = SGRSecondary();
        glyph.onTap = ^{ SGRPlayerToggleLyrics(); };
        objc_setAssociatedObject(host, &kLyricsGlyphKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glyph.superview != host) [host addSubview:glyph];
    sg_lyricsGlyph = glyph;
    return glyph;
}

#pragma mark - the row

static UIView *connectGlyphIn(UIView *holder) {
    __block UIView *glyph = nil;
    SGForEachView(holder, ^(UIView *view) {
        if (!glyph && [view isKindOfClass:UIImageView.class] && view.bounds.size.width > 0 && view.bounds.size.width <= kGlyphMaxWidth) glyph = view;
    });
    return glyph;
}

#pragma mark - lower down

// Moved down, the row is drawn partly below the bottom stack it is arranged in, and UIKit does not look
// into a view for a touch outside its bounds. This band over the part that hangs out hands such a touch
// to the row itself, and lets every other one through.
@interface SGRFooterReach : UIView
@property (nonatomic, weak) UIView *row;
@end

@implementation SGRFooterReach
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *row = self.row;
    if (!row.window || row.alpha < 0.01 || row.hidden) return nil;
    UIView *hit = [row hitTest:[row convertPoint:point fromView:self] withEvent:event];
    return hit == row ? nil : hit;
}
@end

static UIViewController *unitOf(UIView *view) {
    UIResponder *next = view.nextResponder;
    return [next isKindOfClass:UIViewController.class] && ((UIViewController *)next).viewIfLoaded == view ? (UIViewController *)next : nil;
}

// The arranged view drawn right above `row` in its stack, by where the stack put them.
static UIView *rowAbove(UIView *row) {
    UIView *best = nil;
    CGFloat top = row.center.y - row.bounds.size.height / 2, bestBottom = -CGFLOAT_MAX;
    for (UIView *sibling in row.superview.subviews) {
        if (sibling == row || sibling.hidden || sibling.alpha < 0.01 || sibling.bounds.size.height < 1) continue;
        CGFloat bottom = sibling.center.y + sibling.bounds.size.height / 2;
        if (bottom <= top + 1 && bottom > bestBottom) {
            best = sibling;
            bestBottom = bottom;
        }
    }
    return best;
}

static void lowerRow(UIView *row) {
    UIView *stack = row.superview, *player = stack.superview;
    UIWindow *window = row.window;
    if (![stack isKindOfClass:UIStackView.class] || !player || !window) return;
    // Where the stack put the row, the row's own transform left out, and where it belongs.
    CGFloat middle = [stack convertPoint:row.center toView:player].y;
    CGFloat height = player.bounds.size.height;
    CGFloat target = height - MAX(window.safeAreaInsets.bottom + kRowAboveSafeArea, kRowMinBottom);
    CGFloat move = MAX(0, round(target - middle));
    CGAffineTransform down = CGAffineTransformMakeTranslation(0, move);
    if (!CGAffineTransformEqualToTransform(row.transform, down)) row.transform = down;

    // Only the controls, and only straight above: a volume row between them keeps its place and theirs.
    UIView *above = rowAbove(row);
    BOOL controls = [NSStringFromClass(unitOf(above).class) containsString:@"PlaybackControlsElementsUnit"];
    CGAffineTransform follow = CGAffineTransformMakeTranslation(0, controls ? round(move * kControlsShare) : 0);
    if (above && controls && !CGAffineTransformEqualToTransform(above.transform, follow)) above.transform = follow;

    SGRFooterReach *reach = objc_getAssociatedObject(row, &kReachKey);
    if (!reach) {
        reach = [SGRFooterReach new];
        reach.row = row;
        objc_setAssociatedObject(row, &kReachKey, reach, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (reach.superview != player) [player addSubview:reach];
    CGRect stackFrame = [stack convertRect:stack.bounds toView:player];
    CGRect drawn = [row convertRect:row.bounds toView:player];
    CGFloat from = CGRectGetMaxY(stackFrame);
    CGRect band = CGRectMake(CGRectGetMinX(drawn), from, drawn.size.width, MAX(0, CGRectGetMaxY(drawn) - from));
    if (!CGRectEqualToRect(reach.frame, band)) reach.frame = band;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign player: footer row from %.0f to %.0f of %.0f (safe area %.0f), controls %@ %.0f", middle, middle + move, height,
              window.safeAreaInsets.bottom, controls ? @"follow" : @"stay", controls ? round(move * kControlsShare) : 0);
    });
}

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host) return;
    // The unit lays out before its row does, and the moves are measured from where the row put things.
    [SGRowIn(host) layoutIfNeeded];
    CGFloat width = host.bounds.size.width, middleY = CGRectGetMidY(host.bounds);
    BOOL rtl = host.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;

    UIView *share = SGRFindByIdentifier(host, @"ShareButtonNowPlayingView", &kShareKey);
    // The arranged view goes too: a view that takes touches swallows them even with nothing on it.
    SGRPlayerVanish(share);
    SGRPlayerVanish(arrangedAround(share, host));
    // Spotify's clip button, hidden in every clean tree, would turn up where the queue moves to.
    UIView *trimmer = SGRFindByIdentifier(host, @"nowplaying-npv-media-trimmer-navigation-button", &kTrimmerKey);
    SGRPlayerVanish(trimmer);
    SGRPlayerVanish(arrangedAround(trimmer, host));

    SGRGlyphButton *lyrics = lyricsGlyphIn(host);
    lyrics.bounds = CGRectMake(0, 0, 44, 44);
    lyrics.center = CGPointMake(round(width * (rtl ? kTrailing : kLeading)), middleY);
    SGRPlayerLyricsChanged();

    UIView *connect = SGRFindByIdentifier(host, @"Components.ConnectButtonOutputSwitcher", &kConnectKey);
    UIView *glyph = connectGlyphIn(connect);
    for (UIView *view = glyph.superview; view && view != connect; view = view.superview) {
        for (UIView *sibling in view.subviews) {
            if ([NSStringFromClass(sibling.class) containsString:@"MarqueeLabel"]) SGRPlayerVanish(sibling);
        }
    }
    UIView *pinned = glyph ?: connect;
    CGFloat connectFrom = moveTo(arrangedAround(connect, host), pinned, CGPointMake(CGRectGetMidX(pinned.bounds), CGRectGetMidY(pinned.bounds)), host, round(width * kMiddle));

    UIView *queue = SGRFindByIdentifier(host, @"QueueButtonNowPlaying", &kQueueKey);
    CGFloat queueFrom = moveTo(arrangedAround(queue, host), queue, CGPointMake(CGRectGetMidX(queue.bounds), CGRectGetMidY(queue.bounds)), host, round(width * (rtl ? kLeading : kTrailing)));

    lowerRow(host);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign player: footer lyrics at %.0f, connect %.0f (%@) to %.0f, queue %.0f to %.0f, share %@", lyrics.center.x,
              connectFrom, glyph ? @"glyph" : @"button", round(width * kMiddle), queueFrom, round(width * (rtl ? kLeading : kTrailing)), share ? @"gone" : @"not found");
    });
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl18FooterElementsUnit"]);
}
