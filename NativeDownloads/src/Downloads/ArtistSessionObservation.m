#import "ArtistSessionPrivate.h"

@implementation SAPArtistDownloadSession (Observation)
- (void)cancelInitialReads {
    for(dispatch_block_t cancel in self.initialCancels.allValues)cancel();
    [self.initialCancels removeAllObjects];
    for(NSArray *uris in self.initialReadURILists.allValues)for(NSString *uri in uris) {
        NSUInteger count=[self.initialReadURICounts[uri]unsignedIntegerValue];
        if(count<=1)[self.initialReadURICounts removeObjectForKey:uri];else self.initialReadURICounts[uri]=@(count-1);
        [self noteCacheTouch:uri];
    }
    [self.initialReads removeAllObjects];
    [self.initialReadURILists removeAllObjects];[self.initialReadOwners removeAllObjects];
    [self trimInactiveStates];
}
- (void)cancelInitialReadsForOwner:(NSString *)owner {
    for(NSString *identifier in [self.initialReadOwners.allKeys copy])if([self.initialReadOwners[identifier]isEqual:owner]){
        dispatch_block_t cancel=self.initialCancels[identifier];[self finishInitialRead:identifier];if(cancel)cancel();
    }
}
- (void)finishInitialRead:(NSString *)identifier {
    NSArray *uris=self.initialReadURILists[identifier];if(!uris)return;
    [self.initialReads removeObject:identifier];[self.initialCancels removeObjectForKey:identifier];[self.initialReadOwners removeObjectForKey:identifier];
    for(NSString *uri in uris) {
        NSUInteger count=[self.initialReadURICounts[uri]unsignedIntegerValue];
        if(count<=1)[self.initialReadURICounts removeObjectForKey:uri];else self.initialReadURICounts[uri]=@(count-1);
        [self noteCacheTouch:uri];
    }
    [self.initialReadURILists removeObjectForKey:identifier];
}
- (void)cancelWatch {
    if(self.watchCancels.count)SAP_JOURNAL_ACTION(@"artist_observation_watch_cancelled",@{@"generation":@(self.watchEpoch),@"streams":@(self.watchCancels.count),@"reason":self.watchSuspended?@"observation_suspended":@"no_pending_observation_work",@"queued_preserved":@(self.queue.count)});
    self.watchEpoch++;for(dispatch_block_t cancel in self.watchCancels)cancel();[self.watchCancels removeAllObjects];self.watchURIs=nil;self.watchNativeURIs=nil;self.watchOwners=nil;
    self.watchPendingFirst=nil;
    if(self.watchDeadline){dispatch_source_cancel(self.watchDeadline);self.watchDeadline=nil;}
}
- (void)cancelRepair {
    self.repairEpoch++;self.repairing=NO;self.repairAwaitingStreams=NO;
    if(self.cancelRepairRead){self.cancelRepairRead();self.cancelRepairRead=nil;}
    if(self.repairDeadline){dispatch_source_cancel(self.repairDeadline);self.repairDeadline=nil;}
}
- (void)suspendObservation:(NSString *)reason {
    [self cancelRepair];self.watchSuspended=YES;self.observationPaused=YES;self.error=reason;
    // Preserve unsent selections and uncertain native reservations. Pausing
    // observation must not invalidate a pending mutation's completion epoch.
    for(SAPArtistAlbumOperation *operation in self.operations.allValues){
        operation.paused=YES;[operation cancelRecoveryObservation];operation.hasTrustedCounts=NO;operation.needsReadRepair=!operation.downloadSent;
        if(!operation.downloadSent)operation.readyForDownload=NO;
        operation.readEpoch++;if(operation.cancelRead){operation.cancelRead();operation.cancelRead=nil;}
        operation.retryEpoch++;if(operation.retry){dispatch_source_cancel(operation.retry);operation.retry=nil;}
        operation.workEpoch++;if(operation.workDeadline){dispatch_source_cancel(operation.workDeadline);operation.workDeadline=nil;}
        [self stateFor:operation.uri][@"error"]=reason;
    }
    for(NSDictionary *item in self.queue)[self stateFor:item[@"uri"]][@"error"]=reason;
    [self cancelInitialReads];[self cancelWatch];
    SAP_JOURNAL_ACTION(@"artist_observation_repair_exhausted",@{@"reason":reason,@"attempts":@(self.repairAttempts),@"episodes_without_native_progress":@(self.repairEpisodes),@"queued_preserved":@(self.queue.count),@"reserved_albums":@(self.operations.count),@"automatic_replay":@NO});[self publish];
}
- (void)resumeObservation {
    self.repairEpisodes=0;BOOL retained=self.observationPaused;self.observationPaused=NO;self.watchSuspended=NO;
    if(!retained)return;
    NSString *reason=self.error;self.error=nil;
    for(NSMutableDictionary *raw in self.states.allValues)if([raw[@"error"]isEqual:reason])[raw removeObjectForKey:@"error"];
    [self repairWatch:@"Refreshing retained album status."];
}
- (void)repairWatch:(NSString *)reason {
    if(self.watchSuspended)return;
    if(self.repairing){if(self.repairAwaitingStreams){self.repairAwaitingStreams=NO;[self tryRepairWatch];}return;}
    // A first stream response proves observation health, not native work.
    // Repeated healthy-first/error cycles share a finite instability budget.
    if(self.repairEpisodes>=2){SAP_JOURNAL_ACTION(@"artist_observation_repair_budget_exhausted",@{@"episodes_without_native_progress":@(self.repairEpisodes),@"max_episodes_without_native_progress":@2,@"queued_preserved":@(self.queue.count),@"automatic_replay":@NO});[self suspendObservation:@"Spotify status streams repeatedly failed without native download progress. Selected albums are retained; reopen the list to refresh."];return;}
    self.repairEpisodes++;
    self.repairing=YES;self.repairAwaitingStreams=NO;self.repairAttempts=0;self.error=reason;
    for(SAPArtistAlbumOperation *operation in self.operations.allValues)operation.hasTrustedCounts=NO;
    NSUInteger epoch=++self.repairEpoch;__weak typeof(self) weak=self;
    self.repairDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),SAPArtistRepairTimeoutSeconds,^{
        typeof(self) s=weak;if(!s || !s.repairing || s.repairEpoch!=epoch)return;
        s.repairDeadline=nil;[s suspendObservation:@"Spotify status observation could not be repaired in time. Selected albums are retained; reopen the list to refresh."];
    });
    SAP_JOURNAL_ACTION(@"artist_observation_repair_started",@{@"reason":reason,@"queued_preserved":@(self.queue.count),@"reserved_albums":@(self.operations.count),@"max_attempts":@2,@"episodes_without_native_progress":@(self.repairEpisodes),@"max_episodes_without_native_progress":@2,@"automatic_replay":@NO});
    [self tryRepairWatch];[self publish];
}
- (void)tryRepairWatch {
    if(!self.repairing)return;
    if(self.cancelRepairRead){self.cancelRepairRead();self.cancelRepairRead=nil;}
    if(self.repairAttempts>=2){[self suspendObservation:@"Spotify status observation could not be repaired. Selected albums are retained; reopen the list to refresh."];return;}
    self.repairAttempts++;NSUInteger epoch=self.repairEpoch,attempt=self.repairAttempts;
    NSMutableOrderedSet *requested=[NSMutableOrderedSet orderedSetWithArray:self.operations.allKeys];
    [requested addObjectsFromArray:self.stopOperations.allObjects];
    if(!requested.count)for(NSDictionary *item in self.queue){if(![self.readyItems[item[@"uri"]]count] || [item[@"reserved_batch_end"]boolValue])continue;[requested addObject:item[@"uri"]];if(requested.count==2)break;}
    if(!requested.count){NSArray *desired=[self desiredWatchURIs];if(desired.count)[requested addObject:desired.firstObject];}
    if(!requested.count){[self cancelRepair];[self cancelWatch];return;}
    NSArray *uris=requested.array;__weak typeof(self) weak=self;__block BOOL finished=NO;
    SAP_JOURNAL_ACTION(@"artist_observation_repair_attempt",@{@"attempt":@(attempt),@"albums":@(uris.count),@"queued_preserved":@(self.queue.count),@"automatic_replay":@NO});
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(offlineService,@"GetContexts",contextRequest(uris),^(NSData *data,NSString *error){
        typeof(self) s=weak;if(!s || finished || !s.repairing || s.repairEpoch!=epoch || s.repairAttempts!=attempt)return;finished=YES;s.cancelRepairRead=nil;
        NSArray *fields=SAPProtoFields(data);NSMutableSet *seen=[NSMutableSet set];
        if(fields && !error.length && !SAPProtoNumber(fields,2,0))for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(field[@"value"]),1));NSString *uri=SAPProtoString(info,1);if([uris containsObject:uri] && SAPProtoNumber(info,2,0)<=5)[seen addObject:uri];}
        if(seen.count!=uris.count){SAP_JOURNAL_ACTION(@"artist_observation_repair_read_failed",@{@"attempt":@(attempt),@"error":error?:@"missing_or_invalid_contexts"});[s tryRepairWatch];return;}
        // Keep admissions held while this exact snapshot fills the stream gap.
        [s apply:data progress:NO];if(!s.repairing || s.repairEpoch!=epoch)return;
        s.repairAwaitingStreams=YES;s.watchNeedsRenewal=YES;[s startWatch];
    });
    if(!finished && self.repairing && self.repairEpoch==epoch && cancel)self.cancelRepairRead=[^{finished=YES;cancel();} copy];
}
- (void)finishRepair {
    if(!self.repairing || !self.repairAwaitingStreams || self.watchPendingFirst.count)return;
    NSUInteger attempts=self.repairAttempts;[self cancelRepair];self.error=nil;
    SAP_JOURNAL_ACTION(@"artist_observation_repaired",@{@"attempts":@(attempts),@"queued_preserved":@(self.queue.count),@"reserved_albums":@(self.operations.count),@"automatic_replay":@NO});
    for(SAPArtistAlbumOperation *operation in self.operations.allValues){
        if(operation.paused || operation.commandPending)continue;
        if(operation.needsReadRepair){operation.needsReadRepair=NO;[operation preflight];}
        else if(operation.downloadSent)[operation reconcile];
    }
    [self next];[self pumpAdmissions];[self publish];
}
- (void)apply:(NSData *)data progress:(BOOL)progress {[self apply:data progress:progress live:NO];}
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live {[self apply:data progress:progress live:live owners:nil];}
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live owners:(NSDictionary *)owners {[self apply:data progress:progress live:live owners:owners epoch:0];}
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live owners:(NSDictionary *)owners epoch:(NSUInteger)streamEpoch {
    NSArray *envelope=SAPProtoFields(data);if(!envelope)return;
    if(!progress && SAPProtoNumber(envelope,2,0)) {self.error=@"Spotify could not read the album download states.";[self publish];return;}
    BOOL changed=NO;NSMutableSet *advanced=[NSMutableSet set];
    for(NSDictionary *field in envelope)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2) {
        NSArray *entry=SAPProtoFields(field[@"value"]),*info=progress?SAPProtoFields(SAPProtoData(entry,2)):SAPProtoFields(SAPProtoData(entry,1));
        NSString *uri=progress?SAPProtoString(entry,1):SAPProtoString(info,1);if(!uri || !info || !self.states[uri])continue;
        SAPArtistAlbumOperation *operation=self.operations[uri];
        if(operation.paused || ([self.queuedURIs containsObject:uri] && ![self.readyItems[uri]count]) || (owners && operation && owners[uri]!=operation))continue;
        // A stream opened before this AddDownload may still carry a pre-Add snapshot.
        if(streamEpoch && operation.downloadSent && operation.submittedWatchEpoch>=streamEpoch)continue;
        NSMutableDictionary *raw=[self stateFor:uri];NSDictionary *before=[raw copy];
        if(progress) {
            uint64_t done=SAPProtoNumber(info,3,0),bytes=SAPProtoNumber(info,4,0);
            BOOL gained=done>[raw[@"downloaded"]unsignedLongLongValue] || bytes>[raw[@"downloaded_bytes"]unsignedLongLongValue];
            raw[@"downloaded"]=@(done);raw[@"downloaded_bytes"]=@(bytes);raw[@"total_bytes"]=@(SAPProtoNumber(info,6,0));raw[@"total"]=@(SAPProtoNumber(info,5,0));raw[@"totals_state"]=@(SAPProtoNumber(info,11,0));
            raw[@"queued_tracks"]=@(SAPProtoNumber(info,1,0));raw[@"queued_bytes"]=@(SAPProtoNumber(info,2,0));
            raw[@"native_downloading"]=@(SAPProtoNumber(info,7,0)!=0);raw[@"percent"]=@(floatNumber(info,9));
            if(operation) {
                if(live && [raw[@"native_downloading"]boolValue])operation.sawNativeActive=YES;
                operation.hasTrustedCounts=[raw[@"totals_state"]unsignedIntegerValue]==2 && [raw[@"total"]unsignedLongLongValue]>0 && done<=[raw[@"total"]unsignedLongLongValue];
                if(gained) {
                    if(live && operation.downloadSent)self.repairEpisodes=0;
                    [operation armWorkDeadline];
                    for(SAPArtistAlbumOperation *peer in self.operations.allValues)if(peer!=operation && !peer.paused && !peer.stopped) {
                        NSDictionary *peerState=self.states[peer.uri];
                        BOOL heldPreparation=!peer.downloadSent && peer.readyForDownload && self.lastSubmittedOperation==operation;
                        BOOL waitingNative=peer.downloadSent && ![peerState[@"native_downloading"]boolValue];
                        if(heldPreparation || waitingNative)[peer armWorkDeadline];
                    }
                }
            }
        }else {
            uint64_t code=SAPProtoNumber(info,2,0);if(code>5)continue;
            if(code==3 && operation && !operation.downloadSent && SAPIsPlaylistURI(uri) && [operation.item[@"refresh_after_append"]boolValue])continue;
            if(operation && code==3 && ![before[@"native_state"]isEqual:@3])self.repairEpisodes=0;
            raw[@"native_state"]=@(code);raw[@"percent"]=@(floatNumber(info,3));
            if(code==3 || code==1 || code==0)raw[@"native_downloading"]=@NO;
            if(code==3 || code==2 || code==4 || code==5)[raw removeObjectForKey:@"native_cancelled"];
            BOOL forceDisable=[self.forcedOfflineStops containsObject:uri] || [raw[@"stop_removal_pending"]boolValue];
            if((code==3 && !forceDisable) || (code==1 && !forceDisable && ![self.queuedURIs containsObject:uri] && !(operation && !operation.downloadSent)) || (code==0 && [raw[@"stopping"]boolValue] && [self.stopSentURIs containsObject:uri])) {
                if(code==0)raw[@"stop_confirmed"]=@YES;
                raw[@"local_active"]=@NO;raw[@"stopping"]=@NO;raw[@"download_requested"]=@NO;
                raw[@"local_phase"]=code==1?@"failed":@"idle";
                if(code==1)raw[@"error"]=@"Spotify reported a download error. Tap to retry.";else[raw removeObjectForKey:@"error"];
                if(!operation){if(code==0){[raw removeObjectForKey:@"stop_removal_pending"];[raw removeObjectForKey:@"stop_confirmed"];}[self.stopOperations removeObject:uri];[self.stopTokens removeObjectForKey:uri];[self.stopSentURIs removeObject:uri];[self.forcedOfflineStops removeObject:uri];}
            }
            if(operation && live) {
                if(activeNative(raw))operation.sawNativeActive=YES;
                if(code==0 && operation.downloadSent && operation.sawNativeActive && !operation.stopped && !operation.recoveryOwnZero)raw[@"native_cancelled"]=@YES;
            }
        }
        if(![before isEqual:raw]) {
            changed=YES;SAP_JOURNAL_ACTION(@"artist_album_native_state",@{@"album_uri":uri,@"source":progress?@"native_progress":@"native_context",@"state":[self publicState:raw]});
        }
        if(operation)[advanced addObject:operation];
    }
    if(changed)[self publish];for(SAPArtistAlbumOperation *operation in advanced)[operation evaluate];[self pumpAdmissions];
}
- (NSArray *)desiredWatchURIs {
    if(self.watchSuspended)return @[];
    if(!self.observers.count && !self.operations.count && !self.queue.count && !self.stopOperations.count && !self.stopTokens.count)return @[];
    NSMutableOrderedSet *uris=[NSMutableOrderedSet orderedSet];BOOL readyQueued=NO;
    for(NSDictionary *item in self.queue)if([self.readyItems[item[@"uri"]]count]){readyQueued=YES;break;}
    BOOL needsEvents=self.operations.count>0 || readyQueued || self.stopOperations.count>0;
    for(NSString *uri in self.states){NSDictionary *raw=self.states[uri];if(activeNative(raw) || [raw[@"stopping"]boolValue] || ([raw[@"download_requested"]boolValue] && [raw[@"local_active"]boolValue])){needsEvents=YES;[uris addObject:uri];}}
    if(!needsEvents && !self.externalWatchRefCounts.count)return @[];
    if(self.operations.count || readyQueued || self.stopOperations.count)for(NSArray *list in self.observerURIs.allValues)[uris addObjectsFromArray:list];
    [uris addObjectsFromArray:self.externalWatchRefCounts.allKeys];
    [uris addObjectsFromArray:self.operations.allKeys];[uris addObjectsFromArray:self.stopOperations.allObjects];
    for(NSDictionary *item in self.queue)if(![self.readyItems[item[@"uri"]]count])[uris removeObject:item[@"uri"]];
    return [uris.array sortedArrayUsingSelector:@selector(compare:)];
}
- (void)startWatch {
    NSArray *uris=[self desiredWatchURIs];
    if(!uris.count){if(self.watchCancels.count)[self cancelWatch];if(self.repairing)[self cancelRepair];return;}
    NSMutableArray *ownedURIs=[NSMutableArray array];
    for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(owned.downloadSent && !owned.paused)[ownedURIs addObject:owned.uri];
    [ownedURIs sortUsingSelector:@selector(compare:)];
    if(!self.watchNeedsRenewal && [self.watchURIs isEqual:uris] && [self.watchOwners isEqualToDictionary:self.operations] && [self.watchNativeURIs isEqual:ownedURIs] && self.watchCancels.count) {
        if(self.operations.count && self.watchDeadline){dispatch_source_cancel(self.watchDeadline);self.watchDeadline=nil;}
        if(!self.operations.count && !self.queue.count && !self.watchDeadline){NSUInteger generation=self.watchEpoch;__weak typeof(self) weak=self;self.watchDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),900,^{typeof(self) s=weak;if(s && s.watchEpoch==generation)[s pauseWork:@"Live status updates stopped after 15 minutes. Reopen this list to refresh."];});}return;
    }
    // With many direct releases the owner set changes on every preparation and
    // submission. Batch those renewals; each stream already rejects owners it
    // was not opened for, and repairs or the very first streams start at once.
    if(!self.watchRenewalForced && !self.repairing && self.watchCancels.count) {
        BOOL direct=NO;for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(SAPArtistDirectURI(owned.uri)){direct=YES;break;}
        if(direct){[self scheduleWatchRenewal];return;}
    }
    // Queue replacement selection before releasing the old stream leases.
    // Changing the epoch first still rejects every previous callback, including
    // pre-Add snapshots when the URI/operation ownership set did not change.
    NSArray *oldCancels=[self.watchCancels copy];self.watchCancels=[NSMutableArray array];
    if(self.watchDeadline){dispatch_source_cancel(self.watchDeadline);self.watchDeadline=nil;}
    self.watchNeedsRenewal=NO;self.watchURIs=uris;self.watchNativeURIs=ownedURIs;NSUInteger epoch=++self.watchEpoch;NSDictionary *owners=[self.operations copy];self.watchOwners=owners;__weak typeof(self) weak=self;
    self.watchPendingFirst=[NSMutableSet set];
    // Submitted contexts use only the native page's default policy. Sending
    // a state-only context lease for the same URI can yield competing snapshots.
    NSMutableArray *passiveURIs=[uris mutableCopy];[passiveURIs removeObjectsInArray:ownedURIs];
    NSUInteger stateStreams=(passiveURIs.count+63)/64,regularStreams=stateStreams+(uris.count+63)/64;
    NSUInteger ownedStreams=(ownedURIs.count+63)/64;
    for(NSUInteger index=0;index<regularStreams+ownedStreams;index++)[self.watchPendingFirst addObject:@(index)];
    for(NSNumber *isProgress in @[@NO,@YES]) {
        BOOL progress=isProgress.boolValue;NSArray *watched=progress?uris:passiveURIs;
        for(NSUInteger offset=0;offset<watched.count;offset+=64) {
            NSArray *chunk=[watched subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)64,watched.count-offset))];
            NSNumber *identifier=@((progress?stateStreams:0)+offset/64);
            dispatch_block_t cancel=SAPSubscribeReadOnlyService(offlineService,progress?@"SubscribeContextsProgress":@"SubscribeContexts",progress?urisRequest(chunk,1):contextRequest(chunk),^(NSData *data,NSString *error){
                typeof(self) session=weak;if(!session || session.watchEpoch!=epoch)return;
                NSArray *fields=SAPProtoFields(data);
                if(error.length || !fields || (!progress && SAPProtoNumber(fields,2,0))){[session repairWatch:error.length?error:@"Spotify sent an invalid album status stream response."];return;}
                [session.watchPendingFirst removeObject:identifier];[session apply:data progress:progress live:YES owners:owners epoch:epoch];
                if(session.watchEpoch==epoch)[session finishRepair];
            });if(cancel)[self.watchCancels addObject:cancel];
        }
    }
    for(NSUInteger offset=0;offset<ownedURIs.count;offset+=64){
        NSArray *ownedChunk=[ownedURIs subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)64,ownedURIs.count-offset))];
        NSNumber *identifier=@(regularStreams+offset/64);
        // Match the native album page's default-policy observation, only for
        // submitted contexts. Passive catalog entries remain state-only.
        dispatch_block_t cancel=SAPSubscribeReadOnlyService(offlineService,@"SubscribeContexts",urisRequest(ownedChunk,3),^(NSData *data,NSString *error){
            typeof(self) s=weak;if(!s || s.watchEpoch!=epoch)return;
            NSArray *fields=SAPProtoFields(data);
            if(error.length || !fields || SAPProtoNumber(fields,2,0)){[s repairWatch:error.length?error:@"Spotify sent an invalid active context response."];return;}
            [s.watchPendingFirst removeObject:identifier];[s apply:data progress:NO live:YES owners:owners epoch:epoch];if(s.watchEpoch==epoch)[s finishRepair];
        });if(cancel)[self.watchCancels addObject:cancel];
        SAP_JOURNAL_ACTION(@"artist_native_context_observation",@{@"uris":ownedChunk,@"policy":@"native_default",@"owned_contexts":@(ownedURIs.count),@"mutations_sent":@0});
    }
    SAP_JOURNAL_ACTION(@"artist_observation_watch_replaced",@{@"generation":@(epoch),@"previous_streams":@(oldCancels.count),@"replacement_streams":@(self.watchCancels.count),@"reason":self.repairing?@"bounded_repair":@"ownership_or_submission_changed",@"selection_queued_before_cancel":@YES});
    for(dispatch_block_t cancel in oldCancels)cancel();
    if(!self.operations.count && !self.queue.count)self.watchDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),900,^{
        typeof(self) s=weak;if(!s || s.watchEpoch!=epoch)return;
        [s pauseWork:@"Live status updates stopped after 15 minutes. Reopen this list to refresh."];
    });
}
- (void)loadStates:(NSArray *)uris owner:(NSString *)owner {
    // Those contexts already own a stream/preflight; modal reads cannot add evidence.
    NSMutableArray *passive=[NSMutableArray array];for(NSString *uri in uris)if(!self.operations[uri] && ![self.queuedURIs containsObject:uri])[passive addObject:uri];uris=passive;
    __weak typeof(self) weak=self;
    for(NSUInteger offset=0;offset<uris.count;offset+=64) {
        NSArray *chunk=[uris subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)64,uris.count-offset))];
        for(NSNumber *isProgress in @[@NO,@YES]) {
            BOOL progress=isProgress.boolValue;NSString *identifier=NSUUID.UUID.UUIDString;[self.initialReads addObject:identifier];
            self.initialReadURILists[identifier]=chunk;if(owner)self.initialReadOwners[identifier]=owner;
            for(NSString *uri in chunk)self.initialReadURICounts[uri]=@([self.initialReadURICounts[uri]unsignedIntegerValue]+1);
            dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(offlineService,progress?@"GetContextsProgress":@"GetContexts",progress?urisRequest(chunk,1):contextRequest(chunk),^(NSData *data,NSString *error){
                typeof(self) s=weak;if(!s || ![s.initialReads containsObject:identifier])return;[s finishInitialRead:identifier];
                if(error.length){s.error=error;[s publish];}else {
                    // Initial modal snapshots can predate an enqueued mutation.
                    // Owned work is updated only by its current live stream or
                    // explicit epoch-checked reconciliation, never this read.
                    NSMutableData *filtered=[NSMutableData data];
                    for(NSDictionary *field in SAPProtoFields(data)) {
                        if([field[@"number"]unsignedIntValue]!=1 || [field[@"wire"]unsignedIntValue]!=2){[filtered appendData:field[@"raw"]];continue;}
                        NSArray *entry=SAPProtoFields(field[@"value"]),*info=progress?nil:SAPProtoFields(SAPProtoData(entry,1));
                        NSString *uri=progress?SAPProtoString(entry,1):SAPProtoString(info,1);if(!uri)continue;NSDictionary *raw=s.states[uri];
                        if([s.queuedURIs containsObject:uri] || s.operations[uri]!=nil || [raw[@"local_active"]boolValue] || [raw[@"stopping"]boolValue] || [raw[@"download_requested"]boolValue])continue;
                        [filtered appendData:field[@"raw"]];
                    }
                    if(data && SAPProtoFields(data))[s apply:filtered progress:progress];
                }
                [s startWatch];
            });if([self.initialReads containsObject:identifier] && cancel)self.initialCancels[identifier]=cancel;
        }
    }
}
@end
