#import "PlaylistDownloadsInternal.h"

// Single process-local registry, shared by task workflows and observations.
NSMutableArray<SAPPlaylistDownloadTask *> *SAPPlaylistTasks;
NSMutableDictionary *SAPPlaylistObservers,*SAPPlaylistObserverURIs,*SAPPlaylistObserverSnapshots,*SAPPlaylistObserverArtists;
NSUInteger SAPPlaylistItemTaskRevision=1,SAPPlaylistItemScopeRevision=1;

void SAPPlaylistEnsureState(void){if(!SAPPlaylistTasks)SAPPlaylistTasks=[NSMutableArray array];if(!SAPPlaylistObservers)SAPPlaylistObservers=[NSMutableDictionary dictionary];if(!SAPPlaylistObserverURIs)SAPPlaylistObserverURIs=[NSMutableDictionary dictionary];if(!SAPPlaylistObserverSnapshots)SAPPlaylistObserverSnapshots=[NSMutableDictionary dictionary];if(!SAPPlaylistObserverArtists)SAPPlaylistObserverArtists=[NSMutableDictionary dictionary];}
static NSSet *releaseURIs(NSArray *releases){NSMutableSet *uris=[NSMutableSet set];for(NSDictionary *r in releases)if(SAPIsAlbumURI(r[@"uri"]))[uris addObject:r[@"uri"]];return uris;}
void SAPPlaylistPublishTasks(void){
    SAPPlaylistReconcileItemObservers();
    for(NSString *token in [SAPPlaylistObservers.allKeys copy]){
        NSSet *scope=SAPPlaylistObserverURIs[token];BOOL active=NO,resumable=NO;NSMutableArray *summaries=[NSMutableArray array];
        for(SAPPlaylistDownloadTask *task in SAPPlaylistTasks)if(SAPPlaylistObserverArtists[token]?[task.artistURI isEqual:SAPPlaylistObserverArtists[token]]:[task.sourceURIs intersectsSet:scope]){active|=task.active&&!task.cancelled;resumable|=task.stopped&&!task.active&&!task.resumeBlocked&&!task.cancelled;[summaries addObject:@{@"id":task.token,@"active":@(task.active&&!task.cancelled),@"artist_uri":task.artistURI?:@"",@"cancelled":@(task.cancelled),@"queued":@(task.queued),@"submitted":@(task.submitted),@"can_continue":@(task.stopped&&!task.active&&!task.resumeBlocked&&!task.cancelled),@"release_uris":task.sourceURIList,@"playlist_name":task.name?:@"Playlist",@"playlist_uri":task.uri?:@"",@"message":task.message?:@"",@"error":task.error?:@"",@"stopped_visuals":task.stoppedVisuals?:@{},@"context_state":task.contextState?:@{}}];}
        NSDictionary *snapshot=@{@"active":@(active),@"can_continue":@(resumable),@"can_cancel":@(active||resumable),@"jobs":summaries};
        if(![SAPPlaylistObserverSnapshots[token]isEqual:snapshot]){SAPPlaylistObserverSnapshots[token]=snapshot;void (^reply)(NSDictionary *)=SAPPlaylistObservers[token];if(reply)reply(snapshot);}
    }
}
// Serialize preparation and each destination's mutations, but keep a busy
// destination from blocking a ready operation for another playlist.
void SAPPlaylistScheduleTasks(void){
    static BOOL scheduled=NO;if(scheduled)return;scheduled=YES;
    dispatch_async(dispatch_get_main_queue(),^{
        scheduled=NO;
        for(SAPPlaylistDownloadTask *task in SAPPlaylistTasks)if(task.active&&!task.queued&&!task.submitted)return;
        for(SAPPlaylistDownloadTask *task in [SAPPlaylistTasks copy])if(task.active&&task.queued&&!task.stopped){
            BOOL blocked=NO;
            if(task.uri)for(SAPPlaylistDownloadTask *other in SAPPlaylistTasks)if(other!=task && other.active&&!other.queued && [other.uri isEqual:task.uri]){blocked=YES;break;}
            if(!blocked){[task begin];return;}
        }
    });
}
static BOOL startPlaylist(NSString *artist,NSArray *releases,NSString *playlistURI,NSString *newName,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Playlist actions belong to main");SAPPlaylistEnsureState();
    if(![releases isKindOfClass:NSArray.class] || (newName && ![newName isKindOfClass:NSString.class])){if(error)*error=@"Invalid playlist selection or name.";return NO;}
    NSString *name=[newName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!releases.count || releases.count>4096 || (playlistURI && !SAPIsPlaylistURI(playlistURI)) || (!playlistURI && (!name.length || name.length>200))){if(error)*error=@"Choose releases and a valid playlist or a name up to 200 characters.";return NO;}
    for(NSDictionary *r in releases)if(![r isKindOfClass:NSDictionary.class] || !SAPIsAlbumURI(r[@"uri"])){if(error)*error=@"The selection contains an invalid release.";return NO;}
    while(SAPPlaylistTasks.count>=32){NSUInteger index=[SAPPlaylistTasks indexOfObjectPassingTest:^BOOL(SAPPlaylistDownloadTask *t,NSUInteger i,BOOL *stop){return !t.active;}];if(index==NSNotFound){if(error)*error=@"Too many active playlist operations.";return NO;}[SAPPlaylistTasks removeObjectAtIndex:index];SAPPlaylistItemTaskRevision++;}
    SAPPlaylistDownloadTask *task=artist?[SAPIncrementalPlaylistTask new]:[SAPPlaylistDownloadTask new];task.artistURI=artist;task.token=NSUUID.UUID.UUIDString;task.uri=playlistURI;task.name=name;NSMutableArray *intent=[NSMutableArray arrayWithCapacity:releases.count];for(NSDictionary *release in releases)[intent addObject:@{@"uri":release[@"uri"],@"name":release[@"name"]?:@"Release"}];task.releases=intent;task.sourceURIs=releaseURIs(releases);task.sourceURIList=[task.sourceURIs.allObjects sortedArrayUsingSelector:@selector(compare:)];task.orderedTracks=[NSMutableOrderedSet orderedSet];task.releaseTracks=[NSMutableDictionary dictionary];task.active=YES;task.queued=YES;if(![task reserve:error])return NO;[SAPPlaylistTasks addObject:task];
    task.message=[NSString stringWithFormat:@"Queued: %@",name?:@"playlist"];
    SAP_JOURNAL_ACTION(@"playlist_queue_accepted",@{@"operation":task.token,@"playlist_uri":playlistURI?:@"",@"release_count":@(task.sourceURIs.count),@"queued_operations":@([[SAPPlaylistTasks filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SAPPlaylistDownloadTask *entry,NSDictionary *bindings){return entry.active&&entry.queued;}]]count])});
    SAPPlaylistScheduleTasks();return YES;
}
BOOL SAPStartPlaylistReleaseDownload(NSArray *releases,NSString *uri,NSString *name,NSString **error){return startPlaylist(nil,releases,uri,name,error);}
BOOL SAPStartPlaylistReleaseDownloadForArtist(NSString *artist,NSArray *releases,NSString *uri,NSString *name,NSString **error){if(![artist isKindOfClass:NSString.class] || !artist.length){if(error)*error=@"Artist identity is unavailable.";return NO;}return startPlaylist(artist,releases,uri,name,error);}
static dispatch_block_t observePlaylists(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){
    NSCAssert(NSThread.isMainThread,@"Playlist observation belongs to main");SAPPlaylistEnsureState();NSString *token=NSUUID.UUID.UUIDString;
    SAPPlaylistObserverURIs[token]=releaseURIs(releases);if(artist)SAPPlaylistObserverArtists[token]=artist;if(completion)SAPPlaylistObservers[token]=[completion copy];SAPPlaylistPublishTasks();__block BOOL detached=NO;
    return ^{if(detached)return;detached=YES;[SAPPlaylistObservers removeObjectForKey:token];[SAPPlaylistObserverURIs removeObjectForKey:token];[SAPPlaylistObserverSnapshots removeObjectForKey:token];[SAPPlaylistObserverArtists removeObjectForKey:token];};
}
dispatch_block_t SAPObservePlaylistReleaseDownloads(NSArray *releases,void (^completion)(NSDictionary *)){return observePlaylists(nil,releases,completion);}
dispatch_block_t SAPObservePlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){return observePlaylists(artist,releases,completion);}
static BOOL continuePlaylists(NSString *artist,NSArray *releases,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Playlist Continue belongs to main");NSSet *scope=releaseURIs(releases);
    for(SAPPlaylistDownloadTask *task in [SAPPlaylistTasks copy])if(task.stopped&&!task.cancelled&&!task.active&&!task.resumeBlocked && (artist?[task.artistURI isEqual:artist]:[task.sourceURIs intersectsSet:scope])){
        if(![task reserve:error])return NO;
        task.stopped=NO;task.active=YES;task.queued=YES;SAPPlaylistItemTaskRevision++;task.error=nil;task.contextState=nil;task.stoppedVisuals=nil;
        SAP_JOURNAL_ACTION(@"playlist_continue_requested",@{@"operation":task.token,@"playlist_uri":task.uri?:@"",@"resume_existing_context":@(task.submitted),@"replay_creation":@NO});
        task.message=@"Queued to continue…";
    }
    SAPPlaylistPublishTasks();SAPPlaylistScheduleTasks();return YES;
}
BOOL SAPContinuePlaylistReleaseDownloads(NSArray *releases,NSString **error){return continuePlaylists(nil,releases,error);}
BOOL SAPContinuePlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases,NSString **error){return continuePlaylists(artist,releases,error);}
void SAPCancelPlaylistReleaseDownloadsForArtist(NSString *artist){if(!artist.length)return;for(SAPPlaylistDownloadTask *task in [SAPPlaylistTasks copy])if([task.artistURI isEqual:artist] && !task.cancelled && (task.active||task.stopped))[task cancel];}
void SAPStopPlaylistReleaseDownloads(NSArray *releases){
    NSCAssert(NSThread.isMainThread,@"Playlist actions belong to main");NSSet *scope=releaseURIs(releases);
    if(SAPDiagnosticsEnabled())SAP_JOURNAL_ACTION(@"playlist_stop_requested",@{@"caller":@"SAPStopPlaylistReleaseDownloads",@"requested_reason":@"legacy_release_scope",@"release_uris":[scope.allObjects sortedArrayUsingSelector:@selector(compare:)],@"call_stack":NSThread.callStackSymbols});
    for(SAPPlaylistDownloadTask *task in [SAPPlaylistTasks copy])if([task.sourceURIs intersectsSet:scope])[task stopRequestedBy:@"SAPStopPlaylistReleaseDownloads" reason:@"legacy_release_scope"];
}
void SAPStopPlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases){
    NSCAssert(NSThread.isMainThread,@"Playlist actions belong to main");if(!artist.length)return;NSSet *scope=releases?releaseURIs(releases):nil;
    NSString *reason=scope?@"artist_release_scope":@"artist_all_tasks";
    if(SAPDiagnosticsEnabled())SAP_JOURNAL_ACTION(@"playlist_stop_requested",@{@"artist_uri":artist,@"caller":@"SAPStopPlaylistReleaseDownloadsForArtist",@"requested_reason":reason,@"release_uris":scope?[scope.allObjects sortedArrayUsingSelector:@selector(compare:)]:@[],@"call_stack":NSThread.callStackSymbols});
    for(SAPPlaylistDownloadTask *task in [SAPPlaylistTasks copy])if([task.artistURI isEqual:artist] && (!scope || [task.sourceURIs intersectsSet:scope]))[task stopRequestedBy:@"SAPStopPlaylistReleaseDownloadsForArtist" reason:reason];
}


#ifdef SAP_TESTING
void SAPPlaylistForgetInactiveMembershipForTesting(void){
    for(SAPPlaylistDownloadTask *task in SAPPlaylistTasks)if(!task.active)[task.releaseTracks removeAllObjects];SAPPlaylistItemTaskRevision++;SAPPlaylistReconcileItemObservers();
}
#endif
