#import "ArtistSessionPrivate.h"

#ifdef SAP_TESTING
double SAPArtistWorkTimeoutSeconds=900;
double SAPArtistRepairTimeoutSeconds=30;
double SAPArtistRecoverySettleSeconds=2;
void SAPArtistSessionSetRecoverySettleForTesting(double seconds){SAPArtistRecoverySettleSeconds=seconds;}
void SAPArtistSessionSetWorkTimeoutForTesting(double seconds){SAPArtistWorkTimeoutSeconds=seconds;}
void SAPArtistSessionSetRepairTimeoutForTesting(double seconds){SAPArtistRepairTimeoutSeconds=seconds;}
BOOL SAPArtistDirectAlbumSubmission=YES;
void SAPArtistSessionSetDirectAlbumSubmissionForTesting(BOOL enabled){SAPArtistDirectAlbumSubmission=enabled;}
#else
const double SAPArtistWorkTimeoutSeconds=900;
const double SAPArtistRepairTimeoutSeconds=30;
const double SAPArtistRecoverySettleSeconds=2;
#endif
static SAPArtistDownloadSession *session;
@implementation SAPArtistDownloadSession
- (instancetype)init {
    if((self=[super init])) {_leaseOrders=[NSMutableDictionary dictionary];_batchTickets=[NSMutableDictionary dictionary];_queueOrders=[NSMutableDictionary dictionary];_externalWatchRefCounts=[NSMutableDictionary dictionary];_readyItems=[NSMutableDictionary dictionary];_stoppedItems=[NSMutableDictionary dictionary];_stoppedOrder=[NSMutableOrderedSet orderedSet];_states=[NSMutableDictionary dictionary];_observers=[NSMutableDictionary dictionary];_observerURIs=[NSMutableDictionary dictionary];_observedURIRefCounts=[NSMutableDictionary dictionary];_initialReadURICounts=[NSMutableDictionary dictionary];_initialReadURILists=[NSMutableDictionary dictionary];_initialReadOwners=[NSMutableDictionary dictionary];_observerArtists=[NSMutableDictionary dictionary];_contextOwners=[NSMutableDictionary dictionary];_artistContexts=[NSMutableDictionary dictionary];_abandonedURIs=[NSMutableSet set];_forcedOfflineStops=[NSMutableSet set];_pendingCacheTouches=[NSMutableOrderedSet orderedSet];_inactiveStateLRU=[NSMutableArray array];_queue=[NSMutableArray array];_watchCancels=[NSMutableArray array];_initialCancels=[NSMutableDictionary dictionary];_initialReads=[NSMutableSet set];_stopOperations=[NSMutableSet set];_stopSentURIs=[NSMutableSet set];_stopTokens=[NSMutableDictionary dictionary];_queuedURIs=[NSMutableSet set];_operations=[NSMutableDictionary dictionary];_stopReadCancels=[NSMutableDictionary dictionary];}return self;
}
@end

