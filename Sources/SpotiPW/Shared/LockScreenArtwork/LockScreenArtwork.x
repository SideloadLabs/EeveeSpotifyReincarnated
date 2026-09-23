// The track's Canvas or its album's Apple Music cover as the lock screen's animated artwork. The key
// is put on every dictionary that goes out, so the lock screen lyrics' rewrites carry it too.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "LockScreenArtwork.h"
#import "SGAppleArtwork.h"
#import "SGArtworkFile.h"
#import "SGCanvas.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

static NSString *const kCanvazAddress = @"https://spclient.wg.spotify.com/canvaz-cache/v0/canvases";

// Spotify sets the now playing info from several threads; what the hook reads is behind the lock and
// everything else is main thread.
static NSObject *sg_lock;
static NSDictionary *sg_info;
static CFAbsoluteTime sg_infoAt;
static MPMediaItemArtwork *sg_cover;
static id sg_artwork;
static NSString *sg_key;

static NSString *sg_wanted;
static NSString *sg_playing;   // the source the artwork set for sg_wanted came from
static NSString *sg_offered;
static CGFloat sg_aspect;

static UIImage *coverImage(CGSize size) {
    MPMediaItemArtwork *cover;
    @synchronized (sg_lock) {
        cover = sg_cover;
    }
    return [cover imageWithSize:size] ?: [cover imageWithSize:cover.bounds.size];
}

// The system drops the whole artwork when the still is more than 3 % off the shape it asked for.
static UIImage *filled(UIImage *image, CGSize size) {
    if (!image || size.width < 1 || size.height < 1 || image.size.width < 1 || image.size.height < 1) return image;
    size = CGSizeMake(round(size.width), round(size.height));
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
}

static id artworkFor(NSString *artworkID, NSURL *file, UIImage *still) {
    if (@available(iOS 26.0, *)) {
        return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
            previewImageRequestHandler:^(CGSize size, void (^done)(UIImage *image)) {
                SGLog(@"lock artwork: still asked at %.0fx%.0f", size.width, size.height);
                done(filled(still ?: coverImage(size), size));
            }
            videoAssetFileURLRequestHandler:^(CGSize size, void (^done)(NSURL *url)) {
                SGLog(@"lock artwork: clip asked at %.0fx%.0f", size.width, size.height);
                done(file);
            }];
    }
    return nil;
}

// Every credited artist, the way the metadata lists them.
static NSString *artistOf(SPTPlayerTrack *track) {
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger at = 0; ; at++) {
        NSString *name = metadata[at ? [NSString stringWithFormat:@"artist_name:%lu", (unsigned long)at] : @"artist_name"];
        if (![name isKindOfClass:NSString.class] || !name.length) break;
        [names addObject:name];
    }
    if (!names.count && track.artistName.length) [names addObject:track.artistName];
    return names.count ? [names componentsJoinedByString:@", "] : nil;
}

// The last dictionary sent again so the system asks for the clip that has just landed, its position
// run on to now. The artist comes off the player rather than out of the dictionary: the lock screen
// lyrics may have put the line being sung there before this hook ever saw it, and a line sent back
// as the track's own would stick until Spotify set the info itself again.
static void resend(void) {
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_info;
        reportedAt = sg_infoAt;
    }
    if (!info.count) return;
    NSMutableDictionary *now = [info mutableCopy];
    NSString *artist = artistOf(SGPlayerState().track);
    if (artist) now[MPMediaItemPropertyArtist] = artist;
    NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    if (elapsed) {
        double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
        now[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed.doubleValue + rate * (CFAbsoluteTimeGetCurrent() - reportedAt));
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = now;
}

static void play(NSString *uri, SGCanvas *canvas, NSString *source) {
    SGLog(@"lock artwork: clip for %@ from %@: %@", uri, source, canvas.address);
    SGArtworkFetch(canvas.identifier, canvas.address, ^(NSURL *file, NSString *note) {
        SGLog(@"lock artwork: %@ %@", canvas.identifier, note);
        if (!file) return;
        SGArtworkCrop(file, canvas.identifier, sg_aspect, ^(NSURL *ready, NSString *cropNote) {
            SGLog(@"lock artwork: %@ %@", canvas.identifier, cropNote);
            if (!ready) return;
            SGArtworkFirstFrame(ready, ^(CGImageRef frame) {
                UIImage *still = frame ? [UIImage imageWithCGImage:frame] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![sg_wanted isEqualToString:uri]) return;
                    id artwork = artworkFor([canvas.identifier stringByAppendingString:uri], ready, still);
                    @synchronized (sg_lock) {
                        sg_artwork = artwork;
                        sg_key = sg_offered;
                    }
                    sg_playing = source;
                    SGLog(@"lock artwork: %@ set under %@", uri, sg_offered);
                    resend();
                });
            });
        });
    });
}

static void askCanvaz(NSString *uri, void (^done)(SGCanvas *canvas, NSString *note)) {
    NSString *authorization = SGKaraokeSpotifyAuthorization();
    NSData *body = SGCanvazRequestBody(uri);
    if (!authorization || !body) {
        done(nil, @"no token for canvaz yet");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kCanvazAddress]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.allowsConstrainedNetworkAccess = NO;
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *answer, NSURLResponse *response, NSError *error) {
        SGCanvas *canvas = SGCanvazFromBody(answer);
        NSString *note = [NSString stringWithFormat:@"canvaz status %ld, %lu bytes, error %@",
                          (long)[(NSHTTPURLResponse *)response statusCode], (unsigned long)answer.length, error.localizedDescription];
        dispatch_async(dispatch_get_main_queue(), ^{ done(canvas, note); });
    }] resume];
}

