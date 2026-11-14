#import "ArtistSessionPrivate.h"
#import "DownloadEvidence.h"

@implementation SAPArtistDownloadSession (State)
- (NSMutableDictionary *)stateFor:(NSString *)uri {
    NSMutableDictionary *state=self.states[uri];if(!state) {state=[NSMutableDictionary dictionary];self.states[uri]=state;}[self noteCacheTouch:uri];return state;
}
- (void)noteCacheTouch:(NSString *)uri {
    [self.pendingCacheTouches removeObject:uri];[self.pendingCacheTouches addObject:uri];
}
- (BOOL)isProtectedFromCache:(NSString *)uri {
    NSDictionary *raw=self.states[uri];
    if([self.queuedURIs containsObject:uri])return YES;
    if([self.observedURIRefCounts[uri]unsignedIntegerValue] || [self.initialReadURICounts[uri]unsignedIntegerValue] || [self.stopOperations containsObject:uri] || self.operations[uri]!=nil)return YES;
    return [raw[@"local_active"]boolValue] || activeNative(raw) || [raw[@"stopping"]boolValue];
}
- (void)refreshCacheTouches {
    for(NSString *uri in self.pendingCacheTouches) {
        [self.inactiveStateLRU removeObject:uri];
        if(self.states[uri] && ![self isProtectedFromCache:uri])[self.inactiveStateLRU addObject:uri];
    }
    [self.pendingCacheTouches removeAllObjects];
}
- (void)trimInactiveStates {
    [self refreshCacheTouches];
    while(self.inactiveStateLRU.count>inactiveStateCacheLimit) {
        NSString *uri=self.inactiveStateLRU.firstObject;[self.inactiveStateLRU removeObjectAtIndex:0];
        if(![self isProtectedFromCache:uri])[self.states removeObjectForKey:uri];
    }
}
- (NSDictionary *)publicState:(NSDictionary *)raw {
    SAPDownloadContextEvidence evidence=SAPReadDownloadContextEvidence(raw);
    BOOL full=evidence.downloaded,validTotals=evidence.trustedTotals;
    double progress=evidence.progress;
    BOOL active=[raw[@"local_active"]boolValue] || evidence.nativeActive || [raw[@"stopping"]boolValue];
    NSString *phase=full?@"downloaded":[raw[@"stopping"]boolValue]?@"stopping":[raw[@"native_downloading"]boolValue]?@"downloading":raw[@"local_phase"];
    if([phase isEqual:@"idle"] && active)phase=@"waiting";
    if(!phase.length)phase=active?@"waiting":[raw[@"error"]length]?@"failed":@"idle";
    NSString *state=full?@"downloaded":progress>0 || active?@"partial":raw[@"native_state"]?@"not_downloaded":@"unknown";
    return @{@"state":state,@"phase":phase,@"active":@(active&&!full),@"stopping":raw[@"stopping"]?:@NO,@"progress":@(full?1:MIN(1,MAX(0,progress))),
        @"downloaded_tracks":validTotals?raw[@"downloaded"]:@0,@"total_tracks":validTotals?raw[@"total"]:@0,@"error":raw[@"error"]?:@"",
        @"native_cancelled":raw[@"native_cancelled"]?:@NO,@"native_ended":@([raw[@"native_cancelled"]boolValue] || [raw[@"native_state"]isEqual:@1]),@"reserved":raw[@"reserved"]?:@NO,@"native_downloading":raw[@"native_downloading"]?:@NO,@"queued_tracks":raw[@"queued_tracks"]?:@0,@"queued_bytes":raw[@"queued_bytes"]?:@0,@"downloaded_bytes":raw[@"downloaded_bytes"]?:@0};
}
- (void)publish {
    [self trimInactiveStates];
    BOOL globalActive=self.operations.count>0 || self.queue.count>0;
    if(!globalActive)for(NSDictionary *raw in self.states.allValues)if([[self publicState:raw][@"active"]boolValue]){globalActive=YES;break;}
    NSDictionary *observers=[self.observers copy],*observerURIs=[self.observerURIs copy];
    for(NSString *token in observers) {
        NSString *artist=self.observerArtists[token];BOOL hasOwner=NO;if(artist)for(id key in self.artistContexts)if([ownerArtist(key)isEqual:artist] && [self.artistContexts[key]count]){hasOwner=YES;break;}NSMutableDictionary *values=[NSMutableDictionary dictionary];BOOL active=NO,submitting=NO,resumable=NO;
        for(NSString *uri in observerURIs[token]) {
            NSDictionary *raw=self.states[uri];if(!raw)continue;NSMutableDictionary *value=[[self publicState:raw]mutableCopy];
            if([value[@"state"]isEqual:@"downloaded"]){[self.stoppedItems removeObjectForKey:uri];[self.stoppedOrder removeObject:uri];if(!self.operations[uri] && ![self.queuedURIs containsObject:uri])[self clearOwners:uri];}
            value[@"stop_pending"]=@(self.stopTokens[uri]!=nil || [self.stopOperations containsObject:uri] || (self.operations[uri] && self.operations[uri].stopped));
            if(self.stoppedItems[uri][@"stopped_visual"])value[@"stopped_visual"]=self.stoppedItems[uri][@"stopped_visual"];
            value[@"owned"]=@(self.operations[uri]!=nil);value[@"download_submitted"]=@(self.operations[uri].downloadSent);value[@"submission_pending"]=@(self.operations[uri].commandPending);
            value[@"can_continue"]=@(self.stoppedItems[uri]!=nil && (!artist || [self.contextOwners[uri]containsObject:artist]) && ![value[@"active"]boolValue] && !self.operations[uri] && ![self.stopOperations containsObject:uri]);values[uri]=value;resumable|=[value[@"can_continue"]boolValue];
            active|=[value[@"active"]boolValue];submitting|=[raw[@"local_active"]boolValue];
        }
        void (^observer)(NSDictionary *)=observers[token];
        observer(@{@"album_states":values,@"active":@(active),@"global_active":@(globalActive),@"can_continue":@(resumable),@"can_cancel":@(artist?hasOwner:active||resumable),@"submitting":@(submitting),@"error":self.error?:@""});
    }
    [self startWatch];
}
- (void)rememberStopped:(NSDictionary *)item {
    NSString *uri=item[@"uri"];if(!uri || [self.abandonedURIs containsObject:uri] || [self.states[uri][@"native_state"]isEqual:@3])return;
    NSMutableDictionary *intent=[NSMutableDictionary dictionary];for(NSString *key in @[@"uri",@"name",@"category",@"type",@"artist_uri",@"owner_token",@"track_count_verified",@"verified_track_count"])if(item[key])intent[key]=item[key];
    NSDictionary *last=[self publicState:self.states[uri]];
    // A presentation snapshot is never used as evidence of available files.
    intent[@"stopped_visual"]=self.stoppedItems[uri][@"stopped_visual"]?:@{@"progress":last[@"progress"]?:@0,@"downloaded_tracks":last[@"downloaded_tracks"]?:@0,@"total_tracks":last[@"total_tracks"]?:@0};
    self.stoppedItems[uri]=intent;[self.stoppedOrder addObject:uri];
    while(self.stoppedOrder.count>4096){NSString *old=self.stoppedOrder.firstObject;[self.stoppedItems removeObjectForKey:old];[self.stoppedOrder removeObject:old];if(!self.operations[old])[self clearOwners:old];}
}
@end