static SAPArtistDownloadSession *shared(void){if(!session)session=[SAPArtistDownloadSession new];return session;}
@interface SAPArtistSessionObservation ()
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSMutableOrderedSet *uris,*externalURIs;
@property(nonatomic) BOOL detached;
@end
@implementation SAPArtistSessionObservation
- (void)extendReleases:(NSArray *)releases {
    NSCAssert(NSThread.isMainThread,@"Artist observation belongs to main");if(self.detached)return;SAPArtistDownloadSession *s=shared();NSMutableArray *added=[NSMutableArray array];
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];
        if(validContextURI(uri) && [release[@"follow_external_changes"]boolValue] && ![self.externalURIs containsObject:uri] && (self.uris.count<4096 || [self.uris containsObject:uri])){[self.externalURIs addObject:uri];s.externalWatchRefCounts[uri]=@([s.externalWatchRefCounts[uri]unsignedIntegerValue]+1);}
        if(validContextURI(uri) && ![self.uris containsObject:uri] && self.uris.count<4096){[self.uris addObject:uri];[added addObject:uri];s.observedURIRefCounts[uri]=@([s.observedURIRefCounts[uri]unsignedIntegerValue]+1);[s stateFor:uri];}}
    if(!added.count){[s startWatch];return;}s.observerURIs[self.token]=self.uris.array;[s resumeObservation];[s resumePausedOperationsExcept:nil];[s publish];[s loadStates:added owner:self.token];
}
- (void)refresh {
    NSCAssert(NSThread.isMainThread,@"Artist refresh belongs to main");if(self.detached)return;SAPArtistDownloadSession *s=shared();[s cancelInitialReadsForOwner:self.token];[s resumeObservation];[s resumePausedOperationsExcept:nil];[s publish];[s loadStates:self.uris.array owner:self.token];
}
- (void)invalidate {
    NSCAssert(NSThread.isMainThread,@"Artist UI detaches on main");if(self.detached)return;self.detached=YES;SAPArtistDownloadSession *s=shared();[s.observers removeObjectForKey:self.token];[s.observerURIs removeObjectForKey:self.token];[s.observerArtists removeObjectForKey:self.token];[s cancelInitialReadsForOwner:self.token];
    for(NSString *uri in self.uris){NSUInteger count=[s.observedURIRefCounts[uri]unsignedIntegerValue];if(count<=1)[s.observedURIRefCounts removeObjectForKey:uri];else s.observedURIRefCounts[uri]=@(count-1);[s noteCacheTouch:uri];}
    for(NSString *uri in self.externalURIs){NSUInteger count=[s.externalWatchRefCounts[uri]unsignedIntegerValue];if(count<=1)[s.externalWatchRefCounts removeObjectForKey:uri];else s.externalWatchRefCounts[uri]=@(count-1);}
    [self.externalURIs removeAllObjects];[self.uris removeAllObjects];[s trimInactiveStates];[s startWatch];
}
@end
static SAPArtistSessionObservation *observeSession(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){
    NSCAssert(NSThread.isMainThread,@"Artist UI observation belongs to main");SAPArtistDownloadSession *s=shared();SAPArtistSessionObservation *observation=[SAPArtistSessionObservation new];observation.token=NSUUID.UUID.UUIDString;observation.uris=[NSMutableOrderedSet orderedSet];observation.externalURIs=[NSMutableOrderedSet orderedSet];
    if(completion)s.observers[observation.token]=[completion copy];s.observerURIs[observation.token]=@[];if(artist)s.observerArtists[observation.token]=artist;
    [observation extendReleases:releases];if(!observation.uris.count)[s publish];return observation;
}
SAPArtistSessionObservation *SAPObserveArtistSession(NSArray *releases,void (^completion)(NSDictionary *)){return observeSession(nil,releases,completion);}
SAPArtistSessionObservation *SAPObserveArtistSessionForArtist(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){return observeSession(artist,releases,completion);}
void SAPClosePlaylistDownloadFeed(NSString *uri){
    NSCAssert(NSThread.isMainThread,@"Playlist feeds belong to main");SAPArtistAlbumOperation *op=shared().operations[uri];if(op && SAPIsPlaylistURI(uri)){op.playlistFeedOpen=NO;[op evaluate];[shared() publish];}
}
void SAPForgetPlaylistDownloadIntent(NSString *uri){
    if(!SAPIsPlaylistURI(uri))return;SAPArtistDownloadSession *s=shared();if(!s.operations[uri]){[s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];}[s publish];
}
static BOOL cancelOwners(SAPArtistDownloadSession *s,NSSet *keys,NSString *artist){
    if(!keys.count)return NO;NSMutableSet *cancel=[NSMutableSet set];for(id key in keys)[s releaseTicket:key];
    for(id key in keys){for(NSString *uri in [s.artistContexts[key]copy]){
        NSMutableDictionary *ready=s.readyItems[uri];[ready removeObjectForKey:key];
        [s.leaseOrders[uri]removeObjectForKey:key];[s refreshQueuedURI:uri];
        NSMutableSet *owners=s.contextOwners[uri];[owners removeObject:key];if(!owners.count && !ready[NSNull.null]){[s.contextOwners removeObjectForKey:uri];[cancel addObject:uri];[s.abandonedURIs addObject:uri];s.operations[uri].discardStoppedIntent=YES;[s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];}}[s.artistContexts removeObjectForKey:key];}
    if(cancel.count){s.watchSuspended=NO;[s stopURIs:cancel];}
    BOOL pending=NO;for(NSString *uri in cancel){BOOL live=s.operations[uri]!=nil || s.stopTokens[uri]!=nil;pending|=live;if(!live)[s.abandonedURIs removeObject:uri];}
    SAP_JOURNAL_ACTION(@"artist_cancel_requested",@{@"artist_uri":artist?:@"",@"exclusive_contexts":@(cancel.count),@"owner_count":@(keys.count),@"automatic_replay":@NO});[s publish];[s next];[s pumpAdmissions];return pending;
}
void SAPCancelArtistDownloadSession(NSString *artist){
    NSCAssert(NSThread.isMainThread,@"Artist cancellation belongs to main");if(!artist.length)return;SAPArtistDownloadSession *s=shared();NSMutableSet *keys=[NSMutableSet set];for(id key in s.artistContexts)if([ownerArtist(key)isEqual:artist])[keys addObject:key];for(id key in s.batchTickets)if([ownerArtist(key)isEqual:artist])[keys addObject:key];cancelOwners(s,keys,artist);
}
BOOL SAPCancelArtistDownloadOwner(NSString *artist,NSString *token){
    NSCAssert(NSThread.isMainThread,@"Task cancellation belongs to main");if(!artist.length || !token.length)return NO;id key=ownerKey(artist,token);if(![shared().artistContexts[key]count] && !shared().batchTickets[key])return NO;return cancelOwners(shared(),[NSSet setWithObject:key],artist);
}
void SAPStopArtistDownloadSessionReleasesForArtist(NSString *artist,NSArray *releases){
    NSCAssert(NSThread.isMainThread,@"Artist Stop belongs to main");if(!artist.length)return;SAPArtistDownloadSession *s=shared();NSMutableSet *exclusive=[NSMutableSet set];
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];NSMutableSet *owners=s.contextOwners[uri];if(![owners containsObject:artist])continue;
        if(owners.count>1){[owners removeObject:artist];NSMutableDictionary *ready=s.readyItems[uri];[ready removeObjectForKey:artist];[s.leaseOrders[uri]removeObjectForKey:artist];[s refreshQueuedURI:uri];NSMutableSet *contexts=s.artistContexts[artist];[contexts removeObject:uri];if(!contexts.count)[s.artistContexts removeObjectForKey:artist];}
        else[exclusive addObject:uri];
    }
    if(exclusive.count)[s stopURIs:exclusive];else[s publish];
}
BOOL SAPContinueArtistDownloads(NSString *artist,NSArray *releases,NSString **error){
    NSMutableArray *owned=[NSMutableArray array];for(NSDictionary *release in releases)if([shared().contextOwners[release[@"uri"]]containsObject:artist])[owned addObject:release];return SAPContinueArtistDownloadSessionReleases(owned,error);
}
dispatch_block_t SAPObserveArtistDownloadSession(NSArray *releases,void (^completion)(NSDictionary *)){
    SAPArtistSessionObservation *observation=SAPObserveArtistSession(releases,completion);return ^{[observation invalidate];};
}
BOOL SAPReserveArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Artist reservations belong to main");SAPArtistDownloadSession *s=shared();
    if(![releases isKindOfClass:NSArray.class] || !releases.count || releases.count>4096){if(error)*error=@"No valid releases were selected.";return NO;}
    for(NSDictionary *release in releases)if(![release isKindOfClass:NSDictionary.class] || !validContextURI(release[@"uri"]) || ![release[@"artist_uri"]isKindOfClass:NSString.class] || ![release[@"artist_uri"]length] || ![release[@"owner_token"]isKindOfClass:NSString.class] || ![release[@"owner_token"]length]){if(error)*error=@"Invalid download reservation identity.";return NO;}
    for(NSDictionary *release in releases)if([s.abandonedURIs containsObject:release[@"uri"]]){if(error)*error=@"Spotify is still confirming the previous cancellation. Try again when it finishes.";return NO;}
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];NSUInteger rank=[s reserveTicket:releaseOwner(release)];NSDictionary *order=@{@"rank":@(rank),@"ordinal":@([s ticketOrdinal:releaseOwner(release) uri:uri])};[s recordLease:releaseOwner(release) uri:uri order:order];[s registerOwner:releaseOwner(release) uri:uri];
        if([s.queuedURIs containsObject:uri]){[s refreshQueuedURI:uri];continue;}if(s.operations[uri])continue;[s.readyItems removeObjectForKey:uri];
        NSMutableDictionary *raw=[s stateFor:uri];raw[@"local_active"]=@YES;raw[@"local_phase"]=@"queued";raw[@"reserved"]=@YES;
        for(NSString *key in @[@"native_state",@"total",@"downloaded",@"percent",@"totals_state",@"native_cancelled",@"error"])[raw removeObjectForKey:key];
        [s enqueue:release order:order];[s.queuedURIs addObject:uri];
    }
    [s publish];return YES;
}
BOOL SAPAppendArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases,NSString **error) {
    NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");SAPArtistDownloadSession *s=shared();
    if(![releases isKindOfClass:NSArray.class] || !releases.count || releases.count>4096){if(error)*error=@"No valid releases were selected.";return NO;}
    for(NSDictionary *release in releases)if(![release isKindOfClass:NSDictionary.class] || !validContextURI(release[@"uri"])){if(error)*error=@"Invalid download context identity.";return NO;}
    for(NSDictionary *release in releases)if([s.abandonedURIs containsObject:release[@"uri"]]){if(error)*error=@"Spotify is still confirming the previous cancellation. Try again when it finishes.";return NO;}
    NSUInteger appendRank=++s.nextQueueRank,appendOrdinal=0;
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];NSString *artist=[release[@"artist_uri"]isKindOfClass:NSString.class]?release[@"artist_uri"]:nil;NSString *token=[release[@"owner_token"]isKindOfClass:NSString.class]?release[@"owner_token"]:nil;[s registerOwner:artist.length?ownerKey(artist,token):nil uri:uri];
        NSMutableDictionary *ready=s.readyItems[uri];if(!ready)s.readyItems[uri]=ready=[NSMutableDictionary dictionary];ready[releaseOwner(release)]=[release copy];NSDictionary *ticket=s.batchTickets[releaseOwner(release)];NSDictionary *order=@{@"rank":ticket?ticket[@"rank"]:@(appendRank),@"ordinal":ticket?@([s ticketOrdinal:releaseOwner(release) uri:uri]):@(appendOrdinal)};appendOrdinal++;[s recordLease:releaseOwner(release) uri:uri order:order];
        if([s.queuedURIs containsObject:uri])[s refreshQueuedURI:uri];
        if([release[@"incremental_playlist"]boolValue] && s.operations[uri])s.operations[uri].playlistFeedOpen=YES;NSMutableDictionary *raw=[s stateFor:uri];raw[@"reserved"]=@NO;[raw removeObjectForKey:@"native_cancelled"];
        if(SAPIsPlaylistURI(uri) && [release[@"refresh_after_append"]boolValue] && [raw[@"native_state"]isEqual:@3] && !s.operations[uri] && ![s.queuedURIs containsObject:uri]){
            // A mutable playlist's old completed snapshot predates our append.
            // Discard that cache entry; do not reinterpret it as new evidence.
            for(NSString *key in @[@"native_state",@"total",@"downloaded",@"downloaded_bytes",@"percent",@"totals_state"])[raw removeObjectForKey:key];
        }
        if([s.queuedURIs containsObject:uri] || s.operations[uri]!=nil || [raw[@"local_active"]boolValue] || activeNative(raw) || [raw[@"stopping"]boolValue])continue;
        // An inactive cached context is not proof for a new user request.
        // Preflight reads Spotify again and completes without Add when still full.
        if([raw[@"native_state"]isEqual:@3])for(NSString *key in @[@"native_state",@"total",@"downloaded",@"percent",@"totals_state"])[raw removeObjectForKey:key];
        [s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];
        raw[@"local_active"]=@YES;raw[@"local_phase"]=@"queued";[raw removeObjectForKey:@"error"];[s enqueue:release order:order];[s.queuedURIs addObject:uri];
        SAP_JOURNAL_ACTION(@"artist_album_queued",@{@"album_uri":uri,@"position":@(s.queue.count)});
    }
    [s resumeObservation];if(!s.repairing)s.error=nil;[s resumePausedOperationsExcept:nil];[s next];[s publish];return YES;
}
BOOL SAPContinueArtistDownloadSessionReleases(NSArray *releases,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Continue belongs to main");SAPArtistDownloadSession *s=shared();NSMutableSet *scope=[NSMutableSet set];for(NSDictionary *release in releases)if(SAPIsAlbumURI(release[@"uri"]))[scope addObject:release[@"uri"]];
    NSMutableArray *pending=[NSMutableArray array];for(NSString *uri in [s.stoppedOrder.array copy])if([scope containsObject:uri] && !s.operations[uri] && ![s.queuedURIs containsObject:uri] && ![s.stopOperations containsObject:uri] && ![[s publicState:s.states[uri]][@"active"]boolValue])[pending addObject:s.stoppedItems[uri]];
    if(!pending.count)return YES;
    SAP_JOURNAL_ACTION(@"artist_continue_requested",@{@"release_count":@(pending.count),@"fresh_native_preflight":@YES});
    return SAPAppendArtistDownloadSessionReleases(pending,error);
}
void SAPStopArtistDownloadSessionRelease(NSString *uri){NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");if(!validContextURI(uri))return;SAPArtistDownloadSession *s=shared();s.watchSuspended=NO;[s stopURIs:[NSSet setWithObject:uri]];}
void SAPStopArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases){
    NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");NSMutableSet *uris=[NSMutableSet set];
    for(NSDictionary *release in releases)if(validContextURI(release[@"uri"]))[uris addObject:release[@"uri"]];SAPArtistDownloadSession *s=shared();s.watchSuspended=NO;[s stopURIs:uris];
}
void SAPStopArtistDownloadSession(void){for(id owner in [shared().batchTickets.allKeys copy])[shared() releaseTicket:owner];NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");SAPArtistDownloadSession *s=shared();s.watchSuspended=NO;[s stopURIs:[NSSet setWithArray:s.states.allKeys]];}
