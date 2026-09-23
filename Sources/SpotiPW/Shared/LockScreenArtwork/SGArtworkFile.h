// The clip on disk: fetched once into Caches, reshaped once for the now playing key, and kept until
// the cap pushes the oldest out. Everything answers off the main thread.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// `done` gets the local file, or nil with `note` saying why. The fetch in flight is dropped first.
void SGArtworkFetch(NSString *identifier, NSString *address, void (^done)(NSURL *file, NSString *note));
void SGArtworkCancelFetch(void);
// The clip centre cropped to `aspect`, width over height. A clip already that shape comes back as it is.
void SGArtworkCrop(NSURL *file, NSString *identifier, CGFloat aspect, void (^done)(NSURL *cropped, NSString *note));
// The clip's first frame, which the system wants the preview still to match; NULL when unreadable.
void SGArtworkFirstFrame(NSURL *file, void (^done)(CGImageRef frame));
