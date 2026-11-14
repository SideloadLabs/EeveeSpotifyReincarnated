#import "ArtistSessionPrivate.h"

@implementation SAPArtistDownloadSession (Cancellation)
- (void)readStopURI:(NSString *)uri token:(NSString *)token completion:(void (^)(NSData *,NSString *))completion {
    dispatch_block_t previous=self.stopReadCancels[uri];if(previous)previous();[self.stopReadCancels removeObjectForKey:uri];
    __block BOOL finished=NO;
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(offlineService,@"GetContexts",contextRequest(@[uri]),^(NSData *data,NSString *error){
        if(finished || ![self.stopTokens[uri]isEqual:token])return;finished=YES;[self.stopReadCancels removeObjectForKey:uri];completion(data,error);
    });
    if(!finished && [self.stopTokens[uri]isEqual:token] && cancel)self.stopReadCancels[uri]=[^{finished=YES;cancel();} copy];
}
- (void)releaseUnsentStop:(NSString *)uri state:(NSMutableDictionary *)raw {
    // A positively unissued/rejected command can be retried explicitly. Keep
    // the original native download lease; uncertain mutations never use this.
    raw[@"stopping"]=@NO;[raw removeObjectForKey:@"stop_removal_pending"];
    self.operations[uri].stopped=NO;
    [self.stopSentURIs removeObject:uri];[self.stopOperations removeObject:uri];[self.stopTokens removeObjectForKey:uri];
    [self.forcedOfflineStops removeObject:uri];[self.stoppedItems removeObjectForKey:uri];[self.stoppedOrder removeObject:uri];
}
- (void)beginNativeStop:(NSString *)uri {
    if([self.stopOperations containsObject:uri])return;
    BOOL removalAlreadySent=[self.stopSentURIs containsObject:uri];
    NSMutableDictionary *raw=[self stateFor:uri];raw[@"stopping"]=@YES;[self.stopOperations addObject:uri];
    NSString *token=NSUUID.UUID.UUIDString;self.stopTokens[uri]=token;[self publish];
    [self readStopURI:uri token:token completion:^(NSData *data,NSString *error){
        if(![self.stopTokens[uri]isEqual:token])return;
        NSNumber *fresh=nil;NSArray *envelope=SAPProtoFields(data);
        if(envelope && !error.length && !SAPProtoNumber(envelope,2,0))for(NSDictionary *field in envelope)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(field[@"value"]),1));if([SAPProtoString(info,1)isEqual:uri] && SAPProtoNumber(info,2,0)<=5)fresh=@(SAPProtoNumber(info,2,0));}
        if(!removalAlreadySent && ![self.forcedOfflineStops containsObject:uri] && ([raw[@"native_state"]isEqual:@3] || [fresh isEqual:@3])){raw[@"native_state"]=@3;raw[@"stopping"]=@NO;[self.stopOperations removeObject:uri];[self.stopTokens removeObjectForKey:uri];[self.stopSentURIs removeObject:uri];[self noteCacheTouch:uri];[self.operations[uri] evaluate];[self publish];return;}
        if(!fresh){
            // No command was issued: make the row retryable, without releasing
            // the still-active native download or replaying an earlier Remove.
            if(!removalAlreadySent)[self releaseUnsentStop:uri state:raw];
            raw[@"error"]=error?:@"Spotify did not confirm the current state. Stop was not sent; remaining albums are waiting.";[self.stopOperations removeObject:uri];[self.stopTokens removeObjectForKey:uri];[self publish];return;}
        if(removalAlreadySent) {
            // A previous Remove is never replayed, including after a pause.
            [self apply:data progress:NO];[self publish];return;
        }
        [self.stopSentURIs addObject:uri];raw[@"stop_removal_pending"]=@YES;
        SAP_JOURNAL_ACTION(@"artist_album_stop_requested",@{@"album_uri":uri,@"automatic_replay":@NO});
        contextCommandWithDisposition(uri,NO,^(NSData *reply,NSString *failure,SAPCommandInvocationDisposition disposition){
            if(![self.stopTokens[uri]isEqual:token])return;
            [self.stopOperations removeObject:uri];[self noteCacheTouch:uri];uint64_t code=0;NSArray *fields=contextCommandFields(reply,uri,&code);
            if(disposition==SAPCommandNotInvoked || (!failure.length && fields && code)) {
                [self releaseUnsentStop:uri state:raw];
                raw[@"error"]=failure.length?failure:@"Spotify rejected Stop. Tap again to retry.";
                [self.operations[uri] evaluate];[self publish];return;
            }
            if(disposition!=SAPCommandInvoked || failure.length || !fields || code){raw[@"error"]=failure?:@"Spotify did not confirm the stop command. Waiting for native status.";[self publish];return;}
            // Removal acknowledgment is not a terminal native download state.
            // Reconcile once; subscriptions deliver any later transition.
            [self readStopURI:uri token:token completion:^(NSData *freshData,NSString *freshError){
                if(![self.stopTokens[uri]isEqual:token])return;
                if(!freshError.length)[self apply:freshData progress:NO];else raw[@"error"]=freshError;[self publish];
            }];
        });
    }];
}
- (void)stopURI:(NSString *)uri {
    if(!validContextURI(uri))return;
    SAPArtistAlbumOperation *owned=self.operations[uri];if(owned.playlistFeedOpen || [self.states[uri][@"recovery_removal_pending"]boolValue])[self.forcedOfflineStops addObject:uri];
    for(NSDictionary *item in self.queue)if([item[@"uri"]isEqual:uri] && [item[@"incremental_playlist"]boolValue])[self.forcedOfflineStops addObject:uri];
    if(owned)[self rememberStopped:owned.item];
    for(NSDictionary *item in self.queue)if([item[@"uri"]isEqual:uri])[self rememberStopped:item];
    BOOL queued=[self.queuedURIs containsObject:uri];[self.queuedURIs removeObject:uri];[self.queueOrders removeObjectForKey:uri];[self.readyItems removeObjectForKey:uri];[self.leaseOrders removeObjectForKey:uri];
    [self.queue filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return ![item[@"uri"]isEqual:uri];}]];
    NSMutableDictionary *raw=[self stateFor:uri];
    if(queued){raw[@"reserved"]=@NO;raw[@"local_active"]=@NO;raw[@"local_phase"]=@"idle";[raw removeObjectForKey:@"error"];}
    SAPArtistAlbumOperation *operation=self.operations[uri];
    if(operation) {
        if(operation.paused){operation.paused=NO;[operation armWorkDeadline];}
        [operation cancelRecoveryObservation];
        operation.stopped=YES;raw[@"stopping"]=@YES;
        if(operation.commandPending){[self publish];return;}
        if(!operation.downloadSent && ![self.forcedOfflineStops containsObject:uri]){[operation finish:nil];return;}
        if([raw[@"native_state"]isEqual:@3] && ![raw[@"stop_removal_pending"]boolValue] && ![self.forcedOfflineStops containsObject:uri]){[operation finish:nil];return;}
        [self beginNativeStop:uri];return;
    }
    if([self.forcedOfflineStops containsObject:uri] || (![raw[@"native_state"]isEqual:@3] && (activeNative(raw) || [raw[@"download_requested"]boolValue])))[self beginNativeStop:uri];
    [self publish];if(!self.stopBatchDepth)[self next];
}
- (void)stopURIs:(NSSet<NSString *> *)uris {
    // Remove every unsent item in the scope before a synchronous stop callback
    // can advance into a second selected item. Other artists stay queued.
    self.repairEpisodes=0;BOOL wasRepairing=self.repairing || self.observationPaused;self.observationPaused=NO;[self cancelRepair];
    // Invalidate the repair read before scoped Stop can remove or finish its
    // owners. A late verification reply cannot admit an abandoned selection.
    self.repairing=wasRepairing;self.stopBatchDepth++;[self resumePausedOperationsExcept:uris];
    NSArray *owned=[self.operations.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPArtistAlbumOperation *a,SAPArtistAlbumOperation *b){return a.sequence<b.sequence?NSOrderedAscending:a.sequence>b.sequence?NSOrderedDescending:NSOrderedSame;}];
    for(SAPArtistAlbumOperation *operation in owned)if([uris containsObject:operation.uri])[self rememberStopped:operation.item];
    for(NSDictionary *item in self.queue)if([uris containsObject:item[@"uri"]])[self rememberStopped:item];
    for(NSString *uri in uris)[self stopURI:uri];
    self.stopBatchDepth--;self.repairing=NO;
    if(wasRepairing)self.watchNeedsRenewal=YES;
    BOOL remaining=self.queue.count>0;for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(!owned.stopped)remaining=YES;
    if(wasRepairing && remaining)[self repairWatch:@"Refreshing status for the albums remaining after Stop."];
    [self publish];[self next];[self pumpAdmissions];
}@end
