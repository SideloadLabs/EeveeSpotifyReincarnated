// Vibrations > Controls: a tap for what a finger does to playback, in the full screen player and the
// now playing bar (SGFeedback.m holds which tap each gets).
//
// Buttons: every control's action passes -[UIControl sendAction:to:forEvent:] (target and action) or
// -[UIControl sendAction:] (a UIAction), so the controls are told apart there by accessibility
// identifier, after they have acted. Tree (trees/clean/player/01.txt): id=SPTNowPlayingPlayButton is the
// PlayButtonView (:266, and the sticky header's :492) around the UIButton that acts (CondensedButton, :272),
// in the bar too (trees/clean/home/01.txt:1281); id=SPTNowPlayingPreviousTrackButton and ...NextTrackButton
// are Encore buttons (:257, :282); id=Components.UI.ShuffleButton and Nowplaying-RepeatButton are
// EncoreButtons, UIButtons (:247, :290); id=Components.UI.AddToButton is a UIButton (:205, :425 on a card,
// home/01.txt:1296 in the bar).
// Play or pause is read off the player's state before the button acts, since the tap turns it.
//
// Scrubbing: the position slider is NowPlaying_ECMKit.ProgressBar.Slider, a UISlider
// (id=SPTNowPlayingSliderV2, :216) that overrides UIControl's begin, continue and endTracking
// (objc-methods.txt:83559); a tap when it is taken, a tick at every tenth of the song it passes, a firmer one at
// either end, a soft one when it lets go.
//
// Cover swipes: the player's covers are a list of pages scrolled sideways (AccessibleCollectionView,
// :28) and so are the bar's titles (NowPlaying_BarImpl.InformationCollectionView, home/01.txt:1104);
// a tick when a drag or its fling carries the list past halfway to the next page, where letting go skips.
//
// Gestures (Shared/Gestures) tell of each action a double tap performs; the lyrics page's tap to seek
// plays its tap in Redesigned/Lyrics/SGRKaraokeView.m.
#import "Core/SGCore.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Player/PlayerState.h"
#import "Haptics.h"

// How close to either end the scrubber is at it.
static const float kScrubEdge = 0.005f;
// A tenth is only passed once the scrubber is this far past it, so a finger resting on one ticks once.
static const float kScrubHysteresis = 0.004f;
// The share of a page past halfway a swipe has to reach before it ticks.
static const CGFloat kPageHysteresis = 0.02;
// The same control acting twice this quickly (a target and a UIAction, or two targets) is one tap.
static const CFTimeInterval kSameTap = 0.1;

#pragma mark - buttons

typedef NS_ENUM(NSInteger, ControlKind) {
    ControlNone,
    ControlPlay,
    ControlSkip,
    ControlToggle,
    ControlAdd,
};

static ControlKind kindOf(UIControl *control) {
    static NSDictionary<NSString *, NSNumber *> *kinds;
    if (!kinds) {
        kinds = @{
            @"SPTNowPlayingPlayButton": @(ControlPlay),
            @"SPTNowPlayingPreviousTrackButton": @(ControlSkip),
            @"SPTNowPlayingNextTrackButton": @(ControlSkip),
            @"Components.UI.ShuffleButton": @(ControlToggle),
            @"Nowplaying-RepeatButton": @(ControlToggle),
            @"Components.UI.AddToButton": @(ControlAdd),
        };
    }
    NSString *identifier = control.accessibilityIdentifier;
    NSNumber *kind = identifier.length ? kinds[identifier] : nil;
    // The play button's identifier is on the PlayButtonView around the UIButton that acts.
    if (!kind && !identifier.length) kind = kinds[control.superview.accessibilityIdentifier ?: @""];
    return (ControlKind)kind.integerValue;
}

// A touch that has not ended is a control acting on touch down or while dragged, not a tap.
static BOOL isTap(UIEvent *event) {
    NSSet<UITouch *> *touches = event.allTouches;
    if (!touches.count) return YES;
    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseEnded) return YES;
    }
    return NO;
}

static void controlActed(UIControl *control, ControlKind kind, BOOL wasPaused) {
    static __weak UIControl *lastControl;
    static CFTimeInterval lastTime;
    CFTimeInterval now = CACurrentMediaTime();
    if (control == lastControl && now - lastTime < kSameTap) return;
    lastControl = control;
    lastTime = now;
    switch (kind) {
        case ControlNone: return;
        case ControlPlay: SGPlayFeedback(wasPaused ? SGFeedbackPlay : SGFeedbackPause); break;
        case ControlSkip: SGPlayFeedback(SGFeedbackSkip); break;
        case ControlToggle: SGPlayFeedback(SGFeedbackToggle); break;
        case ControlAdd: SGPlayFeedback(SGFeedbackAdd); break;
    }
    static NSMutableSet<NSNumber *> *logged;
    if (!logged) logged = [NSMutableSet set];
    if ([logged containsObject:@(kind)]) return;
    [logged addObject:@(kind)];
    SGLog(@"redesign haptics: %@ (%@) acted, kind %ld", control.accessibilityIdentifier ?: control.superview.accessibilityIdentifier, NSStringFromClass(control.class), (long)kind);
}

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    ControlKind kind = kindOf(self);
    if (kind == ControlNone || !isTap(event)) {
        %orig;
        return;
    }
    BOOL wasPaused = SGPlayerState().isPaused;
    %orig;
    controlActed(self, kind, wasPaused);
}

