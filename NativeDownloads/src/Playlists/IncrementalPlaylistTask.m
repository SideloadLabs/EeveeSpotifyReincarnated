#import "PlaylistDownloadsInternal.h"

@implementation SAPIncrementalPlaylistTask
- (BOOL)reserve:(NSString **)error {
    NSArray *sources=self.releasePlan?:self.releases;NSMutableArray *reserved=[NSMutableArray arrayWithCapacity:sources.count];
    for(NSDictionary *release in sources)[reserved addObject:@{@"uri":release[@"uri"],@"name":release[@"name"]?:@"Release",@"artist_uri":self.artistURI,@"owner_token":self.token}];
    if(!SAPReserveArtistDownloadSessionReleases(reserved,error))return NO;self.sessionReserved=YES;return YES;
}
- (void)detachAlbumContext {self.albumEpoch++;dispatch_block_t detach=self.detachAlbum;self.detachAlbum=nil;if(detach)detach();self.albumContextState=nil;}
- (void)stopAlbum {
    if(!self.sessionReserved && !self.albumStarted)return;self.albumStopPending=YES;
    BOOL pending=SAPCancelArtistDownloadOwner(self.artistURI,self.token);self.sessionReserved=NO;
    if(self.active)self.albumStopPending=pending;
}
- (BOOL)isQueuedRelease:(NSString *)uri {NSNumber *position=self.releasePositions[uri];return position && position.unsignedIntegerValue>self.releaseIndex;}
- (void)detachBatch {
    self.batchWatching=NO;[self.releaseObservation invalidate];self.releaseObservation=nil;self.batchState=nil;self.batchEpoch++;
    if(self.batchDeadline){dispatch_source_cancel(self.batchDeadline);self.batchDeadline=nil;}
}
- (void)armBatchDeadline {
    if(self.batchDeadline)dispatch_source_cancel(self.batchDeadline);__weak typeof(self) weak=self;NSUInteger epoch=self.batchEpoch;
    self.batchDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),900,^{typeof(self) task=weak;if(!task || !task.active || task.batchEpoch!=epoch)return;task.batchDeadline=nil;
        if(!task.cancelled)task.stopped=YES;[task finish:@"Spotify did not confirm the current release. Later tracks were not added. Continue to retry after checking the connection."];
    });
}
- (void)begin {
    if(!self.active || self.stopped || !self.queued)return;self.queued=NO;self.submitted=NO;self.nativeStarted=self.nativeReady=self.streamReady=self.finishing=self.feedClosed=NO;self.albumStarted=self.albumStopPending=NO;self.offset=self.index=self.releaseIndex=0;self.completedTracks=[NSMutableSet set];self.verifiedSources=[NSMutableSet set];
    __weak typeof(self) weak=self;self.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),1800,^{[weak finish:@"Playlist preparation timed out. Confirmed additions were kept."];});
    if(self.plan){self.tracks=self.plan;[self target];}else{self.orderedTracks=[NSMutableOrderedSet orderedSet];[self resolve];}
}
- (void)save {
    if(!self.active || self.stopped)return;
    if(!self.streamReady){
        self.plan=[self.tracks copy];NSMutableArray *releases=[NSMutableArray array];
        for(NSDictionary *release in self.releases){NSArray *tracks=self.releaseTracks[release[@"uri"]];if(tracks.count)[releases addObject:@{@"uri":release[@"uri"],@"name":release[@"name"]?:@"Release",@"tracks":tracks}];}self.releasePlan=releases;NSMutableDictionary *positions=[NSMutableDictionary dictionary];for(NSUInteger i=0;i<releases.count;i++)positions[releases[i][@"uri"]]=@(i);self.releasePositions=positions;
        self.releases=nil;[self target];return;
    }
    if(self.index==self.batchSources.count){[self append];return;}
    NSString *uri=self.batchSources[self.index];if([self.verifiedSources containsObject:uri]){self.index++;[self save];return;}
    self.message=@"Preparing current tracks…";NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(SAPPlaylistLibraryService,@"Contains",SAPPlaylistString(3,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;NSArray *fields=SAPProtoFields(data);NSNumber *member=nil;
        if(!error.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in SAPPlaylistMessages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)<=1)member=@(SAPProtoNumber(entry,2,0));
        if(!member){self.stopped=YES;[self finish:error?:@"Spotify did not confirm library membership."];return;}
        if(member.boolValue){[self.verifiedSources addObject:uri];self.index++;[self save];return;}
        self.commandPending=YES;SAPAddAlbumToLibraryOnce(uri,^(__unused NSData *reply,__unused NSString *failure){if(!self.active || self.epoch!=epoch)return;self.commandPending=NO;if(self.stopped){[self settleStop];return;}[self verifyLibrary:uri attempt:0];});
    });
}
- (void)verifyLibrary:(NSString *)uri attempt:(NSUInteger)attempt {
    if(!self.active || self.stopped)return;NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(SAPPlaylistLibraryService,@"Contains",SAPPlaylistString(3,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;BOOL member=NO;NSArray *fields=SAPProtoFields(data);
        if(!error.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in SAPPlaylistMessages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)==1)member=YES;
        if(member){[self.verifiedSources addObject:uri];self.index++;[self save];return;}
        if(attempt>=5){self.stopped=YES;[self finish:error?:@"Spotify did not confirm this release in Your Library."];return;}
        self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MIN(5,attempt+1),^{self.retry=nil;if([self valid:epoch])[self verifyLibrary:uri attempt:attempt+1];});
    });
}
- (void)readTarget {
    self.message=@"Reading playlist contents…";NSUInteger epoch=self.epoch;
    self.cancelRead=SAPPlaylistReadList(self.uri,^(NSDictionary *contents,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;
        if(!contents || ![contents[@"can_add"]boolValue]){[self finish:error?:@"Spotify does not allow adding tracks to this playlist."];return;}
        self.name=contents[@"name"]?:self.name;self.baseline=contents[@"items"];self.targetTracks=[NSMutableSet setWithArray:self.baseline];NSUInteger missing=0;for(NSString *track in self.plan)missing+=![self.targetTracks containsObject:track];
        if(self.baseline.count+missing>SAPPlaylistMaximumItems){[self finish:@"The destination playlist would exceed 10,000 items."];return;}
        self.streamReady=YES;[self advanceRelease];
    });
}
- (void)advanceRelease {
    if(!self.active || self.stopped)return;[self detachBatch];[self detachAlbumContext];self.albumStarted=self.albumStopPending=NO;self.currentBatch=nil;self.batchCommitted=NO;
    if(self.releaseIndex>=self.releasePlan.count){
        self.finishing=YES;NSUInteger epoch=self.epoch;self.message=@"Checking completed playlist…";
        self.cancelRead=SAPPlaylistReadList(self.uri,^(NSDictionary *contents,NSString *error){
            if(![self valid:epoch])return;self.cancelRead=nil;
            if(!contents || ![contents[@"items"]isEqual:self.baseline]){self.stopped=YES;[self finish:error?:@"The playlist order changed. Confirmed additions were kept."];return;}
            [self submitPlaylist];
        });return;
    }
    self.batchRelease=self.releasePlan[self.releaseIndex];self.currentBatch=self.batchRelease[@"tracks"];self.batchSources=@[self.batchRelease[@"uri"]];self.index=0;SAPPlaylistItemTaskRevision++;
    SAP_JOURNAL_ACTION(@"playlist_release_prepared",@{@"operation":self.token,@"artist_uri":self.artistURI?:@"",@"release_uri":self.batchRelease[@"uri"],@"release_index":@(self.releaseIndex),@"track_count":@(self.currentBatch.count)});[self save];
}
- (void)append {
    if(!self.active || self.stopped)return;NSMutableArray *add=[NSMutableArray array];for(NSString *track in self.currentBatch)if(![self.targetTracks containsObject:track])[add addObject:track];self.appendTracks=add;self.appendIndex=0;[self appendChunk];
}
- (void)appendChunk {
    if(!self.active || self.stopped)return;
    if(self.appendIndex==self.appendTracks.count){self.batchCommitted=YES;[self submit];return;}
    NSArray *add=[self.appendTracks subarrayWithRange:NSMakeRange(self.appendIndex,MIN((NSUInteger)100,self.appendTracks.count-self.appendIndex))];
    NSUInteger start=self.baseline.count,epoch=self.epoch;NSMutableData *request=[SAPPlaylistString(1,@"add")mutableCopy];[request appendData:SAPPlaylistString(3,@"end")];for(NSString *track in add)[request appendData:SAPPlaylistString(7,track)];NSMutableData *outer=[SAPPlaylistString(1,self.uri)mutableCopy];[outer appendData:SAPProtoBytes(2,request)];self.commandPending=YES;self.message=@"Adding current release…";
    SAPCallPlaylistModificationOnce(NO,outer,^(NSData *reply,NSString *error){
        if(!self.active || self.epoch!=epoch)return;self.commandPending=NO;NSString *failure=error;BOOL acknowledged=!error.length && SAPPlaylistStatusOK(SAPProtoFields(reply),&failure);
        // Only settle the already-sent chunk after cancellation; never replay it.
        self.cancelRead=SAPPlaylistReadListFrom(self.uri,start,^(NSDictionary *contents,NSString *readError){
            if(!self.active || self.epoch!=epoch)return;self.cancelRead=nil;BOOL exact=contents && [contents[@"total"]unsignedIntegerValue]==start+add.count && [contents[@"items"]isEqual:add];
            SAP_JOURNAL_ACTION(@"playlist_release_append_verified",@{@"operation":self.token,@"playlist_uri":self.uri,@"release_uri":self.batchRelease[@"uri"],@"chunk_offset":@(self.appendIndex),@"appended":add,@"verified":@(exact),@"acknowledged":@(acknowledged),@"error":readError?:failure?:@"",@"automatic_replay":@NO});
            if(!exact){self.stopped=YES;[self finish:readError?:failure?:@"Spotify did not confirm the appended release. No append was repeated."];return;}
            self.baseline=[self.baseline arrayByAddingObjectsFromArray:add];[self.targetTracks addObjectsFromArray:add];self.addedCount+=add.count;self.appendIndex+=add.count;
            if(self.stopped){[self settleStop];return;}[self appendChunk];
        });
    });
}
- (void)submit {
    if(!self.active || self.stopped || self.albumStarted)return;
    self.albumStarted=YES;self.submitted=YES;self.message=@"Registering album for offline…";SAPPlaylistItemTaskRevision++;
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    NSDictionary *album=@{@"uri":self.batchRelease[@"uri"],@"name":self.batchRelease[@"name"]?:@"Release",@"artist_uri":self.artistURI,@"owner_token":self.token,@"track_count_verified":@YES,@"verified_track_count":@(self.currentBatch.count),@"follow_external_changes":@YES};NSString *error=nil;
    if(!SAPAppendArtistDownloadSessionReleases(@[album],&error)){self.stopped=YES;[self finish:error?:@"Spotify did not accept the album download."];return;}
    NSUInteger epoch=self.albumEpoch;__weak typeof(self) weak=self;
    dispatch_block_t detach=SAPObserveArtistDownloadSession(@[album],^(NSDictionary *snapshot){
        typeof(self) task=weak;if(!task || !task.active || task.terminating || task.albumEpoch!=epoch)return;
        NSDictionary *state=snapshot[@"album_states"][task.batchRelease[@"uri"]];if([task.albumContextState isEqual:state])return;task.albumContextState=state;
        if(task.stopped){[task settleStop];return;}
        if([task.albumContextState[@"phase"]isEqual:@"failed"]){task.stopped=YES;[task finish:task.albumContextState[@"error"]?:@"Spotify could not register this album for offline playback."];return;}
        [task checkBatch];
    });
    if(self.active && self.albumEpoch==epoch)self.detachAlbum=detach;else if(detach)detach();
    if(self.active&&!self.stopped)[self watchBatch];SAPPlaylistScheduleTasks();
}
- (void)submitPlaylist {
    if(!self.active || self.stopped || self.nativeStarted)return;
    // Album registrations have finished and released their shared queue slots.
    // The playlist now gets its own native offline registration as well.
    self.nativeStarted=YES;self.message=@"Registering playlist for offline…";
    NSDictionary *context=@{@"uri":self.uri,@"name":self.name?:@"Playlist",@"category":@"Playlist",@"refresh_after_append":@(self.addedCount>0),@"artist_uri":self.artistURI,@"owner_token":self.token,@"follow_external_changes":@YES};NSString *error=nil;
    if(!SAPAppendArtistDownloadSessionReleases(@[context],&error)){self.stopped=YES;[self finish:error?:@"Spotify did not accept the playlist download."];return;}
    NSUInteger epoch=self.epoch;__weak typeof(self) weak=self;
    dispatch_block_t detach=SAPObserveArtistDownloadSession(@[context],^(NSDictionary *snapshot){
        typeof(self) task=weak;if(!task || !task.active || task.terminating || task.epoch!=epoch)return;NSDictionary *state=snapshot[@"album_states"][task.uri];if([task.contextState isEqual:state])return;task.contextState=state;
        if(task.stopped){[task settleStop];return;}
        if([task.contextState[@"phase"]isEqual:@"failed"]){task.stopped=YES;[task finish:task.contextState[@"error"]?:@"Spotify could not register this playlist for offline playback."];return;}
        [task checkBatch];
    });
    if(self.active && self.epoch==epoch)self.detachSession=detach;else if(detach)detach();[self armBatchDeadline];SAPPlaylistScheduleTasks();
}
- (void)watchBatch {
    if(!self.active || !self.currentBatch.count || self.batchWatching || self.stopped || !self.albumStarted)return;
    self.batchWatching=YES;NSUInteger generation=++self.batchEpoch;__weak typeof(self) weak=self;
    NSDictionary *release=@{@"uri":self.batchRelease[@"uri"],@"track_count_verified":@YES,@"track_uris":self.currentBatch};
    SAPReleaseItemObservation *observation=SAPObserveReleaseItems(@[release],^(NSDictionary *snapshot){
        typeof(self) task=weak;if(!task || !task.active || task.batchEpoch!=generation || task.stopped)return;
        NSDictionary *state=snapshot[@"album_states"][task.batchRelease[@"uri"]];if(!state)return;BOOL changed=![task.batchState isEqual:state];task.batchState=state;if(changed)[task armBatchDeadline];[task checkBatch];
    });
    if(self.active && self.batchEpoch==generation)self.releaseObservation=observation;else[observation invalidate];[self armBatchDeadline];
}
- (void)checkBatch {
    if(!self.active)return;
    if(self.stopped){[self settleStop];return;}
    if(self.finishing){
        if(self.nativeStarted && ![self.contextState[@"owned"]boolValue] && ![self.contextState[@"submission_pending"]boolValue] && [self.contextState[@"state"]isEqual:@"downloaded"])[self finish:nil];
        else if([self.contextState[@"native_cancelled"]boolValue])[self publishMessage:@"Stopped in Spotify. Waiting for restart…"];
        return;
    }
    if(!self.albumStarted || !self.batchCommitted)return;
    if([self.albumContextState[@"native_cancelled"]boolValue]){[self publishMessage:@"Stopped in Spotify. Waiting for restart…"];return;}
    if([self.batchState[@"error"]length]){self.stopped=YES;[self finish:self.batchState[@"error"]];return;}
    NSUInteger done=[self.batchState[@"downloaded_tracks"]unsignedIntegerValue];
    if([self.albumContextState[@"state"]isEqual:@"downloaded"] && ![self.albumContextState[@"owned"]boolValue] && ![self.albumContextState[@"submission_pending"]boolValue] && [self.batchState[@"state"]isEqual:@"downloaded"] && [self.batchState[@"known_tracks"]unsignedIntegerValue]==self.currentBatch.count){
        [self.completedTracks addObjectsFromArray:self.currentBatch];self.offset=self.completedTracks.count;self.releaseIndex++;[self detachBatch];SAP_JOURNAL_ACTION(@"playlist_release_completed",@{@"operation":self.token,@"release_uri":self.batchRelease[@"uri"],@"completed_releases":@(self.releaseIndex),@"selected_releases":@(self.releasePlan.count)});[self advanceRelease];
    }else [self publishMessage:[NSString stringWithFormat:@"Downloading release %lu / %lu… %lu / %lu tracks",(unsigned long)self.releaseIndex+1,(unsigned long)self.releasePlan.count,(unsigned long)done,(unsigned long)self.currentBatch.count]];
}
- (void)settleStop {
    if(!self.active || self.terminating || !self.stopped || self.commandPending || self.cancelRead)return;
    if(self.albumStopPending && ([self.albumContextState[@"owned"]boolValue] || [self.albumContextState[@"stop_pending"]boolValue] || [self.albumContextState[@"submission_pending"]boolValue]))return;
    if(!self.nativeStarted){[self finish:nil];return;}
    if(![self.contextState[@"active"]boolValue] && ![self.contextState[@"stop_pending"]boolValue] && ![self.contextState[@"owned"]boolValue] && ![self.contextState[@"submission_pending"]boolValue])[self finish:nil];
}
- (void)stop {
    if(!self.active || self.stopped)return;self.stoppedVisuals=SAPPlaylistCaptureStoppedVisuals(self.sourceURIs);self.stopped=YES;SAPPlaylistItemTaskRevision++;self.message=@"Stopping…";[self detachBatch];
    if(!self.commandPending){dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();}
    [self stopAlbum];if(!self.active)return;if(self.nativeStarted)SAPStopArtistDownloadSessionRelease(self.uri);[self settleStop];
}
- (void)cancel {
    if(self.cancelled)return;BOOL wasStopped=self.stopped;self.cancelled=YES;self.resumeBlocked=YES;self.stoppedVisuals=nil;SAPPlaylistItemTaskRevision++;
    if(!self.active){SAPCancelArtistDownloadOwner(self.artistURI,self.token);self.stopped=NO;self.plan=nil;self.releasePlan=nil;self.releasePositions=nil;self.batchRelease=nil;self.completedTracks=nil;self.appendTracks=nil;self.releases=nil;SAPForgetPlaylistDownloadIntent(self.uri);SAPPlaylistPublishTasks();return;}
    self.stopped=YES;self.message=@"Canceling…";[self detachBatch];
    if(!self.commandPending){dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();}
    // Disable the native offline context, retaining the playlist and its rows.
    // The shared session waits for its original Add ACK before sending Stop.
    if(!wasStopped){[self stopAlbum];if(!self.active)return;if(self.nativeStarted)SAPStopArtistDownloadSessionRelease(self.uri);}
    [self settleStop];SAPPlaylistPublishTasks();
}
- (void)finish:(NSString *)error {
    if(!self.active || self.terminating)return;self.terminating=YES;[self detachBatch];if(self.sessionReserved || self.albumStarted)SAPCancelArtistDownloadOwner(self.artistURI,self.token);self.sessionReserved=NO;[self detachAlbumContext];if(self.nativeStarted && !self.feedClosed){self.feedClosed=YES;SAPClosePlaylistDownloadFeed(self.uri);}
    if(self.cancelled)SAPForgetPlaylistDownloadIntent(self.uri);
    if(!self.stopped || self.cancelled){self.plan=nil;self.releasePlan=nil;self.releasePositions=nil;self.batchRelease=nil;self.completedTracks=nil;self.appendTracks=nil;self.currentBatch=nil;self.batchSources=nil;self.targetTracks=nil;self.verifiedSources=nil;}
    [super finish:error];self.terminating=NO;
}
@end
