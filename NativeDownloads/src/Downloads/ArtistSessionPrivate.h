#pragma once
// Private session ownership shared across separate implementation units.
#import "ArtistDownloadSession.h"
#import "ArtistMetadata.h"
#import "TrackDownload.h"
#import "TrackJournal.h"
#import "NativeOffline.h"
#import "WireProto.h"
#import "Deadline.h"
#include <math.h>

static NSString *const offlineService=@"spotify.offline_esperanto.proto.Offline";
static const NSUInteger inactiveStateCacheLimit=256;
#ifdef SAP_TESTING
extern double SAPArtistWorkTimeoutSeconds;
extern double SAPArtistRepairTimeoutSeconds;
extern double SAPArtistRecoverySettleSeconds;
#else
extern const double SAPArtistWorkTimeoutSeconds;
extern const double SAPArtistRepairTimeoutSeconds;
extern const double SAPArtistRecoverySettleSeconds;
#endif
// Albums and singles follow Spotify's own manual path: every selected release is
// prepared and sent as soon as it is ready, and Spotify schedules the transfers.
// Preparation (state read, library membership) stays bounded to a few releases
// at a time. Playlists keep the ordered two-slot window their feeds rely on.
#ifdef SAP_TESTING
extern BOOL SAPArtistDirectAlbumSubmission;
#else
static const BOOL SAPArtistDirectAlbumSubmission=YES;
#endif
static const NSUInteger SAPArtistPreparationWindow=4;
static const NSUInteger SAPArtistSubmittedLimit=256;
static inline BOOL SAPArtistDirectURI(NSString *uri){return SAPArtistDirectAlbumSubmission && SAPIsAlbumURI(uri);}
static inline NSArray *commandFields(NSData *data){
    NSArray *fields=SAPProtoFields(data);if(!fields)return nil;
    for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]!=0)return nil;
    return fields;
}
static inline double clockNow(void) {return NSProcessInfo.processInfo.systemUptime;}
static inline double floatNumber(NSArray *fields,unsigned number) {
    for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==number && [field[@"wire"]unsignedIntValue]==5) {
        float value=0;NSData *data=field[@"value"];if(data.length==4)memcpy(&value,data.bytes,4);return isfinite(value)?value:0;
    }
    return 0;
}
static inline NSData *urisRequest(NSArray *uris,unsigned field) {
    NSMutableData *data=[NSMutableData data];for(NSString *uri in uris)[data appendData:SAPProtoBytes(field,[uri dataUsingEncoding:NSUTF8StringEncoding])];return data;
}
static inline NSData *contextRequest(NSArray *uris) {
    // State only: no track-list scan is needed for the native context state.
    NSMutableData *data=[SAPProtoBytes(1,SAPProtoInteger(1,0))mutableCopy];[data appendData:urisRequest(uris,3)];return data;
}
static inline NSNumber *exactContextState(NSData *data,NSString *uri) {
    NSArray *envelope=SAPProtoFields(data);if(!envelope)return nil;NSNumber *state=nil;
    for(NSDictionary *field in envelope){
        unsigned number=[field[@"number"]unsignedIntValue],wire=[field[@"wire"]unsignedIntValue];
        if(number==2 && (wire!=0 || [field[@"value"]unsignedLongLongValue]))return nil;
        if(number!=1)continue;if(wire!=2 || state)return nil;
        NSArray *entry=SAPProtoFields(field[@"value"]),*info=SAPProtoFields(SAPProtoData(entry,1));
        if(!entry || !info || ![SAPProtoString(info,1)isEqual:uri])return nil;
        NSUInteger stateFields=0;for(NSDictionary *part in info)if([part[@"number"]unsignedIntValue]==2){if([part[@"wire"]unsignedIntValue]!=0 || ++stateFields>1)return nil;}
        uint64_t code=SAPProtoNumber(info,2,0);if(code>5)return nil;state=@(code);
    }return state;
}
static inline BOOL activeNative(NSDictionary *state) {NSUInteger s=[state[@"native_state"]unsignedIntegerValue];return s==2 || s==4 || s==5;}
static inline BOOL validContextURI(NSString *uri){return SAPIsAlbumURI(uri) || SAPIsPlaylistURI(uri);}
static inline NSArray *contextCommandFields(NSData *data,NSString *uri,uint64_t *code){
    NSArray *fields=SAPIsPlaylistURI(uri)?SAPProtoFields(data):commandFields(data);
    if(SAPIsPlaylistURI(uri)){
        NSArray *status=SAPProtoFields(SAPProtoData(fields,1));if(!status || !SAPProtoNumber(status,1,0))return nil;
        uint64_t value=SAPProtoNumber(status,1,0);*code=value>=200&&value<300?0:value;
    }else *code=SAPProtoNumber(fields,1,0);
    return fields;
}
static inline void contextCommandWithDisposition(NSString *uri,BOOL enabled,void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)){
    if(SAPIsPlaylistURI(uri))SAPSetPlaylistOfflineOnceWithDisposition(uri,enabled,completion);
    else SAPCallOfflineCommandOnceWithDisposition(enabled?@"AddDownload":@"RemoveDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),completion);
}
static inline void contextCommand(NSString *uri,BOOL enabled,void (^completion)(NSData *,NSString *)){
    contextCommandWithDisposition(uri,enabled,^(NSData *data,NSString *error,__unused SAPCommandInvocationDisposition disposition){completion(data,error);});
}
static inline id ownerKey(NSString *artist,NSString *token){return token.length?@[artist,token]:artist;}
static inline NSString *ownerArtist(id owner){return [owner isKindOfClass:NSArray.class]?[owner firstObject]:owner;}
static inline id releaseOwner(NSDictionary *release){
    NSString *artist=[release[@"artist_uri"]isKindOfClass:NSString.class]?release[@"artist_uri"]:nil;
    NSString *token=[release[@"owner_token"]isKindOfClass:NSString.class]?release[@"owner_token"]:nil;
    return artist.length?ownerKey(artist,token):(id)NSNull.null;
}

static inline NSComparisonResult compareQueueOrder(NSDictionary *a,NSDictionary *b){
    NSUInteger ar=[a[@"rank"]unsignedIntegerValue],br=[b[@"rank"]unsignedIntegerValue];
    if(ar!=br)return ar<br?NSOrderedAscending:NSOrderedDescending;
    NSUInteger ai=[a[@"ordinal"]unsignedIntegerValue],bi=[b[@"ordinal"]unsignedIntegerValue];
    return ai<bi?NSOrderedAscending:ai>bi?NSOrderedDescending:NSOrderedSame;
}


@class SAPArtistDownloadSession;
@interface SAPArtistAlbumOperation : NSObject
@property(nonatomic,weak) SAPArtistDownloadSession *session;
@property(nonatomic,strong) NSDictionary *item;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSDictionary *releaseGate;
@property(nonatomic,readonly) NSString *uri;
@property(nonatomic,copy) dispatch_block_t cancelRead;
@property(nonatomic,strong) dispatch_source_t retry,workDeadline;
@property(nonatomic) NSUInteger epoch,retryEpoch,workEpoch,readEpoch,sequence;
@property(nonatomic) BOOL downloadSent,stopped,commandPending,sawNativeActive,readyForDownload,hasTrustedCounts,paused,needsReadRepair,libraryAddSent;
@property(nonatomic) BOOL singlePairOccupied,playlistFeedOpen,discardStoppedIntent;
@property(nonatomic) BOOL countReadAttempted,completionReadAttempted;
@property(nonatomic) BOOL ownAddAcknowledged,recoveryAttempted,recoveryOwnZero;
@property(nonatomic,copy) NSString *recoveryStage;
@property(nonatomic,strong) dispatch_source_t recoveryTimer;
@property(nonatomic) NSUInteger recoveryEpoch;
@property(nonatomic) double libraryDeadline;
@property(nonatomic) double workDeadlineArmedAt;
@property(nonatomic) NSUInteger workDeadlineOperationEpoch;
// Watch generation current when AddDownload was sent; earlier streams cannot
// describe this attempt.
@property(nonatomic) NSUInteger submittedWatchEpoch;
@end

@interface SAPArtistDownloadSession : NSObject
@property(nonatomic,strong) NSMutableDictionary *states,*observers,*observerURIs,*initialCancels,*observedURIRefCounts,*initialReadURICounts,*initialReadURILists,*initialReadOwners,*observerArtists,*contextOwners,*artistContexts,*stopTokens,*stopReadCancels;
@property(nonatomic,strong) NSMutableDictionary<NSString *,SAPArtistAlbumOperation *> *operations;
@property(nonatomic,strong) SAPArtistAlbumOperation *lastSubmittedOperation;
@property(nonatomic,strong) NSMutableArray *queue,*watchCancels,*inactiveStateLRU;
@property(nonatomic,strong) NSMutableDictionary *stoppedItems,*readyItems,*externalWatchRefCounts,*batchTickets,*queueOrders,*leaseOrders;
@property(nonatomic,strong) NSMutableOrderedSet *stoppedOrder;
@property(nonatomic,strong) NSMutableSet *initialReads,*stopOperations,*stopSentURIs,*queuedURIs,*abandonedURIs,*forcedOfflineStops;
@property(nonatomic,copy) NSArray *watchURIs,*watchNativeURIs;
@property(nonatomic,copy) NSDictionary *watchOwners;
@property(nonatomic,strong) NSMutableOrderedSet *pendingCacheTouches;
@property(nonatomic,strong) dispatch_source_t watchDeadline;
@property(nonatomic,strong) dispatch_source_t repairDeadline;
@property(nonatomic,copy) dispatch_block_t cancelRepairRead;
@property(nonatomic,strong) NSMutableSet *watchPendingFirst;
@property(nonatomic) NSUInteger watchEpoch,stopBatchDepth,nextSequence,nextQueueRank;
@property(nonatomic) NSUInteger repairEpoch,repairAttempts,repairEpisodes;
@property(atomic) NSUInteger prepareEpoch;
@property(nonatomic) BOOL prepared,preparing,watchSuspended,filling,admitting;
@property(nonatomic) BOOL repairing,repairAwaitingStreams,watchNeedsRenewal,observationPaused;
@property(nonatomic) BOOL watchRenewalScheduled,nextScheduled,watchRenewalForced;
@property(nonatomic,copy) NSString *error;
@end

@interface SAPArtistDownloadSession (Ownership)
- (void)enqueue:(NSDictionary *)item order:(NSDictionary *)order;
- (void)recordLease:(id)owner uri:(NSString *)uri order:(NSDictionary *)order;
- (void)refreshQueuedURI:(NSString *)uri;
- (NSUInteger)ticketOrdinal:(id)owner uri:(NSString *)uri;
- (NSUInteger)reserveTicket:(id)owner;
- (void)releaseTicket:(id)owner;
- (void)registerOwner:(id)artist uri:(NSString *)uri;
- (void)clearOwners:(NSString *)uri;
@end

@interface SAPArtistDownloadSession (State)
- (NSMutableDictionary *)stateFor:(NSString *)uri;
- (void)noteCacheTouch:(NSString *)uri;
- (BOOL)isProtectedFromCache:(NSString *)uri;
- (void)refreshCacheTouches;
- (void)trimInactiveStates;
- (NSDictionary *)publicState:(NSDictionary *)raw;
- (void)publish;
- (void)rememberStopped:(NSDictionary *)item;
@end

@interface SAPArtistDownloadSession (Observation)
- (void)cancelInitialReads;
- (void)cancelInitialReadsForOwner:(NSString *)owner;
- (void)finishInitialRead:(NSString *)identifier;
- (void)cancelWatch;
- (void)cancelRepair;
- (void)suspendObservation:(NSString *)reason;
- (void)resumeObservation;
- (void)repairWatch:(NSString *)reason;
- (void)tryRepairWatch;
- (void)finishRepair;
- (void)apply:(NSData *)data progress:(BOOL)progress;
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live;
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live owners:(NSDictionary *)owners;
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live owners:(NSDictionary *)owners epoch:(NSUInteger)streamEpoch;
- (NSArray *)desiredWatchURIs;
- (void)startWatch;
- (void)loadStates:(NSArray *)uris owner:(NSString *)owner;
@end

@interface SAPArtistDownloadSession (Scheduler)
- (void)pauseWork:(NSString *)reason;
- (void)next;
- (void)resumePausedOperationsExcept:(NSSet *)excluded;
- (void)pumpAdmissions;
- (void)scheduleNext;
- (void)scheduleWatchRenewal;
@end

@interface SAPArtistDownloadSession (Cancellation)
- (void)readStopURI:(NSString *)uri token:(NSString *)token completion:(void (^)(NSData *,NSString *))completion;
- (void)beginNativeStop:(NSString *)uri;
- (void)stopURI:(NSString *)uri;
- (void)stopURIs:(NSSet<NSString *> *)uris;
@end

@interface SAPArtistAlbumOperation (InternalMethods)
- (NSString *)uri;
- (BOOL)isCurrent;
- (void)readService:(NSString *)service method:(NSString *)method payload:(NSData *)payload completion:(void (^)(NSData *,NSString *))completion;
- (void)cancel;
- (void)finish:(NSString *)error;
- (void)armWorkDeadline;
- (void)evaluate;
- (BOOL)recoveryExclusive;
- (BOOL)recoveryEligible;
- (void)cancelRecoveryObservation;
- (void)haltRecovery:(NSString *)reason;
- (void)considerRecovery;
- (void)verifyRecoveryItems:(NSArray *)tracks offset:(NSUInteger)offset;
- (void)removeForRecovery;
- (void)confirmRecoveryZero;
- (void)preflight;
- (void)readMembership:(NSUInteger)attempt until:(double)until;
- (void)reconcile;
- (void)resume;
- (void)requestDownload;
- (void)submitDownload;
@end
