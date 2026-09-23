// Double tap zones over the player's artwork: the artwork already answers a sideways swipe with the
// next track and a vertical drag with the cards below, so a double tap is what is left free.
#import <UIKit/UIKit.h>

#define SGKeyGestures @"spotifyglass.gestures"
#define SGKeyGestureSplit @"spotifyglass.gestures.split"
#define SGKeyGestureStep @"spotifyglass.gestures.step"
#define SGKeyGestureZones @"spotifyglass.gestures.zones"

typedef NS_ENUM(NSInteger, SGGestureAction) {
    SGGestureNothing = 0,
    SGGestureSeekBack,
    SGGestureSeekForward,
    SGGesturePlayPause,
    SGGestureNextTrack,
    SGGesturePreviousTrack,
    SGGestureShuffle,
    SGGestureRepeat,
};

NSArray<NSString *> *SGGestureActionNames(void);
NSArray<NSString *> *SGGestureSplitNames(void);
NSArray<NSNumber *> *SGGestureStepChoices(void);

// The split and the seek step as indices into the lists above, and what they mean.
NSInteger SGGestureSplit(void);
NSInteger SGGestureStepChoice(void);
// The split as a grid: 2x1, 3x1 or 3x3.
void SGGestureGrid(NSInteger *columns, NSInteger *rows);
double SGGestureStep(void);

// The action of every cell of the current split, row-major, one entry per cell.
NSArray<NSNumber *> *SGGestureZones(void);
void SGSetGestureZone(NSInteger cell, SGGestureAction action);
void SGResetGestureZones(void);
// Which cell of the current split holds `point`, in a view of size `size`.
NSInteger SGGestureCellAt(CGPoint point, CGSize size);

UIViewController *SGGesturesSettingsPage(void);

// Told of each action a double tap is about to perform, before the player has acted on it; one observer,
// for a look that answers the gesture (the redesign's haptics). Main thread.
void SGGestureSetObserver(void (^observer)(SGGestureAction action));

// Puts the double tap on `host`, the view the player's grid covers, while the switch is on; again on
// every layout pass of the host, so taps Spotify adds later still wait for it. Main thread.
void SGGestureAttach(UIView *host);
