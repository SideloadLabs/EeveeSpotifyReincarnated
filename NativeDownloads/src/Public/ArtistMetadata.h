#pragma once
#import <Foundation/Foundation.h>

BOOL SAPIsAlbumURI(NSString *uri);
BOOL SAPIsPlaylistURI(NSString *uri);
NSDictionary *SAPParseArtistMetadata(NSData *response, NSString *artistURI);
void SAPFetchArtistMetadata(NSString *artistURI,
                           void (^completion)(NSDictionary *catalog, NSString *error));
// All callbacks run on main. Cancellation stops new reads and cancels outstanding
// artist-catalog and release-hydration reads owned by this load.
dispatch_block_t SAPFetchArtistMetadataCancellable(NSString *artistURI,
    void (^progress)(NSUInteger completed,NSUInteger total),
    void (^completion)(NSDictionary *catalog,NSString *error));
// Exact album GID and every disc/track are verified before a native mutation.
NSArray<NSString *> *SAPParseArtistAlbumTrackURIs(NSData *response,NSString *albumURI,NSString **reason);
void SAPFetchArtistAlbumTrackURIs(NSString *albumURI,void (^completion)(NSArray<NSString *> *,NSString *));

// Previews contain only settled edition groups, so a visible release identity
// never changes when another edition resolves. Main-thread, bounded batches.
dispatch_block_t SAPFetchArtistMetadataProgressively(NSString *artistURI,
    void (^progress)(NSUInteger completed,NSUInteger total),
    void (^preview)(NSDictionary *catalog),
    void (^completion)(NSDictionary *catalog,NSString *error));
