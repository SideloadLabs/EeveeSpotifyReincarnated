#pragma once
#import <Foundation/Foundation.h>
// All entry points and snapshots are on main. Detaching cancels UI state reads
// owned by the UI. Pending work keeps native completion observations through
// bounded read-only stream repair. Exhaustion retains selections and uncertain
// submitted reservations for an explicit refresh. One controlled album recovery
// may re-register an exclusively owned, acknowledged Add after fresh exact item
// verification and observed native removal; ambiguous mutations are never replayed.
// Native state 3 alone completes a context. Re-registration may redownload cache.
// A visible catalog extends one scope; only added contexts need initial reads.
// Observer releases with follow_external_changes=YES retain a scoped read-only
// native stream through external Stop/Start until the observation is invalidated.
@interface SAPArtistSessionObservation : NSObject
- (void)extendReleases:(NSArray<NSDictionary *> *)releases;
- (void)refresh;
- (void)invalidate;
@end
SAPArtistSessionObservation *SAPObserveArtistSession(NSArray<NSDictionary *> *releases,void (^completion)(NSDictionary *));
dispatch_block_t SAPObserveArtistDownloadSession(NSArray<NSDictionary *> *catalogReleases,void (^completion)(NSDictionary *snapshot));
SAPArtistSessionObservation *SAPObserveArtistSessionForArtist(NSString *artistURI,NSArray<NSDictionary *> *releases,void (^completion)(NSDictionary *));
void SAPCancelArtistDownloadSession(NSString *artistURI);
// Cancel one task lease. YES means its exclusive native Stop is still pending.
BOOL SAPCancelArtistDownloadOwner(NSString *artistURI,NSString *ownerToken);
BOOL SAPContinueArtistDownloads(NSString *artistURI,NSArray<NSDictionary *> *releases,NSString **error);
void SAPClosePlaylistDownloadFeed(NSString *playlistURI);
void SAPForgetPlaylistDownloadIntent(NSString *playlistURI);
// Reserve a complete task batch in FIFO order without native reads or mutations.
// Append activates each matching task lease in place after its metadata is ready.
// The task ticket also retains its final playlist position; cancel/release its
// owner on every task exit, including successful completion.
BOOL SAPReserveArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases,NSString **error);
BOOL SAPAppendArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases,NSString **error);
BOOL SAPContinueArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases,NSString **error);
void SAPStopArtistDownloadSessionRelease(NSString *albumURI);
void SAPStopArtistDownloadSessionReleases(NSArray<NSDictionary *> *catalogReleases);
void SAPStopArtistDownloadSessionReleasesForArtist(NSString *artistURI,NSArray<NSDictionary *> *catalogReleases);
void SAPStopArtistDownloadSession(void);
