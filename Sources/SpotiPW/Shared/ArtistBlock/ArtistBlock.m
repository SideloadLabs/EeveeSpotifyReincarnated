#import "ArtistBlock.h"
#import "Headers/SPTPlayer.h"

NSString *const SGArtistURI = @"uri";
NSString *const SGArtistName = @"name";

static const NSInteger kMaxCredits = 32;

NSArray<NSDictionary *> *SGBlockedArtists(void) {
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyArtistBlockList];
    return list ?: @[];
}

static void save(NSArray<NSDictionary *> *list) {
    [NSUserDefaults.standardUserDefaults setObject:list forKey:SGKeyArtistBlockList];
}

BOOL SGArtistBlocked(NSString *uri) {
    if (!uri.length) return NO;
    for (NSDictionary *artist in SGBlockedArtists()) {
        if ([artist[SGArtistURI] isEqualToString:uri]) return YES;
    }
    return NO;
}

void SGBlockArtist(NSDictionary *artist) {
    if (SGArtistBlocked(artist[SGArtistURI])) return;
    save([SGBlockedArtists() arrayByAddingObject:artist]);
}

void SGUnblockArtist(NSString *uri) {
    NSPredicate *other = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *artist, NSDictionary *bindings) {
        return ![artist[SGArtistURI] isEqualToString:uri];
    }];
    save([SGBlockedArtists() filteredArrayUsingPredicate:other]);
}

static NSString *uriString(id value) {
    if ([value isKindOfClass:NSURL.class]) return ((NSURL *)value).absoluteString;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static void addArtist(NSMutableArray<NSDictionary *> *artists, NSString *uri, NSString *name) {
    if (![uri hasPrefix:@"spotify:artist:"]) return;
    for (NSDictionary *artist in artists) {
        if ([artist[SGArtistURI] isEqualToString:uri]) return;
    }
    [artists addObject:@{SGArtistURI: uri, SGArtistName: name.length ? name : uri}];
}

static NSString *nameString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSArray<NSDictionary *> *SGArtistsOfTrack(id object) {
    if (![object respondsToSelector:@selector(artistURI)] || ![object respondsToSelector:@selector(metadata)]) return @[];
    SPTPlayerTrack *track = object;
    NSDictionary *metadata = [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : nil;
    NSMutableArray<NSDictionary *> *artists = [NSMutableArray array];
    addArtist(artists, uriString(track.artistURI), nameString(track.artistName));
    addArtist(artists, uriString(metadata[@"artist_uri"]), nameString(metadata[@"artist_name"]));
    for (NSInteger i = 1; i < kMaxCredits; i++) {
        NSString *uri = uriString(metadata[[NSString stringWithFormat:@"artist_uri:%ld", (long)i]]);
        if (!uri) break;
        addArtist(artists, uri, nameString(metadata[[NSString stringWithFormat:@"artist_name:%ld", (long)i]]));
    }
    return artists;
}
