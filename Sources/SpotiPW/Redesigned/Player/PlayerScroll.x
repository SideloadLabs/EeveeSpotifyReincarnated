// Player redesign: the player never scrolls up. Scrolling stays on because Spotify's dismiss pull rides on
// the list's own pan and starts only at its top, so the offset is clamped instead; the insets stay
// Spotify's, since changing one mid-drag moves the offset under the finger.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static NSString *const kListIdentifier = @"scrolling_npv_collection_view_accessibility_identifier";

static __weak UIScrollView *sg_loggedList;

static void holdAtTop(UIScrollView *list) {
    if (![list.accessibilityIdentifier isEqualToString:kListIdentifier]) return;
    CGFloat top = -list.adjustedContentInset.top;
    CGPoint offset = list.contentOffset;
    if (offset.y <= top) return;
    CGFloat past = offset.y - top;
    list.contentOffset = CGPointMake(offset.x, top);

    if (sg_loggedList == list) return;
    sg_loggedList = list;
    SGLog(@"redesign player: scroll held at the top, %.0fpt up taken back (%@)", past, list.isDragging ? @"drag" : @"no finger");
}

%hook _TtC21NowPlaying_ScrollImpl23NPVScrollViewController
- (void)scrollViewDidScroll:(UIScrollView *)list {
    holdAtTop(list);
    %orig;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"]);
}
