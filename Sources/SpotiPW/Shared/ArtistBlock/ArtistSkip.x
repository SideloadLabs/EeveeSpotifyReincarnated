// Skips a track by a blocked artist the moment the player moves onto it, whatever started it: the
// queue, autoplay, a radio or a tap. The track is read off SPTEsperantoPlayer, the app's player,
// which the now playing bar asks for its state from launch on; the full screen player's playback
// controller only exists while that player does, so it is the skip's first choice, not the source. A
// track change is heard from the lock screen's now playing info, which Spotify sets on every track.
// A track is looked at once, so an update within it does not skip twice.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "ArtistBlock.h"
#import "Headers/SPTPlayer.h"
#import "Headers/SPTNowPlayingPlaybackController.h"

static __weak id sg_player;
static __weak SPTNowPlayingPlaybackControllerImplementation *sg_controller;
static NSString *sg_seenTrack;

static SPTPlayerTrack *playingTrack(BOOL explain) {
    id player = sg_player;
    SPTPlayerState *state = [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
    SPTPlayerTrack *track = [state respondsToSelector:@selector(track)] ? state.track : nil;
    if (!track && explain) {
        SGLog(@"artist block: no track, player %@ state %@",
              player ? NSStringFromClass([player class]) : @"nil", state ? NSStringFromClass(state.class) : @"nil");
    }
    return track;
}

NSArray<NSDictionary *> *SGPlayingArtists(void) {
    SPTPlayerTrack *track = playingTrack(YES);
    NSArray<NSDictionary *> *artists = SGArtistsOfTrack(track);
    if (track && !artists.count) {
        SGLog(@"artist block: no artists in %@, artistURI %@ (%@)", NSStringFromClass(track.class),
              [track respondsToSelector:@selector(artistURI)] ? track.artistURI : @"-",
              [track respondsToSelector:@selector(artistURI)] ? NSStringFromClass([track.artistURI class]) : @"-");
    }
    return artists;
}

static NSString *trackKey(SPTPlayerTrack *track) {
    id uri = [track respondsToSelector:@selector(URI)] ? track.URI : nil;
    return [uri isKindOfClass:NSURL.class] ? ((NSURL *)uri).absoluteString : [uri description];
}

static NSDictionary *blockedArtistOf(SPTPlayerTrack *track) {
    NSArray<NSDictionary *> *artists = SGArtistsOfTrack(track);
    if (!SGFlag(SGKeyArtistBlockFeatured, NO) && artists.count > 1) artists = @[artists.firstObject];
    for (NSDictionary *artist in artists) {
        if (SGArtistBlocked(artist[SGArtistURI])) return artist;
    }
    return nil;
}

static void skip(SPTPlayerTrack *track, NSDictionary *artist) {
    SPTNowPlayingPlaybackControllerImplementation *controller = sg_controller;
    id player = sg_player;
    if (controller.canSkipNext) {
        [controller skipToNextWhileDragging:NO];
    } else if ([player respondsToSelector:@selector(skipToNextTrack)]) {
        [(id<SPTPlayer>)player skipToNextTrack];
    } else {
        SGLog(@"artist block: %@ by %@ cannot be skipped", track.trackTitle, artist[SGArtistName]);
        return;
    }
    SGLog(@"artist block: skipped %@ by %@", track.trackTitle, artist[SGArtistName]);
}

static void trackMayHaveChanged(void) {
    SPTPlayerTrack *track = playingTrack(NO);
    NSString *key = trackKey(track);
    if (!key || [key isEqualToString:sg_seenTrack]) return;
    sg_seenTrack = key;

    NSDictionary *artist = blockedArtistOf(track);
    if (artist) skip(track, artist);
}

%hook SPTEsperantoPlayer
- (id)state {
    if (!sg_player) {
        sg_player = self;
        SGLog(@"artist block: player found");
    }
    return %orig;
}
%end

%hook SPTNowPlayingPlaybackControllerImplementation
- (id)initWithPlayer:(id)player testManager:(id)manager inStreamClient:(id)client {
    id controller = %orig;
    sg_controller = controller;
    return controller;
}
%end

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    if (!SGFlag(SGKeyArtistBlock, NO)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ trackMayHaveChanged(); });
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"SPTEsperantoPlayer", @"SPTNowPlayingPlaybackControllerImplementation", @"MPNowPlayingInfoCenter"]);
}
