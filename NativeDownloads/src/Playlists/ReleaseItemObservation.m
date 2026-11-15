#import "PlaylistDownloadsInternal.h"

@interface SAPReleaseItemObservation ()
@property(nonatomic,strong) NSMutableSet *scope,*dirtyMemberships;
@property(nonatomic,strong) NSMutableDictionary *membership;
@property(nonatomic,strong) NSDictionary *flags,*taskMembership;
@property(nonatomic,strong) NSMutableDictionary *catalogMembership;
@property(nonatomic,strong) NSMutableSet *subscribedTracks;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSMutableDictionary *items,*states,*reverseIndex,*observationErrors;
@property(nonatomic,strong) NSMutableArray *cancellations;
@property(nonatomic,strong) dispatch_queue_t decodeQueue;
@property(nonatomic,copy) void (^completion)(NSDictionary *);
@property(nonatomic) NSUInteger generation,seenTaskRevision;
@property(nonatomic) BOOL detached,scopeDirty;
#ifdef SAP_TESTING
@property(nonatomic) NSUInteger validationWork,indexWork;
#endif
- (void)reconcile;
- (void)invalidate;
- (void)renderReleases:(NSSet *)uris;
@end
static NSMutableDictionary<NSString *,SAPReleaseItemObservation *> *itemObservers;
@implementation SAPReleaseItemObservation
- (void)invalidate {
    if(self.detached)return;self.detached=YES;[itemObservers removeObjectForKey:self.token];SAPPlaylistItemScopeRevision++;self.generation++;for(dispatch_block_t cancel in self.cancellations)cancel();[self.cancellations removeAllObjects];self.completion=nil;self.items=nil;self.states=nil;self.membership=nil;self.catalogMembership=nil;self.taskMembership=nil;self.reverseIndex=nil;self.observationErrors=nil;self.subscribedTracks=nil;self.scope=nil;[self.dirtyMemberships removeAllObjects];SAPPlaylistReconcileItemObservers();
}
- (void)renderReleases:(NSSet *)uris {
    BOOL changed=NO;
    for(NSString *uri in uris){
        NSArray *tracks=self.membership[uri];if(!tracks){if(self.states[uri]){[self.states removeObjectForKey:uri];changed=YES;}continue;}NSUInteger done=0,known=0;BOOL downloading=NO,failed=NO,pending=NO;double singleProgress=0;NSString *observationError=nil;
        for(NSString *track in tracks){if(self.observationErrors[track])observationError=self.observationErrors[track];NSDictionary *item=self.items[track];if(!item)continue;known++;NSUInteger code=[item[@"code"]unsignedIntegerValue];done+=code==3;downloading|=code==5;pending|=code==4||code==5||code==6;failed|=code==1||code==7;if(tracks.count==1 && code==5)singleProgress=[item[@"percent"]doubleValue]/100.;}
        BOOL full=tracks.count>0&&known==tracks.count&&done==tracks.count,owned=[self.flags[uri][@"active"]boolValue],stopping=[self.flags[uri][@"stopping"]boolValue];
        NSString *phase=full?@"downloaded":stopping?@"stopping":observationError?@"unknown":failed?@"failed":downloading?@"downloading":owned&&[self.flags[uri][@"queued"]boolValue]?@"queued":owned||pending?@"waiting":@"idle";
        NSString *kind=full?@"downloaded":observationError?@"unknown":done||owned||pending?@"partial":known==tracks.count?@"not_downloaded":@"unknown";
        NSDictionary *state=@{@"state":kind,@"phase":phase,@"stopping":@(stopping&&!full),@"can_continue":@(!full&&[self.flags[uri][@"can_continue"]boolValue]),@"stopped_visual":self.flags[uri][@"stopped_visual"]?:@{},@"active":@(owned&&!full),@"progress":@(full?1:tracks.count==1?singleProgress:tracks.count?(double)done/tracks.count:0),@"downloaded_tracks":@(done),@"total_tracks":@(tracks.count),@"known_tracks":@(known),@"playlist_download":@(self.flags[uri]!=nil),@"playlist_uri":self.flags[uri][@"uri"]?:@"",@"playlist_name":self.flags[uri][@"name"]?:@"Playlist",@"download_source":@"native_items",@"error":observationError?:failed?@"Spotify reported a track error or waiting limit.":@""};
        if(![self.states[uri]isEqual:state]){self.states[uri]=state;changed=YES;}
    }
    if(changed && self.completion)self.completion(@{@"album_states":[self.states copy]});
}
- (void)updateReleases:(NSArray *)releases {
    NSCAssert(NSThread.isMainThread,@"Item membership belongs to main");if(self.detached)return;
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];if(!SAPIsAlbumURI(uri))continue;
        if(![self.scope containsObject:uri]){[self.scope addObject:uri];self.scopeDirty=YES;SAPPlaylistItemScopeRevision++;}
        NSArray *tracks=release[@"track_uris"];if(![release[@"track_count_verified"]boolValue] || ![tracks isKindOfClass:NSArray.class] || !tracks.count || tracks.count>4096)continue;
        NSArray *previous=self.catalogMembership[uri];if(previous==tracks || [previous isEqual:tracks])continue;
