#pragma once
#import "PlaylistDownloads.h"
#import "PlaylistArtwork.h"
#import "ArtistMetadata.h"
#import "ArtistDownloadSession.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import "TrackJournal.h"
#import "Diagnostics.h"
#import "Deadline.h"


// All registry access and workflow transitions belong to the main queue.
// These declarations are private; exported C/ObjC compatibility entry points
// remain in PlaylistDownloads.h.
#define SAP_PLAYLIST_INTERNAL __attribute__((visibility("hidden")))
enum { SAPPlaylistPageSize=250, SAPPlaylistMaximumItems=10000 };
SAP_PLAYLIST_INTERNAL extern NSString *const SAPPlaylistLibraryService;
SAP_PLAYLIST_INTERNAL extern NSString *const SAPPlaylistDataService;
static inline NSData *SAPPlaylistString(unsigned field,NSString *s){return SAPProtoBytes(field,[s dataUsingEncoding:NSUTF8StringEncoding]);}
static inline NSArray *SAPPlaylistMessages(NSArray *fields,unsigned number){NSMutableArray *out=[NSMutableArray array];for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==number && [f[@"wire"]unsignedIntValue]==2)[out addObject:SAPProtoFields(f[@"value"])?:@[]];return out;}
static inline BOOL SAPPlaylistHasField(NSArray *fields,unsigned number){for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==number)return YES;return NO;}
static inline BOOL SAPPlaylistStatusOK(NSArray *fields,NSString **error){
    NSArray *status=SAPProtoFields(SAPProtoData(fields,1));uint64_t code=SAPProtoNumber(status,1,0);
    if(!fields || !status || code<200 || code>=300){if(error)*error=SAPProtoString(status,2)?:@"Spotify did not confirm the playlist request.";return NO;}return YES;
}
@interface SAPPlaylistDownloadTask : NSObject
@property(nonatomic,copy) NSString *token,*uri,*name,*message,*error,*artistURI;
@property(nonatomic,strong) NSArray *releases,*tracks,*baseline,*missing,*sourceURIList;
@property(nonatomic,strong) NSMutableOrderedSet *orderedTracks;
@property(nonatomic,strong) NSMutableDictionary *releaseTracks;
@property(nonatomic,strong) NSSet *sourceURIs;
@property(nonatomic) NSUInteger index,offset,addedCount,epoch;
@property(nonatomic) BOOL active,stopped,commandPending,submitted,queued,resumeBlocked,cancelled;
@property(nonatomic,copy) dispatch_block_t cancelRead,detachSession;
@property(nonatomic,strong) dispatch_source_t retry,deadline;
@property(nonatomic,strong) NSDictionary *contextState,*stoppedVisuals;
- (BOOL)valid:(NSUInteger)epoch;
- (void)verifyLibrary:(NSString *)uri attempt:(NSUInteger)attempt;
- (BOOL)reserve:(NSString **)error;
- (void)begin;
- (void)resolve;
- (void)save;
- (void)target;
- (void)readTarget;
- (void)append;
- (void)submit;
- (void)finish:(NSString *)error;
- (void)publishMessage:(NSString *)message;
- (void)stop;
- (void)stopRequestedBy:(NSString *)caller reason:(NSString *)reason;
- (void)cancel;
- (BOOL)isQueuedRelease:(NSString *)uri;
@end
@interface SAPIncrementalPlaylistTask : SAPPlaylistDownloadTask
@property(nonatomic,strong) NSArray *plan,*currentBatch,*batchSources,*releasePlan,*appendTracks;
@property(nonatomic,strong) NSDictionary *batchRelease,*batchState,*releasePositions,*albumContextState;
@property(nonatomic,copy) dispatch_block_t detachAlbum;
@property(nonatomic,strong) SAPReleaseItemObservation *releaseObservation;
@property(nonatomic,strong) NSMutableSet *completedTracks;
@property(nonatomic) NSUInteger releaseIndex,appendIndex;
@property(nonatomic,strong) NSMutableSet *verifiedSources,*targetTracks;
@property(nonatomic,strong) dispatch_source_t batchDeadline;
@property(nonatomic) NSUInteger batchEpoch,albumEpoch;
@property(nonatomic) BOOL streamReady,nativeStarted,nativeReady,batchCommitted,finishing,feedClosed,batchWatching,terminating,albumStarted,albumStopPending,sessionReserved;
- (void)appendChunk;
- (void)advanceRelease;
- (void)detachAlbumContext;
- (void)submitPlaylist;
- (void)stopAlbum;
- (void)watchBatch;
- (void)checkBatch;
- (void)settleStop;
- (void)armBatchDeadline;
- (void)detachBatch;
@end

SAP_PLAYLIST_INTERNAL extern NSMutableArray<SAPPlaylistDownloadTask *> *SAPPlaylistTasks;
SAP_PLAYLIST_INTERNAL extern NSMutableDictionary *SAPPlaylistObservers,*SAPPlaylistObserverURIs,*SAPPlaylistObserverSnapshots,*SAPPlaylistObserverArtists;
SAP_PLAYLIST_INTERNAL extern NSUInteger SAPPlaylistItemTaskRevision,SAPPlaylistItemScopeRevision;
SAP_PLAYLIST_INTERNAL void SAPPlaylistEnsureState(void);
SAP_PLAYLIST_INTERNAL void SAPPlaylistPublishTasks(void);
SAP_PLAYLIST_INTERNAL void SAPPlaylistScheduleTasks(void);
SAP_PLAYLIST_INTERNAL void SAPPlaylistReconcileItemObservers(void);
SAP_PLAYLIST_INTERNAL NSDictionary *SAPPlaylistCaptureStoppedVisuals(NSSet *scope);
SAP_PLAYLIST_INTERNAL dispatch_block_t SAPPlaylistReadListFrom(NSString *uri,NSUInteger start,void (^completion)(id,NSString *));
SAP_PLAYLIST_INTERNAL dispatch_block_t SAPPlaylistReadList(NSString *uri,void (^completion)(id,NSString *));
#undef SAP_PLAYLIST_INTERNAL
