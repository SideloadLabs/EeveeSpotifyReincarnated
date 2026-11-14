#pragma once
#import <Foundation/Foundation.h>
void SAPInstallTrackDownloader(void);
void SAPDownloadCurrentTrack(void (^message)(NSString *));
void SAPDownloadCurrentAlbum(void (^message)(NSString *));
void SAPCancelTrackDownload(void);
void SAPVerifyCurrentTrack(void (^message)(NSString *));
BOOL SAPTrackDownloadActive(void);
NSString *SAPTrackDownloadSummary(void);
NSDictionary *SAPTrackDownloadReport(void);
NSDictionary *SAPTrackDownloadReportWithJournal(NSDictionary *journalReport);
// Uses Spotify's already authenticated in-process transport. The payload is
// read-only and the callback is delivered on the main queue.
void SAPCallReadOnlyService(NSString *serviceName, NSString *method, NSData *payload,
                            void (^completion)(NSData *response, NSString *error));
// Like SAPCallReadOnlyService, but returns an idempotent cancellation block.
// Calling it suppresses completion and cancels the active read-only lifetime
// and deadline; it never cancels or replays a mutation.
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *serviceName, NSString *method, NSData *payload,
                                                    void (^completion)(NSData *response, NSString *error));
// Subscribes to one supported read-only Offline stream. The callback receives
// each response on the main queue until the returned block is called.
// Endpoint ownership lasts only for this subscription. Missing/unproven routes
// can use at most two candidates, with read-only verification before fallback.
dispatch_block_t SAPSubscribeReadOnlyService(NSString *serviceName, NSString *method, NSData *payload,
                                              void (^onResponse)(NSData *response, NSString *error));
// Explicit user command. One verified endpoint, one send, no replay on timeout.
typedef NS_ENUM(NSUInteger, SAPCommandInvocationDisposition) {
    SAPCommandNotInvoked,
    SAPCommandInvoked
};
// NotInvoked is guaranteed only before entering the native transport method.
// Invoked includes timeouts, invalid replies and exceptions; it is not an ACK.
void SAPCallOfflineCommandOnceWithDisposition(NSString *method,NSData *payload,
    void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition));
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void (^completion)(NSData *,NSString *));
// Exact native Collection.Add album payload; one send and no mutation replay.
void SAPAddAlbumToLibraryOnce(NSString *albumURI,void (^completion)(NSData *,NSString *));
// User-confirmed playlist creation/append only. One proven transport, no replay.
void SAPCallPlaylistModificationOnce(BOOL rootlist,NSData *payload,void (^completion)(NSData *,NSString *));
void SAPSetPlaylistOfflineOnce(NSString *playlistURI,BOOL enabled,void (^completion)(NSData *,NSString *));
void SAPSetPlaylistOfflineOnceWithDisposition(NSString *playlistURI,BOOL enabled,
    void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition));