#ifdef SAP_TESTING
        self.validationWork+=tracks.count;
#endif
        BOOL valid=YES;NSMutableSet *unique=[NSMutableSet set];for(id track in tracks){if(![track isKindOfClass:NSString.class] || ![track hasPrefix:@"spotify:track:"] || [track length]!=36){valid=NO;break;}[unique addObject:track];}
        if(valid && unique.count==tracks.count){self.catalogMembership[uri]=[tracks copy];[self.dirtyMemberships addObject:uri];}
    }
    [self reconcile];
}
- (void)reconcile {
    if(self.detached)return;NSMutableSet *affected=[NSMutableSet set];
    if(self.scopeDirty || self.seenTaskRevision!=SAPPlaylistItemTaskRevision){
        self.scopeDirty=NO;self.seenTaskRevision=SAPPlaylistItemTaskRevision;NSMutableDictionary *fallback=[NSMutableDictionary dictionary],*flags=[NSMutableDictionary dictionary];
        for(SAPPlaylistDownloadTask *task in [SAPPlaylistTasks reverseObjectEnumerator])if(task.submitted)for(NSString *uri in task.sourceURIs)if([self.scope containsObject:uri]){
            if(!fallback[uri] && [task.releaseTracks[uri]count])fallback[uri]=task.releaseTracks[uri];
            if(task.cancelled || (!task.active&&!task.stopped) || (flags[uri] && (!task.active || [flags[uri][@"active"]boolValue])))continue;
            flags[uri]=@{@"active":@(task.active),@"queued":@([task isQueuedRelease:uri]),@"stopping":@(task.active&&task.stopped),@"can_continue":@(task.stopped&&!task.active&&!task.resumeBlocked&&!task.cancelled),@"stopped_visual":task.stopped?task.stoppedVisuals[uri]?:@{}:@{},@"uri":task.uri?:@"",@"name":task.name?:@"Playlist"};
        }
        NSMutableSet *sources=[NSMutableSet setWithArray:self.taskMembership.allKeys?:@[]];[sources addObjectsFromArray:fallback.allKeys];
        for(NSString *uri in sources)if(!self.catalogMembership[uri] && ![self.taskMembership[uri]isEqual:fallback[uri]])[self.dirtyMemberships addObject:uri];
        self.taskMembership=fallback;
        sources=[NSMutableSet setWithArray:self.flags.allKeys?:@[]];[sources addObjectsFromArray:flags.allKeys];for(NSString *uri in sources)if(![self.flags[uri]isEqual:flags[uri]])[affected addObject:uri];self.flags=flags;
    }
    NSMutableOrderedSet *all=[NSMutableOrderedSet orderedSet];
    for(NSString *uri in self.dirtyMemberships){NSArray *old=self.membership[uri],*tracks=self.catalogMembership[uri]?:self.taskMembership[uri];if(old==tracks || [old isEqual:tracks])continue;
#ifdef SAP_TESTING
        self.indexWork+=old.count+tracks.count;
#endif
        for(NSString *track in old){NSMutableSet *sources=self.reverseIndex[track];[sources removeObject:uri];if(!sources.count)[self.reverseIndex removeObjectForKey:track];}
        if(tracks)self.membership[uri]=tracks;else[self.membership removeObjectForKey:uri];
        for(NSString *track in tracks){NSMutableSet *sources=self.reverseIndex[track];if(!sources)self.reverseIndex[track]=sources=[NSMutableSet set];[sources addObject:uri];if(![self.subscribedTracks containsObject:track])[all addObject:track];}
        [affected addObject:uri];
    }
    [self.dirtyMemberships removeAllObjects];[self.subscribedTracks addObjectsFromArray:all.array];NSUInteger generation=self.generation;
    [self renderReleases:affected];if(self.detached)return;
    // Reserve identities before delivering callbacks; extending a catalog never
    // rebuilds existing links or replaces a healthy native item stream.
    NSArray *uris=all.array;__weak typeof(self) weak=self;dispatch_queue_t decodeQueue=self.decodeQueue;
    for(NSUInteger offset=0;offset<uris.count;offset+=256){
        NSArray *chunk=[uris subarrayWithRange:NSMakeRange(offset,MIN(256,uris.count-offset))];NSSet *requested=[NSSet setWithArray:chunk];NSMutableData *payload=[NSMutableData data];for(NSString *uri in chunk)[payload appendData:SAPPlaylistString(1,uri)];
        dispatch_block_t cancel=SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"SubscribeItems",payload,^(NSData *data,NSString *error){
            // Preserve native event order while decoding away from UIKit.
            dispatch_async(decodeQueue,^{
                NSArray *fields=error?nil:SAPProtoFields(data);NSMutableDictionary *updates=[NSMutableDictionary dictionary];
                if(fields)for(NSArray *item in SAPPlaylistMessages(fields,1)){NSString *uri=SAPProtoString(item,1);uint64_t code=SAPProtoNumber(item,2,0);if([requested containsObject:uri] && code<=7)updates[uri]=@{@"code":@(code),@"percent":@(MIN(100,SAPProtoNumber(item,4,0)))};}
                dispatch_async(dispatch_get_main_queue(),^{
                    typeof(self) observer=weak;if(!observer || observer.detached || observer.generation!=generation)return;NSMutableSet *affected=[NSMutableSet set];
                    if(!fields){for(NSString *track in requested){[observer.items removeObjectForKey:track];observer.observationErrors[track]=error?:@"Invalid native item response";[affected unionSet:observer.reverseIndex[track]?:[NSSet set]];}SAP_JOURNAL_ACTION(@"playlist_item_observation_failed",@{@"tracks":@(requested.count),@"error":error?:@"Invalid native item response"});}
                    for(NSString *track in updates)if(![observer.items[track]isEqual:updates[track]]){observer.items[track]=updates[track];[observer.observationErrors removeObjectForKey:track];[affected unionSet:observer.reverseIndex[track]?:[NSSet set]];}
                    [observer renderReleases:affected];
                });
            });
        });
        if(cancel)[self.cancellations addObject:cancel];
    }
}
@end
NSDictionary *SAPPlaylistCaptureStoppedVisuals(NSSet *scope){
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *uri in scope){NSDictionary *last=nil;
        for(SAPReleaseItemObservation *observer in itemObservers.allValues){NSDictionary *candidate=observer.states[uri];if(candidate && (!last || [candidate[@"known_tracks"]unsignedIntegerValue]>[last[@"known_tracks"]unsignedIntegerValue]))last=candidate;}
        result[uri]=@{@"progress":last[@"progress"]?:@0,@"downloaded_tracks":last[@"downloaded_tracks"]?:@0,@"total_tracks":last[@"total_tracks"]?:@0};
    }
    return result;
}
void SAPPlaylistReconcileItemObservers(void){
    static NSUInteger lastTasks=0,lastScopes=0;
    if(lastTasks==SAPPlaylistItemTaskRevision && lastScopes==SAPPlaylistItemScopeRevision)return;
    // Keep recent completed membership bounded; visible rows and active jobs
    // retain the exact track identities needed for their live item stream.
    NSUInteger retained=0;
    for(SAPPlaylistDownloadTask *task in [SAPPlaylistTasks reverseObjectEnumerator]){
        NSUInteger references=0;for(NSArray *tracks in task.releaseTracks.allValues)references+=tracks.count;
        BOOL visible=NO;for(SAPReleaseItemObservation *observer in itemObservers.allValues)if([observer.scope intersectsSet:task.sourceURIs]){visible=YES;break;}
        if(!task.active&&!visible && retained+references>16384 && references){[task.releaseTracks removeAllObjects];SAPPlaylistItemTaskRevision++;}else if(!task.active)retained+=references;
    }
    lastTasks=SAPPlaylistItemTaskRevision;lastScopes=SAPPlaylistItemScopeRevision;
    for(SAPReleaseItemObservation *observer in [itemObservers.allValues copy])[observer reconcile];
}
SAPReleaseItemObservation *SAPObserveReleaseItems(NSArray *releases,void (^completion)(NSDictionary *)){
    NSCAssert(NSThread.isMainThread,@"Item observations belong to main");SAPPlaylistEnsureState();if(!itemObservers)itemObservers=[NSMutableDictionary dictionary];
    SAPReleaseItemObservation *observer=[SAPReleaseItemObservation new];observer.token=NSUUID.UUID.UUIDString;observer.scope=[NSMutableSet set];observer.dirtyMemberships=[NSMutableSet set];observer.membership=[NSMutableDictionary dictionary];observer.reverseIndex=[NSMutableDictionary dictionary];SAPPlaylistItemScopeRevision++;observer.completion=completion;observer.catalogMembership=[NSMutableDictionary dictionary];observer.subscribedTracks=[NSMutableSet set];observer.items=[NSMutableDictionary dictionary];observer.states=[NSMutableDictionary dictionary];observer.observationErrors=[NSMutableDictionary dictionary];observer.cancellations=[NSMutableArray array];observer.decodeQueue=dispatch_queue_create("local.pixie.native-item-decode",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));itemObservers[observer.token]=observer;[observer updateReleases:releases];return observer;
}
dispatch_block_t SAPObservePlaylistReleaseItems(NSArray *releases,void (^completion)(NSDictionary *)){
    SAPReleaseItemObservation *observer=SAPObserveReleaseItems(releases,completion);return ^{[observer invalidate];SAPPlaylistReconcileItemObservers();};
}

