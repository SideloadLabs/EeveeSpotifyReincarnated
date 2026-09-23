// A moving field of the artwork's colours, the Music app's animated background behind its player
// (issue #59): five soft discs of colour, one for each quarter of the artwork and one for the whole of
// it, each drifting on a slow loop of its own and breathing in size, over the artwork's main colour and
// under a shade that deepens towards the bottom, where the controls are.
//
// All of it is Core Animation: radial gradient layers moved by repeating animations that the render
// server plays, so the app itself does no work per frame -- no display link, no timer, nothing redrawn
// -- and a paused layer tree costs nothing at all. The animations ask for 30 frames a second (the discs
// are soft and slow; more would only spend the GPU) and allow up to 60, so they can fall in with other
// sources rather than holding them down.
//
// Stopping holds every disc where it is and starting again carries on from there, so the owner can stop
// it as often as it likes (the player's transition, the app leaving the screen) without a jump.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

@interface SGRFlowLayer : CALayer
// Five colours, as -[SGRPalette flowColors] gives them: top left, top right, bottom left, bottom right,
// the whole artwork's. Animated, they blend into the new ones where the discs are.
- (void)setColors:(NSArray<UIColor *> *)colors animated:(BOOL)animated;
// The colour under the discs, darker than the artwork's main one; nil before any colours are set.
@property (nonatomic, readonly) UIColor *baseColor;
// Drifting, or held still where it is. Off to begin with.
@property (nonatomic) BOOL moving;
@end
