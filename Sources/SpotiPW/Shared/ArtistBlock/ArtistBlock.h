// Artist block: tracks by artists on the list are skipped as they come up (ArtistSkip.x). An artist
// is kept by URI, with the name it had when it was blocked, so a rename or a namesake changes nothing.
#import <UIKit/UIKit.h>

#define SGKeyArtistBlock @"spotifyglass.artistBlock"
#define SGKeyArtistBlockFeatured @"spotifyglass.artistBlock.featured"   // off: the main artist only
#define SGKeyArtistBlockList @"spotifyglass.artistBlock.list"

extern NSString *const SGArtistURI;    // NSString, spotify:artist:…
extern NSString *const SGArtistName;   // NSString

NSArray<NSDictionary *> *SGBlockedArtists(void);
void SGBlockArtist(NSDictionary *artist);
void SGUnblockArtist(NSString *uri);
BOOL SGArtistBlocked(NSString *uri);

// The artists of a track, the main one first, as dictionaries of the keys above.
NSArray<NSDictionary *> *SGArtistsOfTrack(id track);
// ArtistSkip.x: the artists of the track playing now, empty before the player has reported one.
NSArray<NSDictionary *> *SGPlayingArtists(void);

UIViewController *SGArtistBlockSettingsPage(void);
