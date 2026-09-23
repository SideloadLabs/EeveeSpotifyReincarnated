// The redesigned player's hookup of the gestures (Shared/Gestures): the double tap goes on the player's artwork list.
//
// Tree (trees/now-playing.txt): the artwork sits in AccessibleCollectionView, a full screen list of
// the queue scrolled sideways, so the recognizer goes on that and the grid is the screen. Spotify's
// controls are sibling units rather than children of it, so a tap on a button never reaches it.
#import "Core/SGCore.h"
#import "Shared/Gestures/Gestures.h"

// A single tap on the cover is Spotify's way into the tilt mode, the artwork alone in 3D. That is
// the half of a double tap that misses, so while the zones are on it would open on the way to every
// gesture; the tap goes back to Spotify with the switch.
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)handleTap {
    if (SGFlag(SGKeyGestures, NO)) return;
    %orig;
}
%end

%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    SGGestureAttach((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
    ]);
}
