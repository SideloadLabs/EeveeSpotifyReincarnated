// Walking and reading Spotify's view trees.
#import <UIKit/UIKit.h>

void SGForEachView(UIView *view, void (^fn)(UIView *));
CGRect SGFrameIn(UIView *view, UIView *target);
// Whether `view` sits under `root`, stopping at a visual effect view on the way up.
BOOL SGIsInside(UIView *view, UIView *root);
// The first wide stack view under `host` with at least two arranged children: a player row, or
// the row of items in the tab bar.
UIStackView *SGRowIn(UIView *host);
// Whether any view under `root` has `marker` in its class name.
BOOL SGHasClass(UIView *root, NSString *marker);

// Artwork, glyphs, text and thin lines (progress bar) keep their colour, everything else goes clear.
BOOL SGKeepsColor(UIView *view);
void SGStripBackgrounds(UIView *view);
BOOL SGIsVisibleColor(CGColorRef color);
BOOL SGIsLightColor(CGColorRef color);
// Spotify's base surface: the neutral #121212 it paints its pages with, or the black AMOLED turns
// that into.
BOOL SGIsBaseSurface(CGColorRef color);
// A painted, card-sized view: the now playing bar's card, for one.
BOOL SGLooksLikeCard(UIView *view, CGColorRef color);
