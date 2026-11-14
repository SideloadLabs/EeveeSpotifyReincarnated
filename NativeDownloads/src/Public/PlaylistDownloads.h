#pragma once
#import <Foundation/Foundation.h>

// Main-thread callbacks, authenticated native services, bounded cancellable reads.
dispatch_block_t SAPFetchWritablePlaylists(void (^completion)(NSArray<NSDictionary *> *,NSString *));
// Complete, revision-consistent playlist contents. Main-queue callback and cancellation.
dispatch_block_t SAPFetchPlaylistContents(NSString *uri,void (^completion)(NSDictionary *,NSString *));
BOOL SAPStartPlaylistReleaseDownload(NSArray<NSDictionary *> *releases,NSString *playlistURI,NSString *newName,NSString **error);
dispatch_block_t SAPObservePlaylistReleaseDownloads(NSArray<NSDictionary *> *releases,void (^completion)(NSDictionary *));
// A catalog owns live native item evidence; it is discarded on close.
@interface SAPReleaseItemObservation : NSObject
- (void)updateReleases:(NSArray<NSDictionary *> *)releases;
- (void)invalidate;
@end
SAPReleaseItemObservation *SAPObserveReleaseItems(NSArray<NSDictionary *> *releases,void (^completion)(NSDictionary *));
// Compatibility wrapper for callers with a fixed release list.
dispatch_block_t SAPObservePlaylistReleaseItems(NSArray<NSDictionary *> *releases,void (^completion)(NSDictionary *));
BOOL SAPContinuePlaylistReleaseDownloads(NSArray<NSDictionary *> *releases,NSString **error);
void SAPStopPlaylistReleaseDownloads(NSArray<NSDictionary *> *releases);

// Pure wire parsers shared by production and recorded-schema regression tests.
NSDictionary *SAPParseWritablePlaylistPage(NSData *data,NSString **error);
NSDictionary *SAPParsePlaylistContents(NSData *data,NSString *uri,NSString **error);

// Incremental artist workflow: ordered whole-release batches and scoped controls.
BOOL SAPStartPlaylistReleaseDownloadForArtist(NSString *artistURI,NSArray<NSDictionary *> *releases,NSString *playlistURI,NSString *newName,NSString **error);
dispatch_block_t SAPObservePlaylistReleaseDownloadsForArtist(NSString *artistURI,NSArray<NSDictionary *> *releases,void (^completion)(NSDictionary *));
BOOL SAPContinuePlaylistReleaseDownloadsForArtist(NSString *artistURI,NSArray<NSDictionary *> *releases,NSString **error);
// A nil release scope stops all playlist tasks owned by this artist.
void SAPStopPlaylistReleaseDownloadsForArtist(NSString *artistURI,NSArray<NSDictionary *> *releases);
void SAPCancelPlaylistReleaseDownloadsForArtist(NSString *artistURI);
