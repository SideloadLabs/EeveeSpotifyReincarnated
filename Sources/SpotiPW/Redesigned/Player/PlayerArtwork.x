// Player redesign: the cover sits on the field with continuous corners and a soft shadow, and shrinks
// back while playback is paused, the way the Music app's does; the lyric preview under it is gone.
//
// Tree (trees/clean/player/01.txt:36-43): CoverArtCellImpl > ... > CoverArtTiltView 354x354 > an
// ElementView the same size > ImageViewProxy > Encore.ImageView (clips) > UIImageView, with
// Lyrics_NPVContainerKit.LyricsContainerView under the tilt view. The ElementView is what gets the
// corners and the scale: the tilt view's own transform is left to the tilt Spotify gives it when the
// cover is inspected. The image clips, so the shadow is a plate of the Kit's behind it.
//
// The scale is identity while the player opens or closes: the bar morphs into a 354pt stand-in
// (NowPlaying_ECMKit.MaskView, 01.txt:86) and the cover under it has to match where it lands. Once
// the transition is over a paused cover springs down.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

static const CGFloat kPausedScale = 0.84, kPausedScaleReduceMotion = 0.92;
// The bar's 40pt cover lives in a tilt view of its own; the player's is 354.
static const CGFloat kCoverMinWidth = 200;

static char kPlateKey;
static NSHashTable<UIView *> *sg_tilts;
// The cover of each tilt view once found. A frame Spotify sets on a scaled view becomes its scaled
// size, leaving bounds that no longer match the tilt view's, so the cover is not looked for by size again.
static NSMapTable<UIView *, UIView *> *sg_covers;

static CGFloat currentScale(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!state.isPaused || SGRPlayerIsTransitioning()) return 1;
    return SGRReduceMotion() ? kPausedScaleReduceMotion : kPausedScale;
}

// The child of the tilt view the size of the cover.
static UIView *coverIn(UIView *tilt) {
    UIView *cover = [sg_covers objectForKey:tilt];
    if (cover.superview == tilt) return cover;
    for (UIView *sub in tilt.subviews) {
        if (![sub isKindOfClass:SGRShadowPlate.class] && CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size)) {
            [sg_covers setObject:sub forKey:tilt];
            return sub;
        }
    }
    return nil;
}

static BOOL inCoverCell(UIView *tilt) {
    static Class cell;
    if (!cell) cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if ([v isKindOfClass:cell]) return YES;
    }
    return NO;
}

static void scaleCover(UIView *tilt, CGFloat scale) {
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    SGRShadowPlate *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    cover.transform = transform;
    plate.transform = transform;
}

#pragma mark - where the cover is

// The tilt view of the cover on screen: the queue is a cover per cell and the cells out of view are
// kept hidden (player/02.txt:521), so the one showing is the one in a window with nothing hidden over it.
static UIView *showingTilt(void) {
    for (UIView *tilt in sg_tilts) {
        if (!tilt.window) continue;
        BOOL hidden = NO;
        for (UIView *v = tilt; v && !hidden; v = v.superview) hidden = v.hidden;
        if (!hidden) return tilt;
    }
    return nil;
}

UIView *SGRPlayerCoverList(void) {
    for (UIView *v = showingTilt(); v; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) return v;
    }
    return nil;
}

CGRect SGRPlayerCoverFrameIn(UIView *host) {
    UIView *tilt = showingTilt();
    UIView *cover = coverIn(tilt);
    // The cover's own transform is the paused shrink, which is what the eye sees it at.
    return cover && host ? [host convertRect:cover.bounds fromView:cover] : CGRectNull;
}

CGRect SGRPlayerArtworkAreaIn(UIView *host) {
    UIView *tilt = showingTilt();
    if (!tilt || !host) return CGRectNull;
    // The band is the first view over the cover as wide as the player: the cover sits inset inside it
    // (01.txt:33-36, CoverArtCellImpl > UIView {0, 110, 402, 466.67} > UIView {24, 8, ...} > the tilt view).
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if (v == host) break;
        if (v.bounds.size.width >= host.bounds.size.width - 1) return [host convertRect:v.bounds fromView:v];
    }
    return CGRectNull;
}

