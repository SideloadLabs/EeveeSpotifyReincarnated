#import "ArtistSessionPrivate.h"

@implementation SAPArtistDownloadSession (Scheduler)
- (void)pauseWork:(NSString *)reason {
    [self cancelRepair];
    self.observationPaused=NO;
    self.watchSuspended=YES;self.error=reason;self.prepareEpoch++;self.preparing=NO;
    NSUInteger unsent=self.queue.count;NSMutableArray *items=[self.queue mutableCopy];
    for(SAPArtistAlbumOperation *operation in self.operations.allValues){
        [items addObject:operation.item];[operation cancel];
        // A cancelled callback cannot prove that its native mutation failed.
        if(operation.downloadSent){operation.paused=YES;operation.commandPending=NO;operation.hasTrustedCounts=NO;}
        else [self.operations removeObjectForKey:operation.uri];
    }
    for(dispatch_block_t cancel in self.stopReadCancels.allValues)cancel();[self.stopReadCancels removeAllObjects];
    for(NSString *uri in self.stopTokens.allKeys){NSMutableDictionary *raw=[self stateFor:uri];raw[@"stopping"]=@NO;raw[@"error"]=reason;}
    [self.stopTokens removeAllObjects];[self.stopOperations removeAllObjects];
    // Remember sent removals so a later explicit Stop cannot replay them.
    for(NSDictionary *item in items){if([item[@"reserved_batch_end"]boolValue])continue;NSMutableDictionary *raw=[self stateFor:item[@"uri"]];raw[@"native_downloading"]=@NO;raw[@"local_active"]=@NO;raw[@"local_phase"]=@"failed";raw[@"error"]=reason;}
    [self.queue removeAllObjects];[self.queueOrders removeAllObjects];[self.queuedURIs removeAllObjects];
    [self cancelInitialReads];[self cancelWatch];
    SAP_JOURNAL_ACTION(@"artist_album_queue_paused",@{@"reason":reason,@"unsent_albums":@(unsent),@"affected_albums":@(items.count),@"reserved_albums":@(self.operations.count),@"automatic_replay":@NO});[self publish];
}
- (void)next {
    if(self.filling || self.stopBatchDepth || self.watchSuspended || self.repairing || self.preparing)return;
    // Albums: up to four releases prepare at once and each is sent when ready.
    // Playlists: preparation may overlap, but every submitted or uncertain
    // playlist keeps one of the two ownership slots until its outcome is definite.
    self.filling=YES;
    while(self.queue.count && !self.watchSuspended && !self.repairing && !self.stopBatchDepth) {
        NSDictionary *first=self.queue.firstObject;
        // A selected future release owns its FIFO position, without a native slot.
        if([first[@"reserved_batch_end"]boolValue] || ![self.readyItems[first[@"uri"]]count])break;
        if(SAPArtistDirectURI(first[@"uri"])) {
            // Only preparation is bounded; sent releases wait in Spotify's queue.
            NSUInteger preparing=0;for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(!owned.downloadSent)preparing++;
            if(preparing>=SAPArtistPreparationWindow || self.operations.count>=SAPArtistSubmittedLimit)break;
        }else if(self.operations.count>=2)break;
        SAPArtistAlbumOperation *operation=[SAPArtistAlbumOperation new];operation.session=self;operation.item=first;operation.playlistFeedOpen=[operation.item[@"incremental_playlist"]boolValue];operation.token=NSUUID.UUID.UUIDString;operation.sequence=++self.nextSequence;
        [self.queue removeObjectAtIndex:0];[self.queueOrders removeObjectForKey:operation.uri];[self.queuedURIs removeObject:operation.uri];self.operations[operation.uri]=operation;
        [self stateFor:operation.uri][@"local_phase"]=@"preparing";[operation armWorkDeadline];[self publish];
        if(!self.prepared) {
            self.preparing=YES;NSUInteger generation=++self.prepareEpoch;__weak typeof(self) weak=self;
            SAPPrepareNativeOffline(^BOOL{typeof(self) s=weak;return s && s.prepareEpoch==generation;},^(BOOL ready,NSString *reason){
                typeof(self) s=weak;if(!s || s.prepareEpoch!=generation)return;s.preparing=NO;
                if(!ready){NSString *message=reason?:@"The native download manager is not ready.";if(s.repairing || s.observationPaused)[s suspendObservation:message];else[s pauseWork:message];return;}
                s.prepared=YES;for(SAPArtistAlbumOperation *owned in s.operations.allValues)[owned preflight];
                dispatch_async(dispatch_get_main_queue(),^{[s next];});
            });break;
        }
        [operation preflight];
    }
    self.filling=NO;
    if(!self.operations.count && !self.queue.count)[self publish];
}
- (void)resumePausedOperationsExcept:(NSSet *)excluded {
    for(SAPArtistAlbumOperation *operation in self.operations.allValues)if(operation.paused && ![excluded containsObject:operation.uri])[operation resume];
}
- (void)pumpAdmissions {
    if(self.admitting || self.stopBatchDepth || self.watchSuspended || self.repairing)return;
    // A recovery owns the original FIFO reservation through its deliberate zero.
    for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(owned.recoveryStage.length)return;
    self.admitting=YES;
    // Albums are sent as soon as they are prepared. Ordered contexts keep the
    // pair/near-tail admission and uncertain outcomes still reserve slots.
    NSArray *ordered=[self.operations.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPArtistAlbumOperation *a,SAPArtistAlbumOperation *b){return a.sequence<b.sequence?NSOrderedAscending:a.sequence>b.sequence?NSOrderedDescending:NSOrderedSame;}];
    BOOL orderedHeld=NO;
    for(SAPArtistAlbumOperation *operation in ordered) {
        if(![operation isCurrent] || operation.paused || operation.downloadSent || !operation.readyForDownload)continue;
        if(SAPArtistDirectURI(operation.uri)) {
            // Same as tapping download in Spotify: no predecessor gate.
            operation.releaseGate=@{@"reason":@"direct"};[operation submitDownload];continue;
        }
        if(orderedHeld)continue;
        BOOL earlierUnsent=NO;for(SAPArtistAlbumOperation *earlier in self.operations.allValues)if(earlier.sequence<operation.sequence && !earlier.downloadSent){earlierUnsent=YES;break;}
        if(earlierUnsent){orderedHeld=YES;continue;}
        SAPArtistAlbumOperation *predecessor=nil;
        // A completed newer operation must not hide an older native waiter.
        for(SAPArtistAlbumOperation *earlier in ordered)if(earlier.sequence<operation.sequence && earlier.downloadSent && [earlier isCurrent]){predecessor=earlier;break;}
        if(!predecessor)predecessor=self.lastSubmittedOperation;
        NSString *reason=@"first_album";NSMutableDictionary *facts=[NSMutableDictionary dictionary];
        if(predecessor && predecessor!=operation) {
            facts[@"predecessor_uri"]=predecessor.uri;facts[@"predecessor_token"]=predecessor.token;
            if([predecessor isCurrent]) {
                NSDictionary *raw=self.states[predecessor.uri];uint64_t total=[raw[@"total"]unsignedLongLongValue],done=[raw[@"downloaded"]unsignedLongLongValue];
                BOOL singlePair=[predecessor.item[@"track_count_verified"]boolValue] && [predecessor.item[@"verified_track_count"]unsignedIntegerValue]==1 && [operation.item[@"track_count_verified"]boolValue] && [operation.item[@"verified_track_count"]unsignedIntegerValue]==1;
                if(predecessor.paused){orderedHeld=YES;continue;}
                if(predecessor.singlePairOccupied){orderedHeld=YES;continue;}
                if(singlePair){
                    // Submit a real pair, then finish that pair before replacing
                    // its faster member. Otherwise newer contexts can repeatedly
                    // take priority over the first track still waiting in Spotify.
                    predecessor.singlePairOccupied=YES;operation.singlePairOccupied=YES;
                    reason=@"verified_single_pair";facts[@"predecessor_track_count"]=@1;facts[@"selected_track_count"]=@1;
                }
                else {
                    if(!predecessor.hasTrustedCounts || !total || done>total || total-done>1){orderedHeld=YES;continue;}
                    reason=@"one_track_remaining";facts[@"total_tracks"]=@(total);facts[@"downloaded_tracks"]=@(done);facts[@"remaining_tracks"]=@(total-done);
                }
            }else reason=@"predecessor_terminal";
        }
        facts[@"reason"]=reason;operation.releaseGate=facts;[operation submitDownload];
    }
    self.admitting=NO;
}
- (void)scheduleNext {
    if(self.nextScheduled)return;self.nextScheduled=YES;__weak typeof(self) weak=self;
    dispatch_async(dispatch_get_main_queue(),^{typeof(self) s=weak;if(!s)return;s.nextScheduled=NO;[s next];[s pumpAdmissions];});
}
- (void)scheduleWatchRenewal {
    // Submissions arrive one by one as preparation completes. Renew the live
    // streams at most every 0.2 s instead of once per release; older streams
    // keep updating other releases and ignore only the newly sent attempts.
    self.watchNeedsRenewal=YES;
    if(self.watchRenewalScheduled)return;self.watchRenewalScheduled=YES;__weak typeof(self) weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{typeof(self) s=weak;if(!s)return;s.watchRenewalScheduled=NO;s.watchRenewalForced=YES;[s startWatch];s.watchRenewalForced=NO;});
}
@end
