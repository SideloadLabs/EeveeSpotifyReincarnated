#import "PlaylistDownloadsInternal.h"

@implementation SAPPlaylistDownloadTask
- (BOOL)reserve:(NSString **)error {return YES;}
- (void)begin {
    if(!self.active || self.stopped || !self.queued)return;self.queued=NO;
    __weak typeof(self) weak=self;
    self.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),1800,^{typeof(self) task=weak;if(task.active)[task finish:@"Playlist preparation timed out. Check Your Library for any confirmed additions before retrying."];});
    SAP_JOURNAL_ACTION(@"playlist_queue_started",@{@"operation":self.token,@"playlist_uri":self.uri?:@"",@"release_count":@(self.sourceURIs.count)});
    if(self.submitted){self.addedCount=0;[self submit];return;}
    self.index=self.offset=0;self.orderedTracks=[NSMutableOrderedSet orderedSet];[self resolve];
}
- (void)setMessage:(NSString *)message {if([_message isEqual:message])return;_message=[message copy];SAP_JOURNAL_ACTION(@"playlist_download_phase",@{@"operation":self.token?:@"",@"playlist_uri":self.uri?:@"",@"message":message?:@"",@"added_tracks":@(self.addedCount)});SAPPlaylistPublishTasks();}
- (void)publishMessage:(NSString *)message {
    BOOL changed=![self.message isEqual:message];self.message=message;if(!changed)SAPPlaylistPublishTasks();
}
- (void)stopRequestedBy:(NSString *)caller reason:(NSString *)reason {
    SAP_JOURNAL_ACTION(@"playlist_stop_task",@{@"operation":self.token?:@"",@"artist_uri":self.artistURI?:@"",@"playlist_uri":self.uri?:@"",@"caller":caller,@"requested_reason":reason,@"active":@(self.active),@"queued":@(self.queued),@"submitted":@(self.submitted),@"already_stopped":@(self.stopped)});
    [self stop];
}
- (BOOL)valid:(NSUInteger)epoch{return self.active && !self.stopped && self.epoch==epoch;}
- (void)finish:(NSString *)error {
    if(!self.active)return;self.active=NO;self.epoch++;self.error=error;SAPPlaylistItemTaskRevision++;
    dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();cancel=self.detachSession;self.detachSession=nil;if(cancel)cancel();
    if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    [self publishMessage:error?:self.cancelled?@"Canceled.":self.stopped?@"Stopped. Playlist and added tracks were kept.":@"Playlist downloaded."];
    self.tracks=nil;self.baseline=nil;self.missing=nil;self.orderedTracks=nil;if(!self.stopped || self.submitted || self.resumeBlocked)self.releases=nil;
    SAPPlaylistScheduleTasks();
}
- (void)resolve {
    if(!self.active || self.stopped)return;
    if(self.index==self.releases.count){self.tracks=self.orderedTracks.array;self.index=0;[self save];return;}
    self.message=[NSString stringWithFormat:@"Reading selected release %lu / %lu…",(unsigned long)self.index+1,(unsigned long)self.releases.count];
    NSString *uri=self.releases[self.index][@"uri"];NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",SAPPlaylistString(1,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;NSString *reason=nil;NSArray *tracks=error?nil:SAPParseArtistAlbumTrackURIs(data,uri,&reason);
        SAP_JOURNAL_ACTION(@"playlist_release_tracks_read",@{@"operation":self.token,@"release_uri":uri,@"verified":@(tracks!=nil),@"track_count":@(tracks.count),@"reason":reason?:@"",@"error":tracks?@"":error?:reason?:@""});
        if(!tracks){[self finish:error?:[NSString stringWithFormat:@"Could not read all tracks of %@ (%@). No playlist changes were sent.",self.releases[self.index][@"name"]?:uri,reason?:@"missing metadata"]];return;}
        [self.orderedTracks addObjectsFromArray:tracks];if(self.orderedTracks.count>SAPPlaylistMaximumItems){[self finish:@"The selection exceeds 10,000 unique tracks. Choose fewer releases."];return;}
        self.releaseTracks[uri]=tracks;
        self.index++;[self resolve];
    });
}
- (void)verifyLibrary:(NSString *)uri attempt:(NSUInteger)attempt {
    if(!self.active || self.stopped)return;NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(SAPPlaylistLibraryService,@"Contains",SAPPlaylistString(3,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;NSArray *fields=SAPProtoFields(data);BOOL member=NO;
        if(fields && !error.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in SAPPlaylistMessages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)==1)member=YES;
        if(member){self.index++;[self save];return;}
        if(attempt>=5){[self finish:error?:@"Spotify did not confirm the selected release in Your Library. Playlist download was not started."];return;}
        self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MIN(5,attempt+1),^{self.retry=nil;if([self valid:epoch])[self verifyLibrary:uri attempt:attempt+1];});
    });
}
- (void)save {
    if(!self.active || self.stopped)return;
    if(self.index==self.releases.count){[self target];return;}
    NSString *uri=self.releases[self.index][@"uri"];NSUInteger epoch=self.epoch;
    self.message=[NSString stringWithFormat:@"Saving release %lu / %lu to Your Library…",(unsigned long)self.index+1,(unsigned long)self.releases.count];
    // Read membership first; save a missing album once, then verify read-only.
    self.cancelRead=SAPCallReadOnlyServiceCancellable(SAPPlaylistLibraryService,@"Contains",SAPPlaylistString(3,uri),^(NSData *data,NSString *failure){
        if(![self valid:epoch])return;self.cancelRead=nil;NSArray *fields=SAPProtoFields(data);NSNumber *member=nil;
        if(fields && !failure.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in SAPPlaylistMessages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)<=1)member=@(SAPProtoNumber(entry,2,0));
        if(!member){[self finish:failure?:@"Spotify did not return a valid library membership state."];return;}
        if(member.boolValue){self.index++;[self save];return;}
        self.commandPending=YES;SAPAddAlbumToLibraryOnce(uri,^(__unused NSData *reply,__unused NSString *error){
            if(!self.active || epoch!=self.epoch)return;self.commandPending=NO;
            if(self.stopped){[self finish:nil];return;}[self verifyLibrary:uri attempt:0];
        });
    });
}
- (void)target {
    if(!self.active || self.stopped)return;if(self.uri){[self readTarget];return;}
    self.message=@"Creating playlist…";NSUInteger epoch=self.epoch;self.commandPending=YES;
    NSMutableData *create=[SAPPlaylistString(1,@"create")mutableCopy];[create appendData:SAPPlaylistString(4,self.name)];[create appendData:SAPProtoInteger(5,1)];[create appendData:SAPProtoInteger(12,1)];
    SAPCallPlaylistModificationOnce(YES,SAPProtoBytes(2,create),^(NSData *data,NSString *error){
        if(!self.active || epoch!=self.epoch)return;self.commandPending=NO;
        NSArray *fields=SAPProtoFields(data),*response=SAPProtoFields(SAPProtoData(fields,2));NSString *uri=SAPProtoString(response,2),*failure=error;
        SAP_JOURNAL_ACTION(@"playlist_create_reply",@{@"operation":self.token,@"playlist_uri":uri?:@"",@"response_received":@(data!=nil),@"success_field":@(SAPProtoNumber(response,1,0)),@"error":error?:@"",@"automatic_replay":@NO});
        if(error.length || !SAPPlaylistStatusOK(fields,&failure) || !SAPProtoNumber(response,1,0) || !SAPIsPlaylistURI(uri)){
            self.resumeBlocked=YES;[self finish:failure?:@"Spotify did not confirm playlist creation. Check Your Library before retrying; the creation command was not repeated."];return;
        }
        self.uri=uri;if(self.stopped){[self finish:nil];return;}[self readTarget];
    });
}
- (void)readTarget {
    self.message=@"Reading playlist contents…";NSUInteger epoch=self.epoch;
    self.cancelRead=SAPPlaylistReadList(self.uri,^(NSDictionary *contents,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;
        if(!contents || ![contents[@"can_add"]boolValue]){[self finish:error?:@"Spotify does not allow adding tracks to this playlist."];return;}
        self.baseline=contents[@"items"];NSSet *existing=[NSSet setWithArray:self.baseline];NSMutableArray *missing=[NSMutableArray array];
        for(NSString *track in self.tracks)if(![existing containsObject:track])[missing addObject:track];self.missing=missing;
        if(self.baseline.count+self.missing.count>SAPPlaylistMaximumItems){[self finish:@"The destination playlist would exceed 10,000 items. Choose another playlist."];return;}
        self.offset=0;[self append];
    });
}
- (void)append {
    if(!self.active || self.stopped)return;
    if(self.offset==self.missing.count){
        if(!self.offset){[self submit];return;}
        self.message=@"Verifying playlist order…";NSUInteger epoch=self.epoch;
        self.cancelRead=SAPPlaylistReadList(self.uri,^(NSDictionary *contents,NSString *error){
            if(![self valid:epoch])return;self.cancelRead=nil;
            if(!contents || ![contents[@"items"]isEqual:[self.baseline arrayByAddingObjectsFromArray:self.missing]]){[self finish:error?:@"The playlist changed before download. Confirmed additions were kept; check its contents before retrying."];return;}[self submit];
        });return;
    }
    NSArray *batch=[self.missing subarrayWithRange:NSMakeRange(self.offset,MIN(100,self.missing.count-self.offset))];
    self.message=[NSString stringWithFormat:@"Adding tracks to %@… %lu / %lu",self.name?:@"playlist",(unsigned long)self.offset,(unsigned long)self.missing.count];
    NSMutableData *request=[SAPPlaylistString(1,@"add")mutableCopy];[request appendData:SAPPlaylistString(3,@"end")];for(NSString *uri in batch)[request appendData:SAPPlaylistString(7,uri)];
    NSMutableData *outer=[SAPPlaylistString(1,self.uri)mutableCopy];[outer appendData:SAPProtoBytes(2,request)];NSUInteger epoch=self.epoch;self.commandPending=YES;
    SAPCallPlaylistModificationOnce(NO,outer,^(NSData *data,NSString *error){
        if(!self.active || epoch!=self.epoch)return;self.commandPending=NO;
        if(self.stopped){[self finish:nil];return;}NSString *failure=error;BOOL confirmed=!error.length && SAPPlaylistStatusOK(SAPProtoFields(data),&failure);
        SAP_JOURNAL_ACTION(@"playlist_append_reply",@{@"operation":self.token,@"playlist_uri":self.uri,@"offset":@(self.offset),@"batch_count":@(batch.count),@"reply_confirmed":@(confirmed),@"error":failure?:@"",@"automatic_replay":@NO});
        // Even an ACK is not proof of membership. An ambiguous mutation is
        // verified once by reading; the append command is never replayed.
        self.cancelRead=SAPPlaylistReadListFrom(self.uri,self.baseline.count+self.offset,^(NSDictionary *contents,NSString *readError){
            if(![self valid:epoch])return;self.cancelRead=nil;
            SAP_JOURNAL_ACTION(@"playlist_append_verified",@{@"operation":self.token,@"playlist_uri":self.uri,@"offset":@(self.offset),@"expected_total":@(self.baseline.count+self.offset+batch.count),@"observed_total":contents[@"total"]?:@0,@"exact_tail_matches":@([contents[@"items"]isEqual:batch]),@"error":readError?:@""});
            if(!contents || [contents[@"total"]unsignedIntegerValue]!=self.baseline.count+self.offset+batch.count || ![contents[@"items"]isEqual:batch]){[self finish:readError?:confirmed?@"Spotify did not confirm the exact appended tracks and order. Existing additions were kept; download was not started.":failure?:@"The append result is uncertain. Check the playlist before retrying. The command was not repeated."];return;}
            self.offset+=batch.count;self.addedCount=self.offset;[self append];
        });
    });
}
- (void)submit {
    if(!self.active || self.stopped)return;self.submitted=YES;self.releases=nil;SAPPlaylistItemTaskRevision++;self.message=@"Waiting for Spotify…";
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    NSDictionary *context=@{@"uri":self.uri,@"name":self.name?:@"Playlist",@"category":@"Playlist",@"refresh_after_append":@(self.addedCount>0)};NSUInteger epoch=self.epoch;__weak typeof(self) weak=self;
    NSString *error=nil;if(!SAPAppendArtistDownloadSessionReleases(@[context],&error)){[self finish:error];return;}
    dispatch_block_t detach=SAPObserveArtistDownloadSession(@[context],^(NSDictionary *snapshot){
        typeof(self) s=weak;if(!s || !s.active || s.epoch!=epoch)return;s.contextState=snapshot[@"album_states"][s.uri];
        NSString *phase=s.contextState[@"phase"],*failure=s.contextState[@"error"];
        if([s.contextState[@"state"]isEqual:@"downloaded"]){[s finish:nil];return;}
        if([phase isEqual:@"failed"]){[s finish:failure?:@"Spotify could not download the playlist."];return;}
        if(s.stopped && ![s.contextState[@"active"]boolValue] && ![s.contextState[@"stop_pending"]boolValue]){[s finish:nil];return;}
        NSString *downloading=[s.contextState[@"total_tracks"]unsignedIntegerValue]?[NSString stringWithFormat:@"Downloading %@… %@ / %@ tracks",s.name?:@"playlist",s.contextState[@"downloaded_tracks"],s.contextState[@"total_tracks"]]:[NSString stringWithFormat:@"Downloading %@…",s.name?:@"playlist"];
        [s publishMessage:s.stopped?@"Stopping…":[phase isEqual:@"downloading"]?downloading:[phase isEqual:@"queued"]?@"Playlist queued":@"Waiting for Spotify…"];
    });
    if(self.active && self.epoch==epoch)self.detachSession=detach;else if(detach)detach();
    SAPPlaylistScheduleTasks();
}
- (void)stop {
    if(!self.active || self.stopped)return;self.stoppedVisuals=SAPPlaylistCaptureStoppedVisuals(self.sourceURIs);self.stopped=YES;SAPPlaylistItemTaskRevision++;self.message=@"Stopping…";
    if(self.submitted && !self.queued){SAPStopArtistDownloadSessionRelease(self.uri);return;}
    if(!self.commandPending)[self finish:nil];
}
- (BOOL)isQueuedRelease:(NSString *)uri {return NO;}
- (void)cancel {self.cancelled=YES;[self stop];self.resumeBlocked=YES;self.stoppedVisuals=nil;self.releases=nil;SAPPlaylistItemTaskRevision++;SAPPlaylistPublishTasks();}

@end