// The cover hidden for a stand-in, so the same one comes back if the list moved on meanwhile.
static __weak UIView *sg_hiddenCover, *sg_hiddenPlate;

void SGRPlayerSetCoverHidden(BOOL hidden) {
    sg_hiddenCover.alpha = 1;
    sg_hiddenPlate.alpha = 1;
    sg_hiddenCover = sg_hiddenPlate = nil;
    if (!hidden) return;
    UIView *tilt = showingTilt();
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    UIView *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    cover.alpha = 0;
    plate.alpha = 0;
    sg_hiddenCover = cover;
    sg_hiddenPlate = plate;
}

#pragma mark - the paused shrink

static void scaleEveryCover(BOOL animated) {
    CGFloat scale = currentScale();
    NSArray<UIView *> *tilts = sg_tilts.allObjects;
    void (^apply)(void) = ^{
        for (UIView *tilt in tilts) scaleCover(tilt, scale);
    };
    if (animated) SGRAnimate(SGRMotionLayout, apply, nil);
    else apply();
}

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.bounds.size.width < kCoverMinWidth || !inCoverCell(tilt)) return;
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    [sg_tilts addObject:tilt];
    // The cover fills the tilt view (01.txt:37); bounds and center, unlike a frame, hold under the scale.
    CGRect bounds = tilt.bounds;
    CGPoint middle = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    if (!CGSizeEqualToSize(cover.bounds.size, bounds.size)) cover.bounds = (CGRect){cover.bounds.origin, bounds.size};
    if (!CGPointEqualToPoint(cover.center, middle)) cover.center = middle;

    cover.layer.cornerRadius = SGRRadiusArtwork;
    cover.layer.cornerCurve = kCACornerCurveContinuous;
    cover.clipsToBounds = YES;
    SGRShadowPlate *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    plate.bounds = cover.bounds;
    plate.center = cover.center;
    // The same value an animation in flight is heading to, so a layout pass never cuts one short.
    scaleCover(tilt, currentScale());

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: cover %@ rounded %.0f with a shadow plate, scale %.2f", NSStringFromClass(cover.class), SGRRadiusArtwork, currentScale()); });
}
%end

// Spotify shows and hides the preview as lyrics come and go; it stays hidden, the way
// Native/Player/PlayerDeclutter.x has shipped it (its parent is a plain view, 01.txt:35, not a stack).
%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)setHidden:(BOOL)hidden {
    %orig(YES);
}
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).hidden = YES;
}
%end

@interface SGRPlayerArtworkWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRPlayerArtworkWatcher {
    NSInteger _paused;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _paused = -1;
    return self;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSInteger paused = state.isPaused ? 1 : 0;
    if (paused == _paused) return;
    _paused = paused;
    scaleEveryCover(YES);
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"redesign player: state paused=%d loading=%d, %lu covers scaled", state.isPaused, state.isLoading, (unsigned long)sg_tilts.count);
}

@end

static SGRPlayerArtworkWatcher *sg_artworkWatcher;

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_tilts = [NSHashTable weakObjectsHashTable];
    sg_covers = [NSMapTable weakToWeakObjectsMapTable];
    sg_artworkWatcher = [SGRPlayerArtworkWatcher new];
    SGAddPlayerStateObserver(sg_artworkWatcher);
    SGRObservePlayerTransition(sg_artworkWatcher, ^(id owner) {
        scaleEveryCover(YES);
    }, ^(id owner) {
        scaleEveryCover(YES);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign player: transition over, cover scale %.2f", currentScale()); });
    });
    SGRequireClasses(@[
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        @"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl",
        @"_TtC22Lyrics_NPVContainerKit19LyricsContainerView",
    ]);
}
