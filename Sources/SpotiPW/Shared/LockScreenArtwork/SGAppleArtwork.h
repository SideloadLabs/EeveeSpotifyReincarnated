// Apple Music's animated album cover, looked up the way music.apple.com does it: the web player's own
// token, one catalog search that carries the covers' HLS playlists, and the single MP4 file a
// playlist's stream is cut from. Only the artist and album names go out, never the account.
#import <Foundation/Foundation.h>

@class SGCanvas;

// `done` runs on the main queue with the clip, or nil and why. `tall` wants the 3:4 cover and takes
// the square one where there is none; otherwise only the square one.
void SGAppleArtworkFind(NSString *artist, NSString *album, BOOL tall, void (^done)(SGCanvas *canvas, NSString *note));

// The steps with no network in them.
NSString *SGAppleTokenIn(NSString *script);
NSDate *SGAppleTokenExpiry(NSString *token);
// The cover's playlist out of a search answer's albums, the same artist's and the same album's
// name first, then one that differs only in its edition: "(Deluxe)", " - Single".
NSURL *SGAppleCoverPlaylist(NSArray *albums, NSString *artist, NSString *album, BOOL tall);
// The stream at about the lock screen's width, HEVC where there is one, out of the master playlist.
NSURL *SGAppleStream(NSString *master, NSURL *base);
// The one file every segment of the stream is a byte range of; nil when they are separate files.
NSURL *SGAppleStreamFile(NSString *media, NSURL *base);
