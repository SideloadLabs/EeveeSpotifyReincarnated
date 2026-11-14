#import "ArtistSessionPrivate.h"

@implementation SAPArtistAlbumOperation
- (NSString *)uri {return self.item[@"uri"];}
- (BOOL)isCurrent {return self.session.operations[self.uri]==self;}
- (void)readService:(NSString *)service method:(NSString *)method payload:(NSData *)payload completion:(void (^)(NSData *,NSString *))completion {
    if(self.cancelRead){self.cancelRead();self.cancelRead=nil;}
    NSUInteger generation=++self.readEpoch;__block BOOL finished=NO;
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(service,method,payload,^(NSData *data,NSString *error){
        if(finished || ![self isCurrent] || self.readEpoch!=generation)return;finished=YES;self.cancelRead=nil;completion(data,error);
    });
    if(!finished && [self isCurrent] && self.readEpoch==generation && cancel)self.cancelRead=[^{finished=YES;cancel();} copy];
}
- (void)cancel {
    [self cancelRecoveryObservation];
    self.epoch++;self.retryEpoch++;self.workEpoch++;self.readEpoch++;
    if(self.cancelRead){self.cancelRead();self.cancelRead=nil;}
    if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}
    if(self.workDeadline){dispatch_source_cancel(self.workDeadline);self.workDeadline=nil;}
}
- (void)finish:(NSString *)error {
    if(![self isCurrent])return;SAPArtistDownloadSession *s=self.session;NSString *uri=self.uri;NSMutableDictionary *raw=[s stateFor:uri];
    [s.stopOperations removeObject:uri];[s.stopTokens removeObjectForKey:uri];[s.stopSentURIs removeObject:uri];
    dispatch_block_t cancel=s.stopReadCancels[uri];if(cancel)cancel();[s.stopReadCancels removeObjectForKey:uri];
    [raw removeObjectForKey:@"stop_confirmed"];[raw removeObjectForKey:@"recovery_removal_pending"];[raw removeObjectForKey:@"stop_removal_pending"];
    raw[@"local_active"]=@NO;raw[@"stopping"]=@NO;raw[@"download_requested"]=@NO;raw[@"local_phase"]=error.length?@"failed":@"idle";
    if(error.length)raw[@"error"]=error;else[raw removeObjectForKey:@"error"];
    SAP_JOURNAL_ACTION(@"artist_album_queue_advanced",@{@"album_uri":uri,@"native_state":raw[@"native_state"]?:@0,@"error":error?:@"",@"operation_token":self.token,@"owned_operations":@(s.operations.count-1),@"max_window":@(SAPArtistDirectURI(uri)?SAPArtistSubmittedLimit:2),@"queued_remaining":@(s.queue.count)});
    if(self.discardStoppedIntent || !self.stopped || [raw[@"native_state"]isEqual:@3]){[s clearOwners:uri];[s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];}
    [s.abandonedURIs removeObject:uri];[s.forcedOfflineStops removeObject:uri];[self cancel];[s.operations removeObjectForKey:uri];[s publish];
    for(SAPArtistAlbumOperation *peer in s.operations.allValues)[peer considerRecovery];
    if(!s.stopBatchDepth){[s next];[s pumpAdmissions];}
}
- (void)armWorkDeadline {
    // Every progress event re-arms all releases waiting in Spotify's queue.
    // Re-creating hundreds of timers per event buys no precision on a
    // 15-minute limit, so a fresh timer is kept for a short slack.
    double now=clockNow(),slack=MIN(5.0,SAPArtistWorkTimeoutSeconds/100);
    if(self.workDeadline && self.workDeadlineOperationEpoch==self.epoch && [self isCurrent] && now-self.workDeadlineArmedAt<slack)return;
    if(self.workDeadline){dispatch_source_cancel(self.workDeadline);self.workDeadline=nil;}
    if(![self isCurrent])return;
    self.workDeadlineArmedAt=now;self.workDeadlineOperationEpoch=self.epoch;
    NSUInteger epoch=self.epoch,generation=++self.workEpoch;__weak typeof(self) weak=self;
    self.workDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),SAPArtistWorkTimeoutSeconds,^{
        typeof(self) s=weak;if(!s || ![s isCurrent] || s.epoch!=epoch || s.workEpoch!=generation)return;s.workDeadline=nil;
        NSString *reason=@"Spotify did not confirm progress for 15 minutes. Remaining albums were not started. Reopen the list to refresh the native state.";
        if(s.session.repairing)[s.session suspendObservation:reason];else[s.session pauseWork:reason];
    });
}
- (void)evaluate {
    if(![self isCurrent] || self.paused)return;
    if([self.recoveryStage isEqual:@"settling"] && ![self recoveryEligible])[self cancelRecoveryObservation];
    if(self.commandPending)return;
    NSString *uri=self.uri;NSDictionary *raw=self.session.states[uri];NSUInteger code=[raw[@"native_state"]unsignedIntegerValue];
    // An incremental playlist may receive an already-sent append after it was full.
    // Cancel must confirm native offlining is disabled before releasing ownership.
    if(self.stopped && ([raw[@"stop_removal_pending"]boolValue] || [self.session.forcedOfflineStops containsObject:uri])){if(code==0 && [raw[@"stop_confirmed"]boolValue])[self finish:nil];return;}
    // A completion seen while Remove is pending cannot prove that the
    // destructive command will not take effect later. Keep the FIFO lease.
    if([raw[@"recovery_removal_pending"]boolValue] && !self.stopped)return;
    if([raw[@"native_state"]isEqual:@3]){if(!self.playlistFeedOpen || self.stopped)[self finish:nil];return;}
    if(!self.downloadSent)return;
    if(code==1){[self finish:@"Spotify reported a download error. Tap to retry."];return;}
    if(self.recoveryOwnZero && !self.stopped)return;
    if(code==0 && [raw[@"native_state"]isEqual:@0] && ((self.stopped && [raw[@"stop_confirmed"]boolValue]) || (!self.stopped && [raw[@"native_cancelled"]boolValue]))) {
        if(!self.stopped){self.stopped=YES;[self.session rememberStopped:self.item];}
        [self finish:nil];return;
    }
    // Both native waiter states can outlive complete audio counters. A fresh
    // context read is bounded to this attempt and never synthesizes success.
    if((code==4 || code==5) && self.hasTrustedCounts && [raw[@"total"]unsignedLongLongValue]>0 && [raw[@"downloaded"]isEqual:raw[@"total"]] && !self.completionReadAttempted){self.completionReadAttempted=YES;[self reconcile];}
    [self considerRecovery];
}
// A single native re-registration repairs an observed aggregate waiter. Remove
// has no preserve-cache flag: unreferenced files may need to download again.
// Item verification is a mutation gate, never a substitute for native state 3.
- (BOOL)recoveryExclusive {
    if(![self isCurrent] || self.paused || self.stopped || self.session.repairing || self.session.watchSuspended)return NO;
    id owner=releaseOwner(self.item);NSDictionary *ready=self.session.readyItems[self.uri],*leases=self.session.leaseOrders[self.uri];
    NSSet *owners=self.session.contextOwners[self.uri];
    if(ready.count!=1 || !ready[owner] || leases.count!=1 || !leases[owner] || (owner==NSNull.null?owners.count!=0:(owners.count!=1 || ![owners containsObject:owner])))return NO;
    for(SAPArtistAlbumOperation *peer in self.session.operations.allValues)if(peer!=self && peer.downloadSent)return NO;
    return YES;
}
- (BOOL)recoveryEligible {
    NSDictionary *raw=self.session.states[self.uri];uint64_t total=[raw[@"total"]unsignedLongLongValue],bytes=[raw[@"total_bytes"]unsignedLongLongValue];
    return self.ownAddAcknowledged && SAPIsAlbumURI(self.uri) && self.downloadSent && !self.commandPending && [self recoveryExclusive] &&
        ([raw[@"native_state"]isEqual:@4] || [raw[@"native_state"]isEqual:@5]) && self.hasTrustedCounts && total>0 && [raw[@"downloaded"]unsignedLongLongValue]==total &&
        bytes>0 && [raw[@"downloaded_bytes"]unsignedLongLongValue]==bytes && ![raw[@"queued_tracks"]unsignedLongLongValue] &&
        ![raw[@"queued_bytes"]unsignedLongLongValue] && ![raw[@"native_downloading"]boolValue];
}
- (void)cancelRecoveryObservation {
    self.recoveryEpoch++;
    if(self.recoveryTimer){dispatch_source_cancel(self.recoveryTimer);self.recoveryTimer=nil;}
    if([self.recoveryStage isEqual:@"settling"] || [self.recoveryStage isEqual:@"verifying"] || [self.recoveryStage isEqual:@"confirming_zero"]){
        self.readEpoch++;if(self.cancelRead){self.cancelRead();self.cancelRead=nil;}
    }
    self.recoveryStage=nil;
}
- (void)haltRecovery:(NSString *)reason {
    if(![self isCurrent])return;
    [self cancelRecoveryObservation];self.recoveryStage=@"halted";
    self.session.states[self.uri][@"error"]=reason;
    SAP_JOURNAL_ACTION(@"artist_native_reregistration_halted",@{@"album_uri":self.uri,@"reason":reason,@"attempts":@1,@"mutation_replay":@NO,@"native_state":self.session.states[self.uri][@"native_state"]?:@0});
    [self.session publish];[self evaluate];
}
- (void)considerRecovery {
    if(self.recoveryAttempted || self.recoveryStage.length || ![self recoveryEligible])return;
    self.recoveryStage=@"settling";NSUInteger generation=++self.recoveryEpoch;__weak typeof(self) weak=self;
    self.recoveryTimer=SAPScheduleDeadline(dispatch_get_main_queue(),SAPArtistRecoverySettleSeconds,^{
        typeof(self) op=weak;if(!op || ![op isCurrent] || op.recoveryEpoch!=generation)return;op.recoveryTimer=nil;
        if(![op recoveryEligible]){op.recoveryStage=nil;return;}
        op.recoveryAttempted=YES;op.recoveryStage=@"verifying";
        SAP_JOURNAL_ACTION(@"artist_native_reregistration_verifying",@{@"album_uri":op.uri,@"original_add_acknowledged":@YES,@"trusted_full_progress":@YES,@"exclusive_owner":@YES,@"max_attempts":@1});
        [op readService:offlineService method:@"GetContexts" payload:urisRequest(@[op.uri],3) completion:^(NSData *data,NSString *error){
            if(op.stopped || op.paused || ![op.recoveryStage isEqual:@"verifying"])return;
            NSNumber *fresh=error.length?nil:exactContextState(data,op.uri);
            if(!fresh){[op haltRecovery:@"Spotify could not verify album finalization. No recovery command was sent; refresh or Stop this task."];return;}
            [op.session apply:data progress:NO];if(![op isCurrent])return;
            if((![fresh isEqual:@4] && ![fresh isEqual:@5]) || ![op recoveryEligible]){[op haltRecovery:@"Album status changed during finalization verification. No recovery command was sent; refresh or Stop this task."];return;}
            [op readService:@"spotify.metadata_esperanto.proto.ClassicMetadataService" method:@"GetEntity" payload:SAPProtoBytes(1,[op.uri dataUsingEncoding:NSUTF8StringEncoding]) completion:^(NSData *metadata,NSString *failure){
                if(op.stopped || op.paused || ![op.recoveryStage isEqual:@"verifying"])return;
                NSString *reason=nil;NSArray *tracks=failure?nil:SAPParseArtistAlbumTrackURIs(metadata,op.uri,&reason);
                uint64_t total=[op.session.states[op.uri][@"total"]unsignedLongLongValue];
                if(!tracks.count || tracks.count>10000 || tracks.count!=total || [NSSet setWithArray:tracks].count!=tracks.count){[op haltRecovery:@"Spotify could not verify exact album membership. No recovery command was sent; refresh or Stop this task."];return;}
                for(id track in tracks)if(![track isKindOfClass:NSString.class] || ![track hasPrefix:@"spotify:track:"] || [track length]!=36){[op haltRecovery:@"Spotify returned invalid album tracks. No recovery command was sent; refresh or Stop this task."];return;}
                [op verifyRecoveryItems:tracks offset:0];
            }];
        }];
    });
}
- (void)verifyRecoveryItems:(NSArray *)tracks offset:(NSUInteger)offset {
    if(![self recoveryEligible] || tracks.count!=[self.session.states[self.uri][@"total"]unsignedLongLongValue]){[self haltRecovery:@"Album ownership or progress changed. No recovery command was sent; refresh or Stop this task."];return;}
    if(offset==tracks.count){
        SAP_JOURNAL_ACTION(@"artist_native_reregistration_verified",@{@"album_uri":self.uri,@"expected_tracks":@(tracks.count),@"downloaded_items":@(tracks.count),@"native_state":self.session.states[self.uri][@"native_state"]?:@0,@"cache_redownload_possible":@YES});[self removeForRecovery];return;
    }
    NSArray *chunk=[tracks subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)256,tracks.count-offset))];
    [self readService:offlineService method:@"GetItems" payload:urisRequest(chunk,1) completion:^(NSData *data,NSString *error){
        if(self.stopped || self.paused || ![self.recoveryStage isEqual:@"verifying"])return;
        NSArray *fields=SAPProtoFields(data);NSMutableSet *seen=[NSMutableSet set];BOOL valid=fields!=nil && !error.length;
        for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1){
            if([field[@"wire"]unsignedIntValue]!=2){valid=NO;break;}
            NSArray *item=SAPProtoFields(field[@"value"]);NSString *uri=SAPProtoString(item,1);
            if(!item || ![chunk containsObject:uri] || [seen containsObject:uri] || SAPProtoNumber(item,2,0)!=3){valid=NO;break;}[seen addObject:uri];
        }
        if(!valid || seen.count!=chunk.count){[self haltRecovery:@"Spotify did not confirm every album track downloaded. No recovery command was sent; refresh or Stop this task."];return;}
        [self verifyRecoveryItems:tracks offset:offset+chunk.count];
    }];
}
- (void)removeForRecovery {
    if(![self recoveryEligible]){[self haltRecovery:@"Album ownership or progress changed before recovery. No recovery command was sent; refresh or Stop this task."];return;}
    self.recoveryStage=@"removing";self.recoveryOwnZero=YES;self.commandPending=YES;
    self.session.states[self.uri][@"recovery_removal_pending"]=@YES;
    [self.session.stopSentURIs addObject:self.uri];NSUInteger epoch=self.epoch;
    SAP_JOURNAL_ACTION(@"artist_native_reregistration_remove",@{@"album_uri":self.uri,@"max_attempts":@1,@"mutation_replay":@NO,@"cache_redownload_possible":@YES});
    contextCommandWithDisposition(self.uri,NO,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        if(![self isCurrent] || self.epoch!=epoch)return;self.commandPending=NO;
        uint64_t code=0;NSArray *fields=contextCommandFields(data,self.uri,&code);
        if(disposition==SAPCommandNotInvoked || (!error.length && fields && code)){
            [self.session.stopSentURIs removeObject:self.uri];
            [self.session.states[self.uri]removeObjectForKey:@"recovery_removal_pending"];self.recoveryOwnZero=NO;
        }
        if(self.stopped){self.recoveryStage=nil;[self.session beginNativeStop:self.uri];return;}
        if(disposition!=SAPCommandInvoked || error.length || !fields || code){[self haltRecovery:@"Spotify did not confirm the recovery Remove. It will not be retried; refresh or Stop this task."];return;}
        [self confirmRecoveryZero];
    });
}
- (void)confirmRecoveryZero {
    if(![self recoveryExclusive]){[self haltRecovery:@"Album ownership changed after recovery Remove. Recovery Add was not sent; refresh or Stop this task."];return;}
    self.recoveryStage=@"confirming_zero";
    [self readService:offlineService method:@"GetContexts" payload:urisRequest(@[self.uri],3) completion:^(NSData *data,NSString *error){
        if(self.stopped || self.paused || ![self.recoveryStage isEqual:@"confirming_zero"])return;
        NSNumber *fresh=error.length?nil:exactContextState(data,self.uri);
        if(!fresh){[self haltRecovery:@"Spotify did not confirm the recovery removal state. Recovery Add was not sent; refresh or Stop this task."];return;}
        [self.session apply:data progress:NO];if(![self isCurrent])return;
        if(![fresh isEqual:@0] || ![self recoveryExclusive]){[self haltRecovery:@"Spotify has not confirmed recovery removal. Recovery Add was not sent; refresh or Stop this task."];return;}
        self.recoveryStage=@"readding";self.commandPending=YES;self.recoveryOwnZero=NO;self.hasTrustedCounts=NO;
        // A new native activation must be observed before its zero can mean
        // external cancellation. Recovery's initial zero is expected.
        self.sawNativeActive=NO;
        [self.session.states[self.uri]removeObjectForKey:@"recovery_removal_pending"];
        [self.session.stopSentURIs removeObject:self.uri];[self.session.states[self.uri]removeObjectForKey:@"native_cancelled"];
        NSUInteger epoch=self.epoch;
        SAP_JOURNAL_ACTION(@"artist_native_reregistration_add",@{@"album_uri":self.uri,@"native_zero_confirmed":@YES,@"max_attempts":@1,@"mutation_replay":@NO});
        contextCommandWithDisposition(self.uri,YES,^(NSData *reply,NSString *failure,SAPCommandInvocationDisposition disposition){
            if(![self isCurrent] || self.epoch!=epoch)return;self.commandPending=NO;
            if(self.stopped){self.recoveryStage=nil;[self.session beginNativeStop:self.uri];return;}
            uint64_t code=0;NSArray *response=contextCommandFields(reply,self.uri,&code);
            if(disposition!=SAPCommandInvoked || failure.length || !response || code){self.recoveryOwnZero=YES;[self haltRecovery:@"Spotify did not confirm the recovery Add. It will not be retried; refresh or Stop this task."];return;}
            self.recoveryStage=@"awaiting_native";[self evaluate];[self.session publish];
        });
        if([self isCurrent] && self.epoch==epoch){self.session.watchNeedsRenewal=YES;[self.session startWatch];}
    }];
}
- (void)preflight {
    if(![self isCurrent])return;if(self.paused){self.needsReadRepair=YES;return;}self.readyForDownload=NO;NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    [self readService:offlineService method:@"GetContexts" payload:contextRequest(@[uri]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || epoch!=self.epoch)return;self.cancelRead=nil;
        NSArray *fields=SAPProtoFields(data);NSNumber *code=nil;
        if(fields && !error.length && !SAPProtoNumber(fields,2,0))for(NSDictionary *entry in fields)if([entry[@"number"]unsignedIntValue]==1 && [entry[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(entry[@"value"]),1));if([SAPProtoString(info,1)isEqual:uri] && SAPProtoNumber(info,2,0)<=5)code=@(SAPProtoNumber(info,2,0));}
        if(!code){if(self.session.repairing){self.needsReadRepair=YES;return;}[self finish:error?:@"Spotify did not return a valid album state. The download was not sent."];return;}
        if(code.unsignedIntegerValue==3 && !(SAPIsPlaylistURI(uri) && [self.item[@"refresh_after_append"]boolValue])){if(self.playlistFeedOpen)self.downloadSent=YES;[self.session apply:data progress:NO];return;}
        if(code.unsignedIntegerValue==2 || code.unsignedIntegerValue==4 || code.unsignedIntegerValue==5){self.downloadSent=YES;self.sawNativeActive=YES;self.session.lastSubmittedOperation=self;[self.session stateFor:uri][@"local_phase"]=@"waiting";[self.session apply:data progress:NO];[self.session publish];if(SAPArtistDirectURI(uri))[self.session scheduleNext];return;}
        if(code.unsignedIntegerValue==3)[[self.session stateFor:uri]removeObjectForKey:@"native_state"];else[self.session stateFor:uri][@"native_state"]=code;
        if(SAPIsPlaylistURI(uri))[self requestDownload];else[self readMembership:0 until:0];
    }];
}
- (void)readMembership:(NSUInteger)attempt until:(double)until {
    if(![self isCurrent])return;if(self.paused){self.needsReadRepair=YES;return;}
    if(until && clockNow()>=until){[self finish:@"Spotify did not confirm the album in Your Library within 30 seconds."];return;}
    NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    self.retryEpoch++;NSUInteger deadlineGeneration=self.retryEpoch;
    if(until){__weak typeof(self) weak=self;self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MAX(0,until-clockNow()),^{
        typeof(self) s=weak;if(!s || ![s isCurrent] || s.epoch!=epoch || s.retryEpoch!=deadlineGeneration)return;
        s.retry=nil;[s finish:@"Spotify did not confirm the album in Your Library within 30 seconds."];
    });}
    [self readService:@"spotify.your_library_esperanto.proto.YourLibraryService" method:@"Contains" payload:SAPProtoBytes(3,[uri dataUsingEncoding:NSUTF8StringEncoding]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || epoch!=self.epoch)return;self.cancelRead=nil;self.retryEpoch++;if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}
        if(until && clockNow()>=until){[self finish:@"Spotify did not confirm the album in Your Library within 30 seconds."];return;}
        NSArray *fields=SAPProtoFields(data);NSNumber *member=nil;
        if(fields && SAPProtoNumber(fields,98,0)==200 && !SAPProtoString(fields,99).length && !error.length)
            for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==2 && [field[@"wire"]unsignedIntValue]==2){NSArray *entity=SAPProtoFields(field[@"value"]);if([SAPProtoString(entity,1)isEqual:uri]){uint64_t v=SAPProtoNumber(entity,2,0);if(v<=1)member=@(v);}}
        if(member.boolValue){[self requestDownload];return;}
        if(attempt==0){
            if(self.session.repairing){self.needsReadRepair=YES;return;}
            if(!member){[self finish:error?:@"Spotify did not return a valid library state for this album."];return;}
            if(self.libraryAddSent){[self readMembership:1 until:self.libraryDeadline];return;}
            double deadline=clockNow()+30;
            self.libraryAddSent=YES;self.libraryDeadline=deadline;
            SAPAddAlbumToLibraryOnce(uri,^(NSData *reply,NSString *saveError){if(![self isCurrent] || epoch!=self.epoch)return;[self readMembership:1 until:deadline];});return;
        }
        double delay=MIN(3,attempt);self.retryEpoch++;NSUInteger retryEpoch=self.retryEpoch;__weak typeof(self) weak=self;
        self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MAX(0,MIN(delay,until-clockNow())),^{typeof(self) s=weak;if(!s || ![s isCurrent] || s.epoch!=epoch || s.retryEpoch!=retryEpoch)return;s.retry=nil;[s readMembership:attempt+1 until:until];});
    }];
}
- (void)reconcile {
    if(![self isCurrent])return;NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    [self readService:offlineService method:@"GetContexts" payload:contextRequest(@[uri]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || epoch!=self.epoch)return;self.cancelRead=nil;
        if(error.length){[self.session stateFor:uri][@"error"]=error;[self.session publish];return;}
        [self.session apply:data progress:NO];
    }];
}
- (void)resume {
    if(![self isCurrent] || !self.paused)return;self.paused=NO;[self armWorkDeadline];
    // Observation suspension never cancels a sent mutation. Its original ACK
    // or deadline still owns commandPending, including Stop-before-ACK.
    if(self.commandPending)return;
    if(!self.downloadSent && self.needsReadRepair){self.needsReadRepair=NO;[self preflight];return;}
    NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    [self readService:offlineService method:@"GetContexts" payload:contextRequest(@[uri]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || self.epoch!=epoch)return;
        NSArray *fields=SAPProtoFields(data);NSNumber *code=nil;
        if(fields && !error.length && !SAPProtoNumber(fields,2,0))for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(field[@"value"]),1));if([SAPProtoString(info,1)isEqual:uri] && SAPProtoNumber(info,2,0)<=5)code=@(SAPProtoNumber(info,2,0));}
        if(!code){[self.session stateFor:uri][@"error"]=error?:@"Spotify did not return a valid state. This album still reserves its download slot.";[self.session publish];return;}
        // State zero without prior native activity still may precede startup;
        // a command ACK alone cannot release this reservation.
        if([code isEqual:@0]) {
            if([self.session.stopSentURIs containsObject:uri])[self.session stateFor:uri][@"stop_confirmed"]=@YES;
            else if(self.sawNativeActive)[self.session stateFor:uri][@"native_cancelled"]=@YES;
        }
        if(code.unsignedIntegerValue==2 || code.unsignedIntegerValue==4 || code.unsignedIntegerValue==5)self.sawNativeActive=YES;
        [self.session apply:data progress:NO];[self.session publish];
    }];
}
- (void)requestDownload {
    if(![self isCurrent] || self.downloadSent || self.paused)return;
    if(!self.countReadAttempted && SAPIsAlbumURI(self.uri) && !SAPArtistDirectURI(self.uri) && [self.item[@"type"]unsignedIntValue]==2 && ![self.item[@"track_count_verified"]boolValue]) {
        self.countReadAttempted=YES;NSUInteger epoch=self.epoch;NSString *uri=self.uri;
        [self readService:@"spotify.metadata_esperanto.proto.ClassicMetadataService" method:@"GetEntity" payload:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]) completion:^(NSData *data,NSString *error){
            if(![self isCurrent] || epoch!=self.epoch)return;NSString *reason=nil;NSArray *tracks=error?nil:SAPParseArtistAlbumTrackURIs(data,uri,&reason);
            if(tracks){NSMutableDictionary *item=[self.item mutableCopy];item[@"track_count_verified"]=@YES;item[@"verified_track_count"]=@(tracks.count);self.item=item;}
            SAP_JOURNAL_ACTION(@"artist_single_membership_verified",@{@"album_uri":uri,@"verified":@(tracks!=nil),@"track_count":@(tracks.count),@"error":error?:reason?:@""});
            [self requestDownload];
        }];return;
    }
    self.readyForDownload=YES;
    [self.session publish];[self.session pumpAdmissions];
}
- (void)submitDownload {
    if(![self isCurrent] || self.downloadSent || self.paused)return;
    self.readyForDownload=NO;self.hasTrustedCounts=NO;self.session.lastSubmittedOperation=self;
    NSUInteger epoch=self.epoch;NSString *uri=self.uri;self.downloadSent=YES;self.commandPending=YES;self.submittedWatchEpoch=self.session.watchEpoch;
    NSMutableDictionary *raw=[self.session stateFor:uri];
    // A preflight error belongs to the previous attempt. Only fresh native
    // context events can terminate this newly submitted download as failed.
    if([raw[@"native_state"]isEqual:@1])[raw removeObjectForKey:@"native_state"];
    [raw removeObjectForKey:@"stop_confirmed"];[raw removeObjectForKey:@"native_cancelled"];[self.session.stopSentURIs removeObject:uri];raw[@"download_requested"]=@YES;raw[@"local_phase"]=@"waiting";[self.session publish];
    NSUInteger submitted=0;for(SAPArtistAlbumOperation *owned in self.session.operations.allValues)if(owned.downloadSent)submitted++;
    NSMutableDictionary *selectedRelease=[NSMutableDictionary dictionaryWithObject:uri forKey:@"uri"];
    for(NSString *key in @[@"name",@"category",@"type",@"year"]){id value=self.item[key];if([value isKindOfClass:NSString.class])selectedRelease[key]=[value length]<=512?value:[value substringToIndex:512];else if([value isKindOfClass:NSNumber.class])selectedRelease[key]=value;}
    SAP_JOURNAL_ACTION(@"artist_album_download_requested",@{@"album_uri":uri,@"selected_release":selectedRelease,@"automatic_replay":@NO,@"operation_token":self.token,@"owned_operations":@(self.session.operations.count),@"max_window":@(SAPArtistDirectURI(uri)?SAPArtistSubmittedLimit:2),@"queued_remaining":@(self.session.queue.count),@"submitted_operations":@(submitted),@"release_gate":self.releaseGate?:@{}});
    contextCommandWithDisposition(uri,YES,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        if(![self isCurrent] || epoch!=self.epoch || !self.commandPending)return;self.commandPending=NO;
        if(disposition==SAPCommandNotInvoked){
            self.downloadSent=NO;SAP_JOURNAL_ACTION(@"artist_album_not_sent",@{@"album_uri":uri,@"error":error?:@"No verified native transport.",@"automatic_replay":@NO});
            [self finish:self.stopped?nil:error?:@"Spotify did not start this download. Refresh the device state and try again."];return;
        }
        if([raw[@"native_state"]isEqual:@3]){if(self.stopped && [self.session.forcedOfflineStops containsObject:uri])[self.session beginNativeStop:uri];else[self evaluate];[self.session publish];return;}
        uint64_t code=0;NSArray *fields=contextCommandFields(data,uri,&code);
        // Empty protobuf data is a valid success reply. A missing/malformed
        // response or transport error cannot prove that the mutation failed.
        if(error.length || !fields){
            raw[@"error"]=error.length?error:@"Spotify did not confirm the download command. Waiting for native status; the command will not be sent again.";
            SAP_JOURNAL_ACTION(@"artist_album_ack_unconfirmed",@{@"album_uri":uri,@"error":raw[@"error"],@"automatic_replay":@NO});
            if(self.stopped)[self.session beginNativeStop:uri];else[self reconcile];[self.session publish];return;
        }
        if(code){[self finish:[NSString stringWithFormat:@"Spotify rejected the download (code %llu).",(unsigned long long)code]];return;}
        self.ownAddAcknowledged=YES;
        SAP_JOURNAL_ACTION(@"artist_album_submission_acknowledged",@{@"album_uri":uri,@"download_completion_confirmed":@NO});
        if(self.stopped){[self.session beginNativeStop:uri];return;}[self evaluate];[self.session publish];
    });
    // Start observations after the mutation was queued on the transport worker.
    // Old subscription callbacks cannot complete this new album attempt.
    if(epoch==self.epoch && [self isCurrent]) {
        if(SAPArtistDirectURI(uri)){[self.session scheduleWatchRenewal];[self.session scheduleNext];}
        else{self.session.watchNeedsRenewal=YES;[self.session startWatch];}
    }
}
@end