// One source's clip for the track, on the main queue; nil when it has none.
static void ask(NSString *source, NSString *uri, SPTPlayerTrack *track, SGCanvas *fromMetadata, void (^done)(SGCanvas *canvas, NSString *note)) {
    if ([source isEqualToString:SGArtworkSourceSpotify]) {
        if (fromMetadata) done(fromMetadata, @"track metadata");
        else askCanvaz(uri, done);
        return;
    }
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    SGAppleArtworkFind(metadata[@"artist_name"] ?: track.artistName, metadata[@"album_title"], sg_aspect < 0.9, done);
}

static void walk(NSString *uri, SPTPlayerTrack *track, SGCanvas *fromMetadata, NSArray<NSString *> *order, NSUInteger at) {
    if (at >= order.count) {
        SGLog(@"lock artwork: no clip for %@ from %@", uri, order.count ? [order componentsJoinedByString:@", "] : @"no source");
        return;
    }
    ask(order[at], uri, track, fromMetadata, ^(SGCanvas *canvas, NSString *note) {
        if (![sg_wanted isEqualToString:uri]) return;
        if (canvas.video) {
            play(uri, canvas, order[at]);
            return;
        }
        SGLog(@"lock artwork: %@ has no clip for %@ (%@)", order[at], uri, canvas ? @"a still canvas" : note);
        walk(uri, track, fromMetadata, order, at + 1);
    });
}

// Asked on each track until MediaPlayer names one: before the framework is up it answers with none.
static BOOL keyOffered(void) {
    if (sg_offered) return YES;
    sg_offered = SGAnimatedArtworkKey(&sg_aspect);
    SGLog(@"lock artwork: iOS takes %@, going under %@ at %.2f",
          [SGAnimatedArtworkKeys() componentsJoinedByString:@", "] ?: @"nothing", sg_offered, sg_aspect);
    return sg_offered != nil;
}

static void resolve(SPTPlayerTrack *track) {
    // Read on every track, so the switch needs no restart.
    if (!SGFlag(SGKeyLockScreenArtwork, YES)) {
        if (sg_wanted) {
            sg_wanted = nil;
            SGArtworkCancelFetch();
            sg_playing = nil;
            @synchronized (sg_lock) {
                sg_artwork = nil;
                sg_key = nil;
            }
            SGLog(@"lock artwork: switched off");
            resend();
        }
        return;
    }
    if (!keyOffered()) return;
    NSString *uri = SGURIString(track.URI);
    SGCanvas *canvas = SGCanvasFromMetadata([track respondsToSelector:@selector(metadata)] ? track.metadata : nil);
    // Pause, shuffle and the like report the same track again; only metadata that landed late is news.
    static BOOL fromMetadata;
    BOOL same = uri == sg_wanted || [uri isEqualToString:sg_wanted];
    if (same && (fromMetadata || !canvas)) return;
    fromMetadata = canvas != nil;
    NSArray<NSString *> *order = SGArtworkOrder();
    // A Canvas landing late is no news with Spotify off, or with a source asked before it already playing.
    NSUInteger spotifyAt = [order indexOfObject:SGArtworkSourceSpotify];
    if (same && (spotifyAt == NSNotFound || (sg_playing && [order indexOfObject:sg_playing] < spotifyAt))) return;
    sg_wanted = uri;
    sg_playing = nil;
    SGArtworkCancelFetch();
    @synchronized (sg_lock) {
        sg_artwork = nil;
        sg_key = nil;
    }
    if (!uri) return;
    walk(uri, track, canvas, order, 0);
}

@interface SGArtworkWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGArtworkWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    static NSString *seen;
    NSString *uri = SGURIString(state.track.URI);
    if (uri && ![uri isEqualToString:seen]) {
        seen = uri;
        NSDictionary *metadata = [state.track respondsToSelector:@selector(metadata)] ? state.track.metadata : nil;
        SGLog(@"lock artwork: track %@, canvas keys %@", uri,
              [[metadata.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'canvas'"]] componentsJoinedByString:@","]);
    }
    resolve(state.track);
}
@end

static SGArtworkWatcher *sg_watcher;

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    id artwork;
    NSString *key;
    @synchronized (sg_lock) {
        if (info[MPMediaItemPropertyArtwork]) sg_cover = info[MPMediaItemPropertyArtwork];
        sg_info = info;
        sg_infoAt = CFAbsoluteTimeGetCurrent();
        artwork = sg_artwork;
        key = sg_key;
    }
    %orig(SGArtworkInInfo(info, artwork, key));
}
%end

%ctor {
    if (!SGAnimatedArtworkAvailable()) {
        SGLog(@"lock artwork: off, animated artwork needs iOS 26");
        return;
    }
    sg_lock = [NSObject new];
    sg_watcher = [SGArtworkWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    %init;
    SGRequireClasses(@[@"MPNowPlayingInfoCenter"]);
    SGLog(@"lock artwork: on");
}