- (void)sendAction:(UIAction *)action {
    ControlKind kind = kindOf(self);
    if (kind == ControlNone) {
        %orig;
        return;
    }
    BOOL wasPaused = SGPlayerState().isPaused;
    %orig;
    controlActed(self, kind, wasPaused);
}
%end

#pragma mark - scrubbing

static int sg_scrubTenth;
static BOOL sg_scrubAtEdge;
static NSUInteger sg_scrubTicks;

static float positionOf(UISlider *slider) {
    float span = slider.maximumValue - slider.minimumValue;
    return span > 0 ? (slider.value - slider.minimumValue) / span : 0;
}

static BOOL atEdge(float position) {
    return position <= kScrubEdge || position >= 1 - kScrubEdge;
}

static void scrubBegan(UISlider *slider) {
    float position = positionOf(slider);
    sg_scrubTenth = (int)floor(MIN(position, 0.9999f) * 10);
    sg_scrubAtEdge = atEdge(position);
    sg_scrubTicks = 0;
    SGPlayFeedback(SGFeedbackGrab);
    SGPrepareFeedback(SGFeedbackDetent);
}

static void scrubMoved(UISlider *slider) {
    float position = positionOf(slider);
    BOOL edge = atEdge(position);
    if (edge) {
        if (!sg_scrubAtEdge) SGPlayFeedback(SGFeedbackEdge);
        sg_scrubAtEdge = YES;
        sg_scrubTenth = (int)floor(MIN(position, 0.9999f) * 10);
        return;
    }
    sg_scrubAtEdge = NO;
    int tenth = (int)floor(position * 10);
    if (tenth == sg_scrubTenth) return;
    float boundary = (tenth > sg_scrubTenth ? tenth : sg_scrubTenth) / 10.0f;
    if (fabsf(position - boundary) < kScrubHysteresis) return;
    sg_scrubTenth = tenth;
    sg_scrubTicks++;
    SGPlayFeedback(SGFeedbackDetent);
}

%hook _TtCO17NowPlaying_ECMKit11ProgressBar6Slider
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    if (tracking) scrubBegan((UISlider *)self);
    return tracking;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    scrubMoved((UISlider *)self);
    return tracking;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    SGPlayFeedback(SGFeedbackRelease);
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"redesign haptics: scrubbed to %.2f of the song, %lu ticks", positionOf((UISlider *)self), (unsigned long)sg_scrubTicks);
}
%end

#pragma mark - cover swipes

static void pageDetent(UIScrollView *list, NSInteger *lastPage) {
    CGFloat width = list.bounds.size.width;
    if (width < 1) return;
    CGFloat position = list.contentOffset.x / width;
    NSInteger page = lround(position);
    if (!list.isTracking && !list.isDecelerating) {
        *lastPage = page;
        return;
    }
    if (page == *lastPage || fabs(position - *lastPage) < 0.5 + kPageHysteresis) return;
    *lastPage = page;
    SGPlayFeedback(SGFeedbackDetent);
}

%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)setContentOffset:(CGPoint)offset {
    %orig;
    static NSInteger lastPage;
    pageDetent((UIScrollView *)self, &lastPage);
}
%end

%hook _TtC18NowPlaying_BarImpl25InformationCollectionView
- (void)setContentOffset:(CGPoint)offset {
    %orig;
    static NSInteger lastPage;
    pageDetent((UIScrollView *)self, &lastPage);
}
%end

#pragma mark - gestures

static void gesturePerformed(SGGestureAction action) {
    switch (action) {
        case SGGestureNothing: break;
        case SGGesturePlayPause: SGPlayFeedback(SGPlayerState().isPaused ? SGFeedbackPlay : SGFeedbackPause); break;
        case SGGestureSeekBack:
        case SGGestureSeekForward:
        case SGGestureNextTrack:
        case SGGesturePreviousTrack: SGPlayFeedback(SGFeedbackSkip); break;
        case SGGestureShuffle:
        case SGGestureRepeat: SGPlayFeedback(SGFeedbackToggle); break;
    }
}

%ctor {
    SGMigrateKey(SGKeyControlHapticsWas, SGKeyControlHaptics);
    SGMigrateKey(SGKeyControlStrengthWas, SGKeyControlStrength);
    %init;
    SGGestureSetObserver(^(SGGestureAction action) { gesturePerformed(action); });
    SGRequireClasses(@[
        @"_TtCO17NowPlaying_ECMKit11ProgressBar6Slider",
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC18NowPlaying_BarImpl25InformationCollectionView",
    ]);
}
