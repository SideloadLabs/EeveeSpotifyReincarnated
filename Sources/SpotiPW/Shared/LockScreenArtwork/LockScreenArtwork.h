// The playing track's Canvas as the system's animated now playing artwork: from iOS 26 the lock
// screen plays a looping clip behind the controls the way Apple Music plays an animated cover. It
// draws nothing on Spotify's own screens, so it answers under either look.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#define SGKeyLockScreenArtwork @"spotifyglass.lockscreen.animatedartwork"
#define SGKeyLockScreenArtworkSources @"spotifyglass.lockscreen.artworksources"

// Where a clip can come from: the track's Canvas, or the album's animated cover on Apple Music.
extern NSString *const SGArtworkSourceSpotify;
extern NSString *const SGArtworkSourceApple;
// The sources in the user's order, the ones switched off left out; Spotify, then Apple Music until set.
NSArray<NSString *> *SGArtworkOrder(void);
void SGArtworkSetOrder(NSArray<NSString *> *order);

// Whether this iOS has MPMediaItemAnimatedArtwork at all.
BOOL SGAnimatedArtworkAvailable(void);
// Every now playing key this iOS takes a clip under, and the one of them the Canvas goes under with
// the shape it wants there through `aspect`; nil where there is none.
NSArray<NSString *> *SGAnimatedArtworkKeys(void);
NSString *SGAnimatedArtworkKey(CGFloat *aspect);
// `artwork` under `key` in a copy of `info`, everything else left as it stands. The lock screen
// lyrics rewrite the dictionary on a timer, so the key is put back on every one that passes.
NSDictionary *SGArtworkInInfo(NSDictionary *info, id artwork, NSString *key);
// The rows for the Lock screen widget page; below iOS 26 one row reads out what is missing instead.
@class SGModRow;
NSArray<SGModRow *> *SGAnimatedArtworkRows(void);
