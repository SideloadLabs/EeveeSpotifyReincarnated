#import <Foundation/Foundation.h>
#import "ArtistDownloadSession.h"
#import "TrackDownload.h"
#import "WireProto.h"
#include <assert.h>
#ifdef SAP_TESTING
void SAPArtistSessionSetWorkTimeoutForTesting(double seconds);
void SAPArtistSessionSetRepairTimeoutForTesting(double seconds);
void SAPArtistSessionSetRecoverySettleForTesting(double seconds);
void SAPArtistSessionSetDirectAlbumSubmissionForTesting(BOOL enabled);
#endif

// Fixture transport. AddDownload and RemoveDownload replies are held so each
// race can be driven explicitly by the test instead of timing the fake server.
static NSMutableDictionary *native,*members,*contexts,*progressStreams,*contextRequests;
static NSMutableArray *sent,*streamCancels,*heldContains,*heldInitialReads,*readURIs;
static NSMutableDictionary *addReplies,*removeReplies;
static NSMutableArray *addSubmissionOrder,*heldPreparations;
static NSMutableSet *submittedUnfinishedURIs;
static NSUInteger peakSubmittedUnfinished;
// The ordered-window suite keeps its original bounds; the direct suite raises them.
static NSUInteger fixtureSubmittedLimit=2,fixtureNativeContextLimit=2,entityReads;
static NSString *neverInvokedURI,*neverInvokedRemoveURI;
static NSMutableDictionary *terminalCounts;
static NSDictionary *snapshot;
static NSUInteger reads,streamStarts;
static BOOL holdContains,holdPrepare,holdCatalogReads;
static BOOL autoStreamResponses,holdStreamResponses,failContextReads;
static NSMutableArray *heldStreamResponses,*streamLeaseEvents;
static NSMutableArray *repairJournal;
static NSMutableDictionary *progressSnapshots;
static BOOL holdNextContextRead;
static dispatch_block_t heldVerificationRead;
static NSDictionary *initialReadStates;
static NSMutableArray *nativeDefaultContexts;
static NSMutableDictionary *verifiedFixtureTrackCounts;
static BOOL recoveryMissingItem,holdRecoveryZeroRead;
static NSUInteger recoveryItemReads;
static dispatch_block_t heldRecoveryZeroRead;


static NSString *uri(int n){return [NSString stringWithFormat:@"spotify:album:%022d",n];}
static NSDictionary *release(int n){return @{ @"uri":uri(n),@"name":@"Fixture" };}
BOOL SAPIsAlbumURI(NSString *u){return [u hasPrefix:@"spotify:album:"] && u.length==36;}
BOOL SAPIsPlaylistURI(NSString *u){return [u hasPrefix:@"spotify:playlist:"] && u.length==39;}
NSArray *SAPParseArtistAlbumTrackURIs(NSData *data,NSString *uri,NSString **reason){NSUInteger count=[verifiedFixtureTrackCounts[uri]unsignedIntegerValue];if(!count || ![[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]isEqual:uri])return nil;NSMutableArray *tracks=[NSMutableArray array];for(NSUInteger i=0;i<count;i++)[tracks addObject:[NSString stringWithFormat:@"spotify:track:%022lu",(unsigned long)i+1]];return tracks;}
bool SAPDiagnosticsEnabled(void){return true;}

void SAPJournalNoteAction(NSString *event,NSDictionary *facts){if([event hasPrefix:@"artist_observation_"] || [event hasPrefix:@"artist_native_reregistration_"])[repairJournal addObject:@{@"event":event,@"facts":facts?:@{}}];}
void SAPPrepareNativeOffline(BOOL(^wanted)(void),void(^done)(BOOL,NSString*)){
    if(holdPrepare){[heldPreparations addObject:[done copy]];return;}
    dispatch_async(dispatch_get_main_queue(),^{if(wanted())done(YES,nil);else done(NO,@"cancelled");});
}

static NSArray *asked(NSData *data,unsigned field){
    NSMutableArray *out=[NSMutableArray array];
    for(NSDictionary *f in SAPProtoFields(data))if([f[@"number"]unsignedIntValue]==field && [f[@"wire"]unsignedIntValue]==2)
        [out addObject:[[NSString alloc]initWithData:f[@"value"] encoding:NSUTF8StringEncoding]];
    return out;
}
static NSData *stateDataFrom(NSArray *uris,NSDictionary *states){
    NSMutableData *out=[NSMutableData data];
    for(NSString *u in uris){NSMutableData *c=[SAPProtoBytes(1,[u dataUsingEncoding:NSUTF8StringEncoding]) mutableCopy];
        if([states[u]unsignedIntValue])[c appendData:SAPProtoInteger(2,[states[u]unsignedIntValue])];
        [out appendData:SAPProtoBytes(1,SAPProtoBytes(1,c))];
    }return out;
}
static NSData *stateData(NSArray *uris){return stateDataFrom(uris,native);}
static NSData *progressDataWithTotals(NSArray *uris,BOOL downloading,int done,int total,uint64_t downloadedBytes,uint64_t totalBytes,NSUInteger totalsState){
    NSMutableData *out=[NSMutableData data];
    for(NSString *u in uris){NSMutableData *p=[SAPProtoInteger(1,0) mutableCopy]; // queued_tracks
        [p appendData:SAPProtoInteger(2,0)]; // queued_bytes
        [p appendData:SAPProtoInteger(3,done)];[p appendData:SAPProtoInteger(4,downloadedBytes)];
        [p appendData:SAPProtoInteger(5,total)];[p appendData:SAPProtoInteger(6,totalBytes)];
        [p appendData:SAPProtoInteger(7,downloading?1:0)];[p appendData:SAPProtoInteger(11,totalsState)];
        NSMutableData *c=[SAPProtoBytes(1,[u dataUsingEncoding:NSUTF8StringEncoding]) mutableCopy];[c appendData:SAPProtoBytes(2,p)];
        [out appendData:SAPProtoBytes(1,c)];
    }return out;
}
static NSData *progressData(NSArray *uris,BOOL downloading,int done,int total,uint64_t downloadedBytes,uint64_t totalBytes){return progressDataWithTotals(uris,downloading,done,total,downloadedBytes,totalBytes,2);}
static NSData *currentProgress(NSArray *uris){NSMutableData *data=[NSMutableData data];for(NSString *u in uris)[data appendData:progressSnapshots[u]?:progressData(@[u],NO,0,0,0,0)];return data;}
static void (^storedReply(NSMutableDictionary *store,NSString *key))(NSData*,NSString*) {return store[key];}

dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *service,NSString *method,NSData *payload,void(^done)(NSData*,NSString*)){
    reads++;
    if(holdRecoveryZeroRead && [method isEqual:@"GetContexts"] && [native[asked(payload,3).firstObject]isEqual:@0]){holdRecoveryZeroRead=NO;NSData *captured=stateData(asked(payload,3));__block BOOL cancelled=NO;heldRecoveryZeroRead=^{if(!cancelled)done(captured,nil);};return ^{cancelled=YES;};}
    if(holdNextContextRead && [method isEqual:@"GetContexts"]){holdNextContextRead=NO;NSData *captured=stateData(asked(payload,3));heldVerificationRead=^{done(captured,nil);};return ^{};}
    if(failContextReads && [method isEqual:@"GetContexts"]){dispatch_async(dispatch_get_main_queue(),^{done(nil,@"No verified Spotify stream transport is available");});return ^{};}
    if([method isEqual:@"Contains"] && holdContains){NSString *u=asked(payload,3).firstObject;
        [heldContains addObject:[^{NSMutableData *e=[SAPProtoBytes(1,[u dataUsingEncoding:NSUTF8StringEncoding]) mutableCopy];if([members[u]boolValue])[e appendData:SAPProtoInteger(2,1)];
            NSMutableData *r=[SAPProtoBytes(2,e) mutableCopy];[r appendData:SAPProtoInteger(98,200)];done(r,nil);} copy]];return ^{};
    }
    if(holdCatalogReads && [method isEqual:@"GetContexts"]){NSArray *requested=asked(payload,3);if(requested.count>1){[readURIs addObject:requested];NSData *captured=stateDataFrom(requested,initialReadStates?:native);[heldInitialReads addObject:[^{done(captured,nil);} copy]];return ^{};}}
    if(holdCatalogReads && [method isEqual:@"GetContextsProgress"]){NSArray *requested=asked(payload,1);if(requested.count>1){[heldInitialReads addObject:[^{done(progressData(requested,YES,5,10,5120,10240),nil);} copy]];return ^{};}}
    __block BOOL cancelled=NO;dispatch_async(dispatch_get_main_queue(),^{if(cancelled)return;NSData *reply=nil;
        if([method isEqual:@"Contains"]){NSString *u=asked(payload,3).firstObject;NSMutableData *e=[SAPProtoBytes(1,[u dataUsingEncoding:NSUTF8StringEncoding]) mutableCopy];if([members[u]boolValue])[e appendData:SAPProtoInteger(2,1)];NSMutableData *r=[SAPProtoBytes(2,e) mutableCopy];[r appendData:SAPProtoInteger(98,200)];reply=r;}
        else if([method isEqual:@"GetEntity"]){entityReads++;reply=[SAPProtoString(SAPProtoFields(payload),1)dataUsingEncoding:NSUTF8StringEncoding];}
        else if([method isEqual:@"GetContexts"]){NSArray *requested=asked(payload,3);[readURIs addObject:requested?:@[]];reply=stateData(requested);}
        else if([method isEqual:@"GetItems"]){recoveryItemReads++;NSArray *uris=asked(payload,1);assert(uris.count<=256);NSMutableData *items=[NSMutableData data];for(NSUInteger i=0;i<uris.count;i++){if(recoveryMissingItem && i==0)continue;NSMutableData *item=[SAPProtoBytes(1,[uris[i]dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];[item appendData:SAPProtoInteger(2,3)];[items appendData:SAPProtoBytes(1,item)];}reply=items;}
        else if([method isEqual:@"GetContextsProgress"])reply=progressData(asked(payload,1),NO,0,0,0,0);
        else assert(0);done(reply,nil);
    });return ^{cancelled=YES;};
}
dispatch_block_t SAPSubscribeReadOnlyService(NSString *service,NSString *method,NSData *payload,void(^done)(NSData*,NSString*)){
    streamStarts++;NSString *key=NSUUID.UUID.UUIDString;NSMutableDictionary *store=[method isEqual:@"SubscribeContextsProgress"]?progressStreams:contexts;
    store[key]=[done copy];[streamLeaseEvents addObject:[@"start:" stringByAppendingString:key]];
    BOOL progress=[method isEqual:@"SubscribeContextsProgress"];NSArray *requested=asked(payload,progress?1:3);
    if(!contextRequests)contextRequests=[NSMutableDictionary dictionary];if(!progress)contextRequests[key]=@{@"uris":requested,@"state_only":@(SAPProtoData(SAPProtoFields(payload),1)!=nil)};
    if(!progress && !SAPProtoData(SAPProtoFields(payload),1)){assert(requested.count>0 && requested.count<=fixtureNativeContextLimit);if(!nativeDefaultContexts)nativeDefaultContexts=[NSMutableArray array];[nativeDefaultContexts addObject:requested];}
    dispatch_block_t first=^{if(!store[key])return;[streamLeaseEvents addObject:[@"healthy:" stringByAppendingString:key]];done(progress?currentProgress(requested):stateData(requested),nil);};
    if(holdStreamResponses)[heldStreamResponses addObject:[first copy]];
    else if(autoStreamResponses)dispatch_async(dispatch_get_main_queue(),first);
    return ^{if(!store[key])return;[streamLeaseEvents addObject:[@"cancel:" stringByAppendingString:key]];[store removeObjectForKey:key];[contextRequests removeObjectForKey:key];[streamCancels addObject:key];};
}
void SAPAddAlbumToLibraryOnce(NSString *u,void(^done)(NSData*,NSString*)){
    [sent addObject:[@"save:" stringByAppendingString:u]];members[u]=@YES;dispatch_async(dispatch_get_main_queue(),^{done([NSData data],nil);});
}
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void(^done)(NSData*,NSString*)){
    NSString *u=asked(payload,2).firstObject;[sent addObject:[method stringByAppendingFormat:@":%@",u]];
    if([method isEqual:@"AddDownload"]){
        assert(![submittedUnfinishedURIs containsObject:u]);
        [submittedUnfinishedURIs addObject:u];[addSubmissionOrder addObject:u];
        peakSubmittedUnfinished=MAX(peakSubmittedUnfinished,submittedUnfinishedURIs.count);
        assert(submittedUnfinishedURIs.count<=fixtureSubmittedLimit); // ACKs never release native capacity.
        addReplies[u]=[done copy];
    }
    else if([method isEqual:@"RemoveDownload"])removeReplies[u]=[done copy];
}
void SAPSetPlaylistOfflineOnce(NSString *uri,BOOL enabled,void(^done)(NSData*,NSString*)){
    SAPCallOfflineCommandOnce(enabled?@"AddDownload":@"RemoveDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *reply,NSString *error){done(reply && !reply.length?SAPProtoBytes(1,SAPProtoInteger(1,200)):reply,error);});
}
void SAPCallOfflineCommandOnceWithDisposition(NSString *method,NSData *payload,void(^done)(NSData*,NSString*,SAPCommandInvocationDisposition)){
    NSString *uri=asked(payload,2).firstObject;if([method isEqual:@"RemoveDownload"] && [uri isEqual:neverInvokedRemoveURI]){dispatch_async(dispatch_get_main_queue(),^{done(nil,@"No native transport",SAPCommandNotInvoked);});return;}if([method isEqual:@"AddDownload"] && [uri isEqual:neverInvokedURI]){dispatch_async(dispatch_get_main_queue(),^{done(nil,@"No verified Spotify transport. Refresh the device state first.",SAPCommandNotInvoked);});return;}
    SAPCallOfflineCommandOnce(method,payload,^(NSData *data,NSString *error){done(data,error,SAPCommandInvoked);});
}
void SAPSetPlaylistOfflineOnceWithDisposition(NSString *uri,BOOL enabled,void(^done)(NSData*,NSString*,SAPCommandInvocationDisposition)){
    SAPSetPlaylistOfflineOnce(uri,enabled,^(NSData *data,NSString *error){done(data,error,SAPCommandInvoked);});
}
static void pump(double seconds){NSDate *d=[NSDate dateWithTimeIntervalSinceNow:seconds];while(d.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];}
static void waitForSessionAt(BOOL(^condition)(void),int line){NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];while(!condition() && deadline.timeIntervalSinceNow>0)pump(.002);if(!condition())fprintf(stderr,"Session wait failed at line %d\n",line);assert(condition());}
#define waitForSession(condition) waitForSessionAt(condition,__LINE__)
static void emit(NSMutableDictionary *store,NSData *data){for(void(^cb)(NSData*,NSString*) in store.allValues)cb(data,nil);}
static void failStream(void){void(^cb)(NSData*,NSString*)=[contexts.allValues.firstObject copy];assert(cb);cb(nil,@"No verified Spotify stream transport is available");}
static void releaseStreamResponses(void){NSArray *pending=[heldStreamResponses copy];[heldStreamResponses removeAllObjects];for(dispatch_block_t reply in pending)reply();pump(.02);}
static void emitState(NSArray *uris){emit(contexts,stateData(uris));}
static void emitProgress(NSString *u,BOOL downloading,int done,int total){NSData *data=progressData(@[u],downloading,done,total,(uint64_t)done*1024,(uint64_t)total*1024);progressSnapshots[u]=data;emit(progressStreams,data);}
// Explicit tail evidence is the only fixture input that admits a successor
// before its predecessor reaches a definite native terminal state.
static void nearTail(NSString *u){emitProgress(u,NO,0,1);pump(.005);}
static NSUInteger sentCount(NSString *prefix){return [[sent filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@",prefix]] count];}
static NSUInteger sentExactCount(NSString *command){return [sent filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@",command]].count;}
static NSString *phase(NSString *u){return snapshot[@"album_states"][u][@"phase"]?:@"";}
static void acceptAdd(NSString *u){void(^reply)(NSData*,NSString*)=addReplies[u];assert(reply);[addReplies removeObjectForKey:u];reply([NSData data],nil);}
static void failAdd(NSString *u,NSData *data,NSString *error){void(^reply)(NSData*,NSString*)=addReplies[u];assert(reply);[addReplies removeObjectForKey:u];reply(data,error);}
static void consumeTerminal(NSString *u){
    assert([submittedUnfinishedURIs containsObject:u]);
    [submittedUnfinishedURIs removeObject:u];terminalCounts[u]=@([terminalCounts[u]unsignedIntegerValue]+1);
}
static void rejectAdd(NSString *u,uint64_t code){consumeTerminal(u);void(^reply)(NSData*,NSString*)=addReplies[u];assert(reply);[addReplies removeObjectForKey:u];reply(SAPProtoInteger(1,code),nil);}
static void failRemove(NSString *u,NSData *data,NSString *error){void(^reply)(NSData*,NSString*)=removeReplies[u];assert(reply);[removeReplies removeObjectForKey:u];reply(data,error);}
static void finishRemove(NSString *u){if([addSubmissionOrder containsObject:u])consumeTerminal(u);native[u]=@0;emitState(@[u]);void(^reply)(NSData*,NSString*)=removeReplies[u];if(reply){[removeReplies removeObjectForKey:u];reply([NSData data],nil);}}
static void complete(NSString *u){consumeTerminal(u);native[u]=@3;emitState(@[u]);}
static void failNative(NSString *u){consumeTerminal(u);native[u]=@1;emitState(@[u]);}
static void cancelNative(NSString *u){consumeTerminal(u);native[u]=@0;emitState(@[u]);}
static void ready(NSArray *uris){for(NSString *u in uris){native[u]=@0;members[u]=@YES;[progressSnapshots removeObjectForKey:u];}}
static void assertSubmitted(NSArray *uris){assert([submittedUnfinishedURIs isEqual:[NSSet setWithArray:uris]]);}
static void initFixture(void){native=[NSMutableDictionary dictionary];members=[NSMutableDictionary dictionary];contexts=[NSMutableDictionary dictionary];progressStreams=[NSMutableDictionary dictionary];sent=[NSMutableArray array];streamCancels=[NSMutableArray array];heldContains=[NSMutableArray array];heldInitialReads=[NSMutableArray array];readURIs=[NSMutableArray array];addReplies=[NSMutableDictionary dictionary];removeReplies=[NSMutableDictionary dictionary];snapshot=nil;reads=streamStarts=peakSubmittedUnfinished=0;holdContains=holdPrepare=holdCatalogReads=NO;initialReadStates=nil;addSubmissionOrder=[NSMutableArray array];heldPreparations=[NSMutableArray array];submittedUnfinishedURIs=[NSMutableSet set];terminalCounts=[NSMutableDictionary dictionary];heldStreamResponses=[NSMutableArray array];streamLeaseEvents=[NSMutableArray array];autoStreamResponses=holdStreamResponses=failContextReads=NO;holdNextContextRead=NO;heldVerificationRead=nil;repairJournal=[NSMutableArray array];progressSnapshots=[NSMutableDictionary dictionary];}

int main(){setbuf(stdout,NULL);@autoreleasepool{
    // Albums now use the direct path in production; this suite first keeps
    // proving the ordered window that playlists still use.
    SAPArtistSessionSetDirectAlbumSubmissionForTesting(NO);
    initFixture();native[uri(1)]=@3;ready(@[uri(2),uri(3),uri(4),uri(5),uri(59)]);
    dispatch_block_t detach=SAPObserveArtistDownloadSession(@[release(1),release(2),release(3),release(4),release(5),release(59)],^(NSDictionary *s){snapshot=s;});pump(.03);
    assert([snapshot[@"album_states"][uri(1)][@"state"] isEqual:@"downloaded"]);
    NSString *error=nil;assert(!SAPAppendArtistDownloadSessionReleases(nil,&error) && error.length);assert(!SAPAppendArtistDownloadSessionReleases(@[],&error));assert(sent.count==0);error=nil;holdPrepare=YES;assert(SAPAppendArtistDownloadSessionReleases(@[release(2),release(3)],&error));pump(.03);
    assert(sentCount(@"AddDownload:")==0);assert([phase(uri(2)) isEqual:@"preparing"]);
    assert([phase(uri(3)) isEqual:@"preparing"] || [phase(uri(3)) isEqual:@"queued"]);
    assert(heldPreparations.count>0);holdPrepare=NO;
    for(void(^prepared)(BOOL,NSString*) in heldPreparations)prepared(YES,nil);[heldPreparations removeAllObjects];pump(.04);
    assert(sentCount(@"AddDownload:")==1);nearTail(uri(2));
    assert(sentCount(@"AddDownload:")==2);assertSubmitted(@[uri(2),uri(3)]);
    assert(([addSubmissionOrder isEqual:@[uri(2),uri(3)]]));
    acceptAdd(uri(2));acceptAdd(uri(3));pump(.02);assertSubmitted(@[uri(2),uri(3)]);
    emitProgress(uri(3),YES,2,10);emitProgress(uri(2),YES,5,10);
    assert([phase(uri(2)) isEqual:@"downloading"] && [phase(uri(3)) isEqual:@"downloading"]);
    assert([snapshot[@"album_states"][uri(2)][@"progress"] doubleValue]==.5);
    assert([snapshot[@"album_states"][uri(3)][@"progress"] doubleValue]==.2);
    NSUInteger oldReads=reads;pump(.08);assert(reads==oldReads); // No periodic status polling.
    complete(uri(3));pump(.03);assertSubmitted(@[uri(2)]);assert([snapshot[@"active"] boolValue]);
    assert([phase(uri(2)) isEqual:@"downloading"] && [phase(uri(3)) isEqual:@"downloaded"]);
    complete(uri(2));pump(.03);assert(![snapshot[@"active"] boolValue]);
    NSUInteger completedRemoves=sentCount(@"RemoveDownload:");SAPStopArtistDownloadSessionRelease(uri(1));pump(.02);assert(sentCount(@"RemoveDownload:")==completedRemoves);

    // Both native startups overlap before either finishes. Completion before
    // an Add ACK remains held until that ACK resolves the command race.
    NSUInteger before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(4),release(5),release(59)],&error));pump(.03);nearTail(uri(4));nearTail(uri(5));
    assert(sentCount(@"AddDownload:")==before+2);assertSubmitted(@[uri(4),uri(5)]);
    assert(([[addSubmissionOrder subarrayWithRange:NSMakeRange(before,2)] isEqual:@[uri(4),uri(5)]]));assert(terminalCounts[uri(4)]==nil && terminalCounts[uri(5)]==nil);
    complete(uri(4));pump(.03);assert(sentCount(@"AddDownload:")==before+2);
    acceptAdd(uri(5));pump(.02);assert(sentCount(@"AddDownload:")==before+2);
    acceptAdd(uri(4));pump(.03);assert(sentCount(@"AddDownload:")==before+3);assertSubmitted(@[uri(5),uri(59)]);
    acceptAdd(uri(59));complete(uri(59));pump(.02);assertSubmitted(@[uri(5)]);complete(uri(5));pump(.02);

    // Detaching the modal leaves both submitted albums and streams alive.
    ready(@[uri(6),uri(7)]);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(6),release(7)],&error));pump(.03);nearTail(uri(6));detach();detach=nil;
    assert(contexts.count>0 && progressStreams.count>0);assert(sentCount(@"AddDownload:")==before+2);
    acceptAdd(uri(6));acceptAdd(uri(7));complete(uri(7));pump(.02);assert(contexts.count>0 && progressStreams.count>0);
    complete(uri(6));pump(.03);assert(contexts.count==0 && progressStreams.count==0);

    NSMutableArray *testCatalog=[NSMutableArray array];for(int i=8;i<=140;i++)[testCatalog addObject:release(i)];
    __block NSDictionary *testSnapshot=nil;dispatch_block_t detachTests=SAPObserveArtistDownloadSession(testCatalog,^(NSDictionary *s){testSnapshot=s;snapshot=s;});pump(.03);

    // Unknown counts preserve FIFO. Zero totals, invalid counts and an
    // unknown totals state never admit speculative work. A reliable <=1 tail
    // admits the successor before any native completion, including 0/1 albums.
    ready(@[uri(129),uri(130),uri(131)]);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(129),release(130),release(131)],&error));pump(.03);
    assert(sentCount(@"AddDownload:")==before+1);acceptAdd(uri(129));pump(.02);assertSubmitted(@[uri(129)]);
    emit(progressStreams,progressDataWithTotals(@[uri(129)],NO,0,0,0,0,2));pump(.01);assert(sentCount(@"AddDownload:")==before+1);
    emit(progressStreams,progressDataWithTotals(@[uri(129)],NO,11,10,0,0,2));pump(.01);assert(sentCount(@"AddDownload:")==before+1);
    emit(progressStreams,progressDataWithTotals(@[uri(129)],NO,9,10,0,0,0));pump(.01);assert(sentCount(@"AddDownload:")==before+1);
    emitProgress(uri(129),NO,8,10);pump(.01);assert(sentCount(@"AddDownload:")==before+1);
    emitProgress(uri(129),NO,9,10);pump(.03);assert(sentCount(@"AddDownload:")==before+2);assertSubmitted(@[uri(129),uri(130)]);
    assert(terminalCounts[uri(129)]==nil);acceptAdd(uri(130));nearTail(uri(130));assert(sentCount(@"AddDownload:")==before+2);
    complete(uri(130));pump(.03);assert(sentCount(@"AddDownload:")==before+3);acceptAdd(uri(131));complete(uri(131));complete(uri(129));pump(.02);
    ready(@[uri(132),uri(133)]);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(132),release(133)],&error));pump(.03);assert(sentCount(@"AddDownload:")==before+1);
    acceptAdd(uri(132));pump(.02);assert(sentCount(@"AddDownload:")==before+1);complete(uri(132));pump(.03);
    assert(sentCount(@"AddDownload:")==before+2);acceptAdd(uri(133));complete(uri(133));pump(.02);

    // Without tail evidence an ambiguous ACK still preserves the original
    // FIFO behavior after its one exact read; active state alone cannot admit.
    ready(@[uri(134),uri(135)]);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(134),release(135)],&error));pump(.03);NSUInteger unknownAckReads=reads;
    failAdd(uri(134),nil,nil);pump(.03);assert(reads==unknownAckReads+1 && [readURIs.lastObject isEqual:@[uri(134)]]);
    native[uri(134)]=@4;emitState(@[uri(134)]);pump(.02);assert(sentCount(@"AddDownload:")==before+1);assertSubmitted(@[uri(134)]);
    complete(uri(134));pump(.03);assert(sentCount(@"AddDownload:")==before+2);acceptAdd(uri(135));complete(uri(135));pump(.02);

    // The next album's library save and membership confirmation can finish
    // while the first is still waiting; only the tail event admits its Add.
    ready(@[uri(136),uri(137)]);[members removeObjectForKey:uri(137)];before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(136),release(137)],&error));pump(.03);
    assert(sentCount(@"AddDownload:")==before+1);assert(sentExactCount([@"save:" stringByAppendingString:uri(137)])==1);
    assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(137)])==0);acceptAdd(uri(136));nearTail(uri(136));pump(.02);
    assert(sentCount(@"AddDownload:")==before+2);assertSubmitted(@[uri(136),uri(137)]);assert(terminalCounts[uri(136)]==nil);
    acceptAdd(uri(137));complete(uri(137));complete(uri(136));pump(.02);

    // Empty NSData is a valid ACK. Nil, malformed and transport failures each
    // reconcile exactly one URI once, without replay or freeing either slot.
    ready(@[uri(8)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(8)],&error));pump(.03);acceptAdd(uri(8));assert([phase(uri(8)) isEqual:@"waiting"]);assertSubmitted(@[uri(8)]);complete(uri(8));pump(.02);
    NSArray *ambiguousCases=@[@[@9,@90,@91],@[@10,@100,@101],@[@11,@110,@111],@[@12,@13,@114]];
    for(NSUInteger i=0;i<ambiguousCases.count;i++){
        NSArray *numbers=ambiguousCases[i];NSString *a=uri([numbers[0]intValue]),*b=uri([numbers[1]intValue]),*c=uri([numbers[2]intValue]);
        ready(@[a,b,c]);NSArray *batch=@[release([numbers[0]intValue]),release([numbers[1]intValue]),release([numbers[2]intValue])];
        before=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(batch,&error));pump(.03);nearTail(a);nearTail(b);
        assert(sentCount(@"AddDownload:")==before+2);assertSubmitted(@[a,b]);NSUInteger beforeRead=reads;
        if(i==1)native[a]=@4;
        failAdd(a,i==1?[NSData dataWithBytes:"\xff" length:1]:nil,i==2?@"transport failed":nil);pump(.03);
        assert(sentCount(@"AddDownload:")==before+2 && reads==beforeRead+1);assert([readURIs.lastObject isEqual:@[a]]);
        assert([phase(a) isEqual:@"waiting"] && [phase(c) isEqual:@"queued"]);assert([snapshot[@"album_states"][a][@"error"] length]>0);
        acceptAdd(b);pump(.02);assertSubmitted(@[a,b]);assert(sentCount(@"AddDownload:")==before+2);
        native[a]=@4;emitState(@[a]);emitProgress(a,YES,2,10);pump(.02);
        assert(sentCount(@"AddDownload:")==before+2 && reads==beforeRead+1);
        complete(a);pump(.03);assert(sentCount(@"AddDownload:")==before+3);assertSubmitted(@[b,c]);
        acceptAdd(c);complete(c);complete(b);pump(.02);
        assert(sentExactCount([@"AddDownload:" stringByAppendingString:a])==1);
    }

    // A definite rejection and a native error release only their own slot.
    ready(@[uri(112),uri(113),uri(115)]);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(112),release(113),release(115)],&error));pump(.03);nearTail(uri(112));nearTail(uri(113));
    rejectAdd(uri(112),7);pump(.03);assert([phase(uri(112)) isEqual:@"failed"] && sentCount(@"AddDownload:")==before+3);
    assertSubmitted(@[uri(113),uri(115)]);acceptAdd(uri(113));acceptAdd(uri(115));complete(uri(115));complete(uri(113));pump(.02);
    ready(@[uri(14),uri(15),uri(116)]);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(14),release(15),release(116)],&error));pump(.03);nearTail(uri(14));nearTail(uri(15));
    acceptAdd(uri(14));failNative(uri(14));pump(.03);assert([phase(uri(14)) isEqual:@"failed"] && sentCount(@"AddDownload:")==before+3);
    assertSubmitted(@[uri(15),uri(116)]);acceptAdd(uri(15));acceptAdd(uri(116));complete(uri(15));complete(uri(116));pump(.02);

    // A queued Stop sends no Remove. A submitted Stop waits for its own ACK
    // and definite removal while the other submitted album remains independent.
    ready(@[uri(16),uri(17),uri(21),uri(27)]);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(16),release(21),release(17),release(27)],&error));pump(.03);nearTail(uri(16));nearTail(uri(21));
    NSUInteger removes=sentCount(@"RemoveDownload:");SAPStopArtistDownloadSessionRelease(uri(17));pump(.02);
    assert(sentCount(@"RemoveDownload:")==removes);assert([phase(uri(17)) isEqual:@"idle"] || [phase(uri(17)) isEqual:@"failed"]);
    SAPStopArtistDownloadSessionRelease(uri(16));pump(.02);assert(sentCount(@"AddDownload:")==before+2 && sentCount(@"RemoveDownload:")==removes);
    acceptAdd(uri(16));pump(.02);assert(sentCount(@"RemoveDownload:")==removes+1 && sentCount(@"AddDownload:")==before+2);
    assertSubmitted(@[uri(16),uri(21)]);finishRemove(uri(16));pump(.03);assert(sentCount(@"AddDownload:")==before+3);assertSubmitted(@[uri(21),uri(27)]);
    acceptAdd(uri(27));complete(uri(27));acceptAdd(uri(21));complete(uri(21));pump(.02);
    assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(17)])==0);

    // A failed Remove ACK does not release native capacity; state zero does.
    ready(@[uri(22),uri(23),uri(30)]);before=sentCount(@"AddDownload:");removes=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(22),release(23),release(30)],&error));pump(.03);nearTail(uri(22));nearTail(uri(23));
    acceptAdd(uri(22));native[uri(22)]=@4;SAPStopArtistDownloadSessionRelease(uri(22));pump(.03);
    assert(sentCount(@"AddDownload:")==before+2 && sentCount(@"RemoveDownload:")==removes+1);
    failRemove(uri(22),nil,@"stop transport failed");pump(.02);assert(sentCount(@"AddDownload:")==before+2);assertSubmitted(@[uri(22),uri(23)]);
    cancelNative(uri(22));pump(.03);assert(sentCount(@"AddDownload:")==before+3);acceptAdd(uri(23));acceptAdd(uri(30));complete(uri(30));complete(uri(23));pump(.02);

    // Stop All atomically removes all unsent entries before waiting for both
    // Add ACKs. Late ACKs can only stop their own submitted URI.
    native[uri(18)]=@3;ready(@[uri(19),uri(20),uri(61),uri(62)]);before=sentCount(@"AddDownload:");removes=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(18),release(19),release(20),release(61),release(62)],&error));
    // Tail evidence belongs after submission; elapsed wall time does not prove
    // that the native command boundary has run on a loaded simulator host.
    waitForSession(^BOOL{return sentCount(@"AddDownload:")==before+1;});nearTail(uri(19));
    waitForSession(^BOOL{return sentCount(@"AddDownload:")==before+2;});nearTail(uri(20));
    assert(sentCount(@"AddDownload:")==before+2);SAPStopArtistDownloadSession();pump(.02);
    assert(![snapshot[@"album_states"][uri(18)][@"active"] boolValue]);assert(sentCount(@"AddDownload:")==before+2 && sentCount(@"RemoveDownload:")==removes);
    acceptAdd(uri(20));pump(.02);assert(sentCount(@"AddDownload:")==before+2 && sentCount(@"RemoveDownload:")==removes+1);
    finishRemove(uri(20));pump(.02);assert(sentCount(@"AddDownload:")==before+2);
    acceptAdd(uri(19));pump(.02);assert(sentCount(@"RemoveDownload:")==removes+2);finishRemove(uri(19));pump(.02);
    assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(61)])==0 && sentExactCount([@"AddDownload:" stringByAppendingString:uri(62)])==0);

    // Cache pressure cannot evict locally owned work. Stop before Contains
    // replies cancels both preparations and every unsent entry atomically.
    holdContains=YES;assert(SAPAppendArtistDownloadSessionReleases(@[release(7000),release(7001),release(7002)],&error));
    __block NSDictionary *queuedSnapshot=nil;dispatch_block_t detachQueued=SAPObserveArtistDownloadSession(@[release(7000),release(7001),release(7002)],^(NSDictionary *s){queuedSnapshot=s;});pump(.03);
    for(int i=7000;i<=7002;i++)assert([queuedSnapshot[@"album_states"][uri(i)][@"active"] boolValue]);
    for(int i=6000;i<6300;i++){dispatch_block_t d=SAPObserveArtistDownloadSession(@[release(i)],nil);pump(.003);d();}
    assert([queuedSnapshot[@"album_states"] count]==3);NSUInteger oldSent=sent.count;SAPStopArtistDownloadSession();pump(.03);
    for(int i=7000;i<=7002;i++)assert(![queuedSnapshot[@"album_states"][uri(i)][@"active"] boolValue]);assert(sent.count==oldSent);
    holdContains=NO;for(dispatch_block_t completeContains in heldContains)completeContains();[heldContains removeAllObjects];pump(.02);assert(sent.count==oldSent);detachQueued();

    // Artist observers share the same per-URI state and deduplicate albums.
    ready(@[uri(31),uri(32),uri(33)]);__block NSDictionary *artistA=nil,*artistB=nil;
    dispatch_block_t detachA=SAPObserveArtistDownloadSession(@[release(31),release(32)],^(NSDictionary *s){artistA=s;});
    dispatch_block_t detachB=SAPObserveArtistDownloadSession(@[release(32),release(33)],^(NSDictionary *s){artistB=s;});pump(.03);
    NSUInteger artistAdds=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(31),release(32)],&error));pump(.03);nearTail(uri(31));nearTail(uri(32));
    assert(SAPAppendArtistDownloadSessionReleases(@[release(32),release(33)],&error));pump(.03);
    assert(sentCount(@"AddDownload:")==artistAdds+2);assertSubmitted(@[uri(31),uri(32)]);
    assert([artistB[@"active"] boolValue] && [artistB[@"global_active"] boolValue]);
    acceptAdd(uri(32));emitProgress(uri(32),YES,5,10);
    assert([artistA[@"album_states"][uri(32)]isEqual:artistB[@"album_states"][uri(32)]]);
    assert([artistA[@"album_states"][uri(32)][@"phase"]isEqual:@"downloading"]);
    assert([artistB[@"album_states"][uri(32)][@"downloaded_tracks"]unsignedIntegerValue]==5);
    assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(32)])==1);
    complete(uri(32));pump(.03);assert(sentCount(@"AddDownload:")==artistAdds+3);assertSubmitted(@[uri(31),uri(33)]);
    acceptAdd(uri(31));complete(uri(31));pump(.03);assert(![artistA[@"active"] boolValue] && [artistA[@"global_active"] boolValue]);
    detachA();detachA=nil;assert([artistB[@"active"] boolValue]);acceptAdd(uri(33));complete(uri(33));pump(.03);detachB();detachB=nil;

    // Scoped Stop clears A's queued album before either A Add ACK arrives.
    // B's submitted album continues, then its queue fills the confirmed slots.
    ready(@[uri(41),uri(42),uri(43),uri(44),uri(45)]);
    assert(SAPAppendArtistDownloadSessionReleases(@[release(41),release(43),release(42),release(44),release(45)],&error));pump(.03);nearTail(uri(41));nearTail(uri(43));
    NSUInteger scopedAdds=sentCount(@"AddDownload:"),scopedRemoves=sentCount(@"RemoveDownload:");
    SAPStopArtistDownloadSessionReleases(@[release(41),release(42)]);pump(.03);
    assert(sentCount(@"AddDownload:")==scopedAdds && sentCount(@"RemoveDownload:")==scopedRemoves);
    acceptAdd(uri(43));emitProgress(uri(43),YES,9,10);pump(.02);assert(sentCount(@"RemoveDownload:")==scopedRemoves);
    acceptAdd(uri(41));pump(.03);assert(sentCount(@"RemoveDownload:")==scopedRemoves+1);
    finishRemove(uri(41));pump(.03);assert(sentCount(@"AddDownload:")==scopedAdds+1);assertSubmitted(@[uri(43),uri(44)]);
    assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(42)])==0);
    nearTail(uri(44));complete(uri(43));pump(.03);assert(sentCount(@"AddDownload:")==scopedAdds+2);assertSubmitted(@[uri(44),uri(45)]);
    assert(sentExactCount([@"RemoveDownload:" stringByAppendingString:uri(43)])==0);
    acceptAdd(uri(44));acceptAdd(uri(45));complete(uri(45));complete(uri(44));pump(.02);

    // Delayed catalog reads cannot overwrite either locally submitted album
    // or let a stale state zero advance the waiting third album.
    ready(@[uri(24),uri(25),uri(26)]);initialReadStates=@{uri(24):@4,uri(25):@0,uri(26):@0};holdCatalogReads=YES;
    __block NSDictionary *staleReadSnapshot=nil;dispatch_block_t detachStaleRead=SAPObserveArtistDownloadSession(@[release(24),release(25),release(26)],^(NSDictionary *s){staleReadSnapshot=s;});
    holdCatalogReads=NO;initialReadStates=nil;assert(heldInitialReads.count==2);NSUInteger staleReadAdds=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(24),release(25),release(26)],&error));pump(.03);nearTail(uri(24));nearTail(uri(25));
    assert(sentCount(@"AddDownload:")==staleReadAdds+2);acceptAdd(uri(24));acceptAdd(uri(25));
    for(dispatch_block_t deliver in heldInitialReads)deliver();[heldInitialReads removeAllObjects];pump(.03);
    assert(sentCount(@"AddDownload:")==staleReadAdds+2);assertSubmitted(@[uri(24),uri(25)]);
    for(int i=24;i<=25;i++){NSDictionary *state=staleReadSnapshot[@"album_states"][uri(i)];assert([state[@"phase"] isEqual:@"waiting"]);assert([state[@"error"]length]==0 && [state[@"progress"]doubleValue]==0);}
    assert([staleReadSnapshot[@"album_states"][uri(26)][@"phase"] isEqual:@"queued"]);
    complete(uri(25));pump(.03);assert(sentCount(@"AddDownload:")==staleReadAdds+3);acceptAdd(uri(26));complete(uri(24));complete(uri(26));pump(.02);detachStaleRead();

    // Adopting native work from an existing catalog watch changes operation
    // ownership even when the subscribed URI list is unchanged. Its terminal
    // event must release that operation and allow the third album to start.
    ready(@[uri(118),uri(119),uri(120)]);native[uri(121)]=@4;
    __block NSDictionary *adoptedSnapshot=nil;dispatch_block_t detachAdopted=SAPObserveArtistDownloadSession(@[release(118),release(119),release(120),release(121)],^(NSDictionary *s){adoptedSnapshot=s;});pump(.03);
    assert(contexts.count>0 && progressStreams.count>0);before=sentCount(@"AddDownload:");native[uri(118)]=@4;
    assert(SAPAppendArtistDownloadSessionReleases(@[release(118),release(119),release(120)],&error));pump(.03);
    assert(sentCount(@"AddDownload:")==before);assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(119)])==0);assertSubmitted(@[]);
    nearTail(uri(118));nearTail(uri(119));
    assert(sentCount(@"AddDownload:")==before+1);assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(118)])==0);
    assert([adoptedSnapshot[@"album_states"][uri(120)][@"phase"]isEqual:@"queued"]);assertSubmitted(@[uri(119)]);
    acceptAdd(uri(119));native[uri(118)]=@3;emitState(@[uri(118)]);pump(.03);
    assert([adoptedSnapshot[@"album_states"][uri(118)][@"phase"]isEqual:@"downloaded"]);
    assert(sentCount(@"AddDownload:")==before+2);assertSubmitted(@[uri(119),uri(120)]);
    acceptAdd(uri(120));complete(uri(120));complete(uri(119));pump(.02);
    // The active preflight also supplies evidence needed to recognize a later
    // native cancellation, which releases the adopted slot without Remove.
    ready(@[uri(125),uri(126),uri(127)]);native[uri(125)]=@4;before=sentCount(@"AddDownload:");removes=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(125),release(126),release(127)],&error));pump(.03);nearTail(uri(125));nearTail(uri(126));
    assert(sentCount(@"AddDownload:")==before+1);acceptAdd(uri(126));native[uri(125)]=@0;emitState(@[uri(125)]);pump(.03);
    assert(sentCount(@"AddDownload:")==before+2 && sentCount(@"RemoveDownload:")==removes);assertSubmitted(@[uri(126),uri(127)]);
    acceptAdd(uri(127));complete(uri(127));complete(uri(126));native[uri(121)]=@3;emitState(@[uri(121)]);pump(.02);detachAdopted();

    // A previous native error discovered by preflight belongs to the old
    // attempt. The new Add ACK must wait for a fresh native terminal event.
    ready(@[uri(122),uri(123),uri(124)]);native[uri(122)]=@1;
    dispatch_block_t detachRetryError=SAPObserveArtistDownloadSession(@[release(122),release(123),release(124)],nil);pump(.03);before=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(122),release(123),release(124)],&error));pump(.03);nearTail(uri(122));nearTail(uri(123));assert(sentCount(@"AddDownload:")==before+2);
    acceptAdd(uri(122));pump(.02);assert([phase(uri(122))isEqual:@"waiting"]);assertSubmitted(@[uri(122),uri(123)]);assert(sentCount(@"AddDownload:")==before+2);
    failNative(uri(122));pump(.03);assert([phase(uri(122))isEqual:@"failed"] && sentCount(@"AddDownload:")==before+3);
    acceptAdd(uri(123));acceptAdd(uri(124));complete(uri(124));complete(uri(123));pump(.02);detachRetryError();

    // A callback from a prior watch generation cannot complete a newly added
    // operation for the same URI, even while its peer is also waiting.
    native[uri(28)]=@4;ready(@[uri(29),uri(117)]);members[uri(28)]=@YES;
    __block NSDictionary *oldWatchSnapshot=nil;dispatch_block_t detachOldWatch=SAPObserveArtistDownloadSession(@[release(28),release(29),release(117)],^(NSDictionary *s){oldWatchSnapshot=s;});pump(.03);
    assert(contexts.count>0);void(^oldWatch)(NSData*,NSString*)=[contexts.allValues.firstObject copy];assert(oldWatch);native[uri(28)]=@0;emitState(@[uri(28)]);pump(.02);
    NSUInteger retryAdds=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(28),release(29),release(117)],&error));pump(.03);nearTail(uri(28));nearTail(uri(29));
    assert(sentCount(@"AddDownload:")==retryAdds+2);acceptAdd(uri(28));acceptAdd(uri(29));
    oldWatch(stateDataFrom(@[uri(28)],@{uri(28):@3}),nil);pump(.02);
    assert(sentCount(@"AddDownload:")==retryAdds+2);assertSubmitted(@[uri(28),uri(29)]);assert([oldWatchSnapshot[@"album_states"][uri(28)][@"phase"] isEqual:@"waiting"]);
    complete(uri(28));pump(.03);assert(sentCount(@"AddDownload:")==retryAdds+3);acceptAdd(uri(117));complete(uri(117));complete(uri(29));pump(.02);detachOldWatch();

    detachTests();detachTests=nil;
    NSMutableArray *catalog=[NSMutableArray array];for(int i=100;i<400;i++)[catalog addObject:release(i)];
    __block NSDictionary *largeSnapshot=nil;dispatch_block_t detachLarge=SAPObserveArtistDownloadSession(catalog,^(NSDictionary *s){largeSnapshot=s;});pump(.06);
    assert([largeSnapshot[@"album_states"] count]==300);detachLarge();NSUInteger beforeReopen=reads;
    dispatch_block_t reopen=SAPObserveArtistDownloadSession(@[release(100)],^(NSDictionary *s){snapshot=s;});pump(.03);assert(reads>=beforeReopen+2);assert(snapshot[@"album_states"][uri(100)]!=nil);reopen();
    native[uri(9000)]=@4;dispatch_block_t detachActive=SAPObserveArtistDownloadSession(@[release(9000)],nil);pump(.03);detachActive();
    for(int i=5000;i<5300;i++){dispatch_block_t d=SAPObserveArtistDownloadSession(@[release(i)],nil);pump(.003);d();}
    oldSent=sent.count;SAPStopArtistDownloadSession();pump(.04);assert([sent containsObject:[@"RemoveDownload:" stringByAppendingString:uri(9000)]]);assert(sent.count>oldSent);finishRemove(uri(9000));pump(.03);
    assert(contexts.count==0 && progressStreams.count==0);assertSubmitted(@[]);

    // Timeout pauses the whole pipeline, clears unsent work and releases all
    // watches. A held Add ACK and an old watch cannot replay that work.
    SAPArtistSessionSetWorkTimeoutForTesting(.5);ready(@[uri(50),uri(51),uri(60)]);
    __block NSDictionary *timeoutSnapshot=nil;dispatch_block_t detachTimeout=SAPObserveArtistDownloadSession(@[release(50),release(51),release(60)],^(NSDictionary *s){timeoutSnapshot=s;});
    NSUInteger timeoutAdds=sentCount(@"AddDownload:"),timeoutRemoves=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(50),release(51),release(60)],&error));pump(.03);nearTail(uri(50));nearTail(uri(51));assert(sentCount(@"AddDownload:")==timeoutAdds+2);acceptAdd(uri(50));
    native[uri(50)]=@4;native[uri(51)]=@4;emitState(@[uri(50),uri(51)]);
    void(^expiredWatch)(NSData*,NSString*)=[contexts.allValues.firstObject copy];assert(expiredWatch);detachTimeout();waitForSession(^BOOL{return contexts.count==0 && progressStreams.count==0;});
    assert(sentCount(@"AddDownload:")==timeoutAdds+2 && sentCount(@"RemoveDownload:")==timeoutRemoves);assert(contexts.count==0 && progressStreams.count==0);assertSubmitted(@[uri(50),uri(51)]);
    acceptAdd(uri(51));expiredWatch(stateDataFrom(@[uri(50)],@{uri(50):@3}),nil);pump(.02);assert(sentCount(@"AddDownload:")==timeoutAdds+2);
    // Pausing cannot discard submitted native reservations. Appending a new
    // batch reconciles those URIs and holds every new Add while both are active.
    ready(@[uri(67),uri(68)]);NSUInteger resumeReads=reads;
    assert(SAPAppendArtistDownloadSessionReleases(@[release(67),release(68)],&error));pump(.03);
    assert(reads==resumeReads+2);assert(sentCount(@"AddDownload:")==timeoutAdds+2 && sentCount(@"RemoveDownload:")==timeoutRemoves);assertSubmitted(@[uri(50),uri(51)]);
    SAPStopArtistDownloadSessionReleases(@[release(67),release(68)]);pump(.02);assert(sentCount(@"RemoveDownload:")==timeoutRemoves);
    dispatch_block_t reopenTimeout=SAPObserveArtistDownloadSession(@[release(50),release(51),release(60)],^(NSDictionary *s){timeoutSnapshot=s;});pump(.03);
    assert([timeoutSnapshot[@"album_states"][uri(60)][@"phase"] isEqual:@"failed"]);
    complete(uri(50));complete(uri(51));pump(.02);assert(sentCount(@"AddDownload:")==timeoutAdds+2);assert(contexts.count==0 && progressStreams.count==0);
    reopenTimeout();SAPArtistSessionSetWorkTimeoutForTesting(900);

    // A real gain extends its own deadline. Repeating identical values does
    // not extend it a second time, even after the peer has completed.
    SAPArtistSessionSetWorkTimeoutForTesting(.18);ready(@[uri(52),uri(53)]);
    __block NSDictionary *gainSnapshot=nil;dispatch_block_t detachGain=SAPObserveArtistDownloadSession(@[release(52),release(53)],^(NSDictionary *s){gainSnapshot=s;});
    NSUInteger gainAdds=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(52),release(53)],&error));pump(.03);nearTail(uri(52));nearTail(uri(53));assert(sentCount(@"AddDownload:")==gainAdds+2);acceptAdd(uri(52));acceptAdd(uri(53));complete(uri(53));
    pump(.07);emitProgress(uri(52),YES,1,10);pump(.10);assert([gainSnapshot[@"album_states"][uri(52)][@"active"]boolValue]);emitProgress(uri(52),YES,1,10);pump(.12);
    assert(sentCount(@"AddDownload:")==gainAdds+2);assert([gainSnapshot[@"album_states"][uri(52)][@"phase"] isEqual:@"failed"]);assert(contexts.count==0 && progressStreams.count==0);
    detachGain();complete(uri(52));SAPArtistSessionSetWorkTimeoutForTesting(900);

    // A peer's progress cannot reset an actively downloading operation's
    // own inactivity deadline.
    SAPArtistSessionSetWorkTimeoutForTesting(.18);ready(@[uri(64),uri(65),uri(66)]);
    __block NSDictionary *independentTimeoutSnapshot=nil;dispatch_block_t detachIndependent=SAPObserveArtistDownloadSession(@[release(64),release(65),release(66)],^(NSDictionary *s){independentTimeoutSnapshot=s;});
    before=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(64),release(65),release(66)],&error));pump(.03);nearTail(uri(64));nearTail(uri(65));acceptAdd(uri(64));acceptAdd(uri(65));emitProgress(uri(65),YES,0,1);
    for(int i=1;i<=3;i++){pump(.05);emitProgress(uri(64),YES,i,10);}pump(.05);
    assert(sentCount(@"AddDownload:")==before+2);assert([independentTimeoutSnapshot[@"album_states"][uri(65)][@"phase"]isEqual:@"failed"]);
    assert([independentTimeoutSnapshot[@"album_states"][uri(66)][@"phase"]isEqual:@"failed"]);assert(contexts.count==0 && progressStreams.count==0);
    detachIndependent();complete(uri(64));complete(uri(65));SAPArtistSessionSetWorkTimeoutForTesting(900);

    // Deadlines belong to operations. The batch can exceed one deadline when
    // each submitted album completes before its own deadline expires.
    SAPArtistSessionSetWorkTimeoutForTesting(.25);ready(@[uri(54),uri(55),uri(56)]);
    __block NSDictionary *longBatchSnapshot=nil;dispatch_block_t detachLongBatch=SAPObserveArtistDownloadSession(@[release(54),release(55),release(56)],^(NSDictionary *s){longBatchSnapshot=s;});
    NSUInteger longBatchAdds=sentCount(@"AddDownload:");NSDate *batchStart=[NSDate date];
    assert(SAPAppendArtistDownloadSessionReleases(@[release(54),release(55),release(56)],&error));pump(.03);nearTail(uri(54));nearTail(uri(55));assert(sentCount(@"AddDownload:")==longBatchAdds+2);acceptAdd(uri(54));acceptAdd(uri(55));
    pump(.13);complete(uri(54));pump(.03);assert(sentCount(@"AddDownload:")==longBatchAdds+3);acceptAdd(uri(56));complete(uri(55));pump(.13);complete(uri(56));pump(.03);
    assert(-batchStart.timeIntervalSinceNow>.25);for(int i=54;i<=56;i++)assert([longBatchSnapshot[@"album_states"][uri(i)][@"phase"] isEqual:@"downloaded"]);
    assert(contexts.count==0 && progressStreams.count==0);detachLongBatch();SAPArtistSessionSetWorkTimeoutForTesting(900);

    // Explicit scoped Stop still works after timeout. It refreshes both
    // submitted native URIs and confirms each removal without starting a third.
    SAPArtistSessionSetWorkTimeoutForTesting(.14);ready(@[uri(57),uri(58),uri(63)]);
    __block NSDictionary *postTimeoutStopSnapshot=nil;dispatch_block_t detachPostTimeoutStop=SAPObserveArtistDownloadSession(@[release(57),release(58),release(63)],^(NSDictionary *s){postTimeoutStopSnapshot=s;});
    NSUInteger postTimeoutAdds=sentCount(@"AddDownload:"),postTimeoutRemoves=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(57),release(58),release(63)],&error));pump(.03);nearTail(uri(57));nearTail(uri(58));assert(sentCount(@"AddDownload:")==postTimeoutAdds+2);acceptAdd(uri(57));acceptAdd(uri(58));
    native[uri(57)]=@4;native[uri(58)]=@4;emitState(@[uri(57),uri(58)]);pump(.19);assert(sentCount(@"AddDownload:")==postTimeoutAdds+2);assert(contexts.count==0 && progressStreams.count==0);
    NSUInteger beforeStopRead=reads;SAPStopArtistDownloadSessionReleases(@[release(57),release(58),release(63)]);pump(.03);
    assert(reads==beforeStopRead+2);NSArray *stopReads=[readURIs subarrayWithRange:NSMakeRange(readURIs.count-2,2)];assert([NSSet setWithArray:stopReads].count==2);assert([stopReads containsObject:@[uri(57)]] && [stopReads containsObject:@[uri(58)]]);
    assert(sentCount(@"RemoveDownload:")==postTimeoutRemoves+2);assert(contexts.count>0 && progressStreams.count>0);
    finishRemove(uri(58));pump(.02);assert(contexts.count>0 && progressStreams.count>0);finishRemove(uri(57));pump(.04);
    for(NSString *u in @[uri(57),uri(58)]){assert(![postTimeoutStopSnapshot[@"album_states"][u][@"active"]boolValue]);assert(![postTimeoutStopSnapshot[@"album_states"][u][@"stopping"]boolValue]);}
    assert(sentCount(@"AddDownload:")==postTimeoutAdds+2);assert(contexts.count==0 && progressStreams.count==0);detachPostTimeoutStop();SAPArtistSessionSetWorkTimeoutForTesting(900);
    // An Add ACK with no native activity cannot make a later state zero
    // terminal. The paused reservation and its unknown tail hold a prepared
    // successor until an explicit Stop obtains native removal confirmation.
    SAPArtistSessionSetWorkTimeoutForTesting(.14);ready(@[uri(138),uri(139)]);
    dispatch_block_t detachUnprovenZero=SAPObserveArtistDownloadSession(@[release(138),release(139)],nil);pump(.03);
    before=sentCount(@"AddDownload:");removes=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(138)],&error));pump(.03);acceptAdd(uri(138));pump(.19);
    assert(sentCount(@"AddDownload:")==before+1 && sentCount(@"RemoveDownload:")==removes);assertSubmitted(@[uri(138)]);
    assert(contexts.count==0 && progressStreams.count==0);NSUInteger recoveryReads=readURIs.count;
    assert(SAPAppendArtistDownloadSessionReleases(@[release(139)],&error));pump(.03);
    NSArray *freshRecoveryReads=[readURIs subarrayWithRange:NSMakeRange(recoveryReads,readURIs.count-recoveryReads)];
    assert([freshRecoveryReads containsObject:@[uri(138)]] && [freshRecoveryReads containsObject:@[uri(139)]]);
    assert(sentCount(@"AddDownload:")==before+1 && sentCount(@"RemoveDownload:")==removes);assertSubmitted(@[uri(138)]);
    assert(sentExactCount([@"AddDownload:" stringByAppendingString:uri(138)])==1 && sentExactCount([@"AddDownload:" stringByAppendingString:uri(139)])==0);
    SAPStopArtistDownloadSessionRelease(uri(138));pump(.03);assert(sentCount(@"RemoveDownload:")==removes+1 && sentCount(@"AddDownload:")==before+1);
    finishRemove(uri(138));pump(.03);assert(sentCount(@"AddDownload:")==before+2);assertSubmitted(@[uri(139)]);
    acceptAdd(uri(139));complete(uri(139));pump(.02);detachUnprovenZero();SAPArtistSessionSetWorkTimeoutForTesting(900);

    // A renewal starts every replacement lease before retiring the proven
    // old generation. Its first response may arrive later.
    autoStreamResponses=YES;ready(@[uri(7100),uri(7101)]);__block NSDictionary *leaseSnapshot=nil;
    dispatch_block_t detachLease=SAPObserveArtistDownloadSession(@[release(7100),release(7101)],^(NSDictionary *s){leaseSnapshot=s;});
    before=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(7100),release(7101)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")>=before+1;});pump(.01);
    assert(sentCount(@"AddDownload:")==before+1);NSArray *oldContextKeys=contexts.allKeys,*oldProgressKeys=progressStreams.allKeys;
    void(^oldLeaseCallback)(NSData*,NSString*)=[contexts.allValues.firstObject copy];assert(oldLeaseCallback);
    NSUInteger renewalEventOffset=streamLeaseEvents.count;holdStreamResponses=YES;nearTail(uri(7100));pump(.02);assert(sentCount(@"AddDownload:")==before+2);
    NSUInteger replacementStarts=0;for(NSString *event in [streamLeaseEvents subarrayWithRange:NSMakeRange(renewalEventOffset,streamLeaseEvents.count-renewalEventOffset)]){
        if([event hasPrefix:@"start:"])replacementStarts++;if([event hasPrefix:@"cancel:"])assert(replacementStarts>=2);
    }
    assert(replacementStarts>=2);
    assert(heldStreamResponses.count>0);holdStreamResponses=NO;releaseStreamResponses();
    for(NSString *key in oldContextKeys)assert(!contexts[key]);for(NSString *key in oldProgressKeys)assert(!progressStreams[key]);
    oldLeaseCallback(stateDataFrom(@[uri(7100)],@{uri(7100):@1}),nil);pump(.01);
    assert(![leaseSnapshot[@"album_states"][uri(7100)][@"phase"]isEqual:@"failed"]);
    acceptAdd(uri(7100));acceptAdd(uri(7101));complete(uri(7100));complete(uri(7101));pump(.02);detachLease();
    puts("PASS: artist stream renewal starts replacement leases before retiring the proven old generation and ignores late retired callbacks");

    // A transient observation failure retains the third queued URI and both
    // owned slots. Healthy status alone cannot replace reliable tail evidence.
    SAPArtistSessionSetRepairTimeoutForTesting(.75);ready(@[uri(7110),uri(7111),uri(7112)]);
    NSMutableArray *repairCatalog=[NSMutableArray array];for(int n=7110;n<7175;n++)[repairCatalog addObject:release(n)];
    __block NSDictionary *repairSnapshot=nil;dispatch_block_t detachRepair=SAPObserveArtistDownloadSession(repairCatalog,^(NSDictionary *s){repairSnapshot=s;});
    before=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(7110),release(7111),release(7112)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")>=before+1;});pump(.01);
    assert(sentCount(@"AddDownload:")==before+1);native[uri(7110)]=@4;holdStreamResponses=YES;
    void(^preRepairCallback)(NSData*,NSString*)=[contexts.allValues.firstObject copy];void(^preRepairProgress)(NSData*,NSString*)=[progressStreams.allValues.firstObject copy];failStream();pump(.03);
    acceptAdd(uri(7110));preRepairProgress(progressData(@[uri(7110)],NO,0,1,0,1024),nil);pump(.02);assert(sentCount(@"AddDownload:")==before+1);
    assert([repairSnapshot[@"album_states"][uri(7112)][@"phase"]isEqual:@"queued"]);
    assert(heldStreamResponses.count>=4);NSArray *chunkReplies=[heldStreamResponses copy];[heldStreamResponses removeAllObjects];
    dispatch_block_t lastChunk=chunkReplies.firstObject;for(NSUInteger i=1;i<chunkReplies.count;i++){dispatch_block_t reply=chunkReplies[i];reply();}pump(.01);
    assert(sentCount(@"AddDownload:")==before+1);nearTail(uri(7110));pump(.01);assert(sentCount(@"AddDownload:")==before+1);
    holdStreamResponses=NO;lastChunk();waitForSession(^BOOL{return sentCount(@"AddDownload:")==before+2;});
    acceptAdd(uri(7111));nearTail(uri(7111));assert(sentCount(@"AddDownload:")==before+2);
    preRepairCallback(nil,@"late retired stream failure");pump(.01);complete(uri(7110));pump(.03);
    assert(sentCount(@"AddDownload:")==before+3);acceptAdd(uri(7112));complete(uri(7111));complete(uri(7112));pump(.02);
    for(int n=7110;n<=7112;n++)assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(n)])==1);
    detachRepair();puts("PASS: transient stream repair preserves queue, pending Add ACK, max-two capacity and fresh trustworthy tail admission without replay");

    // Exhaustion produces a quiet pause with the unsent queue intact. An
    // explicit append resumes observation and never repeats the acknowledged Add.
    ready(@[uri(7120),uri(7121),uri(7122)]);__block NSDictionary *exhaustedSnapshot=nil;
    dispatch_block_t detachExhausted=SAPObserveArtistDownloadSession(@[release(7120),release(7121),release(7122)],^(NSDictionary *s){exhaustedSnapshot=s;});
    before=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(7120),release(7121),release(7122)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")>=before+1;});pump(.01);
    acceptAdd(uri(7120));native[uri(7120)]=@4;NSUInteger repairLogOffset=repairJournal.count;failContextReads=YES;failStream();pump(.25);
    assert(sentCount(@"AddDownload:")==before+1 && [exhaustedSnapshot[@"album_states"][uri(7122)][@"phase"]isEqual:@"queued"]);
    NSUInteger repairAttemptCount=0,repairFailureCount=0;for(NSDictionary *event in [repairJournal subarrayWithRange:NSMakeRange(repairLogOffset,repairJournal.count-repairLogOffset)]){if([event[@"event"]isEqual:@"artist_observation_repair_attempt"])repairAttemptCount++;if([event[@"event"]isEqual:@"artist_observation_repair_read_failed"]){assert([event[@"facts"][@"error"]isEqual:@"No verified Spotify stream transport is available"]);repairFailureCount++;}}assert(repairAttemptCount==2 && repairFailureCount==2);
    NSUInteger exhaustedReads=reads,exhaustedStreams=streamStarts;pump(.25);
    assert(reads==exhaustedReads && streamStarts==exhaustedStreams);assert(contexts.count==0 && progressStreams.count==0);
    failContextReads=NO;assert(SAPAppendArtistDownloadSessionReleases(@[release(7122)],&error));pump(.04);
    assert(sentCount(@"AddDownload:")==before+1);nearTail(uri(7120));pump(.03);assert(sentCount(@"AddDownload:")==before+2);
    acceptAdd(uri(7121));nearTail(uri(7121));complete(uri(7120));pump(.03);assert(sentCount(@"AddDownload:")==before+3);
    acceptAdd(uri(7122));complete(uri(7121));complete(uri(7122));pump(.02);detachExhausted();
    assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(7120)])==1);
    puts("PASS: exhausted observation repair preserves queued work, stops all automatic retries, and resumes explicitly without Add replay");

    // Stop during repair still owns the original Add callback. It clears only
    // the scoped unsent URI, waits for that ACK, and preserves another artist.
    ready(@[uri(7130),uri(7131),uri(7132)]);__block NSDictionary *stopRepairSnapshot=nil;
    dispatch_block_t detachStopRepair=SAPObserveArtistDownloadSession(@[release(7130),release(7131),release(7132)],^(NSDictionary *s){stopRepairSnapshot=s;});
    before=sentCount(@"AddDownload:");removes=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(7130),release(7131),release(7132)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")>=before+1;});pump(.01);
    holdStreamResponses=YES;native[uri(7130)]=@4;failStream();pump(.02);
    SAPStopArtistDownloadSessionReleases(@[release(7130),release(7132)]);pump(.02);
    assert(sentCount(@"RemoveDownload:")==removes && sentCount(@"AddDownload:")==before+1);
    acceptAdd(uri(7130));pump(.03);assert(sentExactCount([@"RemoveDownload:"stringByAppendingString:uri(7130)])==1);
    holdStreamResponses=NO;releaseStreamResponses();finishRemove(uri(7130));pump(.04);
    assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(7132)])==0);
    assert(sentCount(@"AddDownload:")==before+2 && sentExactCount([@"AddDownload:"stringByAppendingString:uri(7131)])==1);
    acceptAdd(uri(7131));complete(uri(7131));pump(.03);detachStopRepair();
    assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(7130)])==1);
    assert(![stopRepairSnapshot[@"album_states"][uri(7130)][@"active"]boolValue]);
    SAPArtistSessionSetRepairTimeoutForTesting(30);
    puts("PASS: scoped Stop during observation repair waits for the original pending Add ACK and late verification never restarts stopped work");

    // A canceled verification read may still deliver a native callback after
    // Stop All. The callback cannot recreate its removed queue or replay Add.
    ready(@[uri(7140),uri(7141),uri(7142)]);dispatch_block_t detachLateVerification=SAPObserveArtistDownloadSession(@[release(7140),release(7141),release(7142)],nil);
    before=sentCount(@"AddDownload:");removes=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(7140),release(7141),release(7142)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")>=before+1;});pump(.01);
    assert(sentCount(@"AddDownload:")==before+1);native[uri(7140)]=@4;holdNextContextRead=YES;failStream();pump(.01);assert(heldVerificationRead);
    SAPStopArtistDownloadSession();pump(.01);assert(sentCount(@"RemoveDownload:")==removes);
    acceptAdd(uri(7140));pump(.03);assert(sentCount(@"RemoveDownload:")==removes+1);finishRemove(uri(7140));pump(.02);
    dispatch_block_t obsoleteVerification=heldVerificationRead;heldVerificationRead=nil;obsoleteVerification();pump(.05);
    assert(sentCount(@"AddDownload:")==before+1 && sentCount(@"RemoveDownload:")==removes+1);
    assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(7141)])==0 && sentExactCount([@"AddDownload:"stringByAppendingString:uri(7142)])==0);
    assert(contexts.count==0 && progressStreams.count==0);detachLateVerification();
    puts("PASS: Stop All cancels in-flight repair verification, waits pending Add ACK, and ignores its late read callback without restarting the queue");

    // Briefly healthy streams are not useful native progress. Repeated
    // failure/repair cycles exhaust one shared budget until explicit resume.
    ready(@[uri(7150),uri(7151),uri(7152)]);__block NSDictionary *cyclingSnapshot=nil;
    dispatch_block_t detachCycling=SAPObserveArtistDownloadSession(@[release(7150),release(7151),release(7152)],^(NSDictionary *s){cyclingSnapshot=s;});
    before=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[release(7150),release(7151),release(7152)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")>=before+1;});pump(.01);
    assert(sentCount(@"AddDownload:")==before+1);acceptAdd(uri(7150));native[uri(7150)]=@4;
    for(NSUInteger episode=0;episode<2;episode++){
        NSUInteger episodeJournalStart=repairJournal.count;failStream();
        waitForSession(^BOOL{for(NSUInteger i=episodeJournalStart;i<repairJournal.count;i++)if([repairJournal[i][@"event"]isEqual:@"artist_observation_repaired"])return YES;return NO;});
        assert(contexts.count>0 && progressStreams.count>0);
        assert(sentCount(@"AddDownload:")==before+1 && [cyclingSnapshot[@"album_states"][uri(7152)][@"phase"]isEqual:@"queued"]);
    }
    NSUInteger cycleReads=reads,cycleStreams=streamStarts,cycleLogOffset=repairJournal.count;failStream();pump(.05);
    assert(reads==cycleReads && streamStarts==cycleStreams && contexts.count==0 && progressStreams.count==0);
    NSUInteger circuitBreaks=0;for(NSDictionary *event in [repairJournal subarrayWithRange:NSMakeRange(cycleLogOffset,repairJournal.count-cycleLogOffset)])if([event[@"event"]isEqual:@"artist_observation_repair_budget_exhausted"]){assert([event[@"facts"][@"episodes_without_native_progress"]unsignedIntegerValue]==2 && [event[@"facts"][@"max_episodes_without_native_progress"]unsignedIntegerValue]==2);circuitBreaks++;}assert(circuitBreaks==1);
    assert([cyclingSnapshot[@"album_states"][uri(7152)][@"phase"]isEqual:@"queued"]);pump(.12);
    assert(reads==cycleReads && streamStarts==cycleStreams && sentCount(@"AddDownload:")==before+1);
    assert(SAPAppendArtistDownloadSessionReleases(@[release(7152)],&error));pump(.04);
    assert(contexts.count>0 && progressStreams.count>0 && sentCount(@"AddDownload:")==before+1);
    nearTail(uri(7150));pump(.02);assert(sentCount(@"AddDownload:")==before+2);acceptAdd(uri(7151));nearTail(uri(7151));complete(uri(7150));pump(.03);
    assert(sentCount(@"AddDownload:")==before+3);acceptAdd(uri(7152));complete(uri(7151));complete(uri(7152));pump(.02);detachCycling();
    for(int n=7150;n<=7152;n++)assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(n)])==1);
    puts("PASS: repeated shallow healthy stream repairs exhaust a shared finite budget, preserve the queue without more RPCs, and require explicit resume");
    // Verified one-track releases submit two real commands without requiring
    // a progress tail. Unknown/multi-track fixtures above keep their old gate.
    ready(@[uri(7160),uri(7161),uri(7162)]);
    NSMutableArray *singles=[NSMutableArray array];
    for(int n=7160;n<=7162;n++){NSMutableDictionary *item=[release(n)mutableCopy];item[@"type"]=@2;item[@"track_count_verified"]=@YES;item[@"verified_track_count"]=@1;[singles addObject:item];}
    NSUInteger pairedAdds=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(singles,&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==pairedAdds+2;});
    assertSubmitted(@[uri(7160),uri(7161)]);pump(.03);assert(sentCount(@"AddDownload:")==pairedAdds+2);
    BOOL observesPair=NO;for(NSArray *request in nativeDefaultContexts)if([request containsObject:uri(7160)] && [request containsObject:uri(7161)])observesPair=YES;assert(observesPair);
    for(NSDictionary *request in contextRequests.allValues)if([request[@"state_only"]boolValue])assert(![request[@"uris"]containsObject:uri(7160)] && ![request[@"uris"]containsObject:uri(7161)]);
    acceptAdd(uri(7160));acceptAdd(uri(7161));pump(.02);assert(sentCount(@"AddDownload:")==pairedAdds+2);
    complete(uri(7161));pump(.03);assert(sentCount(@"AddDownload:")==pairedAdds+2);assertSubmitted(@[uri(7160)]);
    complete(uri(7160));waitForSession(^BOOL{return sentCount(@"AddDownload:")==pairedAdds+3;});assertSubmitted(@[uri(7162)]);
    acceptAdd(uri(7162));complete(uri(7162));pump(.03);assert(contexts.count==0 && progressStreams.count==0);
    puts("PASS: two verified singles submit before native progress; the faster member never admits a third ahead of its waiting peer; native observations have one context policy per submitted URI, are bounded and cleaned up");
    // Separate artist calls share the same pair and cannot starve its older
    // member. Missing embedded counts are fetched only for selected singles.
    ready(@[uri(7170),uri(7171),uri(7172)]);verifiedFixtureTrackCounts=[NSMutableDictionary dictionaryWithDictionary:@{uri(7170):@1,uri(7171):@1,uri(7172):@1}];
    NSMutableArray *crossArtist=[NSMutableArray array];for(int n=7170;n<=7172;n++){NSMutableDictionary *item=[release(n)mutableCopy];item[@"type"]=@2;item[@"artist_uri"]=n==7170?@"artist A":@"artist B";[crossArtist addObject:item];}
    NSUInteger crossAdds=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[crossArtist[0]],&error));assert(SAPAppendArtistDownloadSessionReleases(@[crossArtist[1],crossArtist[2]],&error));
    waitForSession(^BOOL{return sentCount(@"AddDownload:")==crossAdds+2;});assertSubmitted(@[uri(7170),uri(7171)]);acceptAdd(uri(7170));acceptAdd(uri(7171));complete(uri(7171));pump(.03);assert(sentCount(@"AddDownload:")==crossAdds+2);
    complete(uri(7170));waitForSession(^BOOL{return sentCount(@"AddDownload:")==crossAdds+3;});acceptAdd(uri(7172));complete(uri(7172));pump(.02);
    puts("PASS: separate artists share one fair two-single window; selected singles with missing embedded membership receive a bounded metadata read before admission");
    // A playlist append invalidates an older completed snapshot; it must issue
    // the native playlist action and await fresh native completion evidence.
    NSString *playlistURI=@"spotify:playlist:0000000000000000000001";native[playlistURI]=@3;
    NSDictionary *playlistContext=@{@"uri":playlistURI,@"name":@"Updated playlist",@"refresh_after_append":@YES};
    NSUInteger playlistAdds=sentCount(@"AddDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[playlistContext],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==playlistAdds+1;});assertSubmitted(@[playlistURI]);native[playlistURI]=@4;acceptAdd(playlistURI);emitState(@[playlistURI]);pump(.02);complete(playlistURI);pump(.02);
    puts("PASS: mutable playlist refresh uses its own native command reply envelope and never treats the pre-append downloaded snapshot as new completion");
    NSString *stoppedPlaylist=@"spotify:playlist:0000000000000000000002";native[stoppedPlaylist]=@0;playlistAdds=sentCount(@"AddDownload:");NSUInteger playlistRemoves=sentCount(@"RemoveDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[@{@"uri":stoppedPlaylist,@"name":@"Stop playlist"}],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==playlistAdds+1;});
    SAPStopArtistDownloadSessionRelease(stoppedPlaylist);pump(.02);assert(sentCount(@"RemoveDownload:")==playlistRemoves);acceptAdd(stoppedPlaylist);waitForSession(^BOOL{return sentCount(@"RemoveDownload:")==playlistRemoves+1;});finishRemove(stoppedPlaylist);pump(.02);
    puts("PASS: playlist Stop waits for its original pending native SetOfflineState ACK and confirms removal through the playlist response envelope");
    ready(@[uri(7200),uri(7201)]);NSArray *resumeScope=@[release(7200),release(7201)];__block NSDictionary *resumeSnapshot=nil;
    dispatch_block_t detachResume=SAPObserveArtistDownloadSession(resumeScope,^(NSDictionary *v){resumeSnapshot=v;});NSUInteger resumeAdds=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(resumeScope,&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==resumeAdds+1;});
    emitProgress(uri(7200),YES,5,10);
    SAPStopArtistDownloadSessionReleases(resumeScope);assert(![resumeSnapshot[@"album_states"][uri(7200)][@"can_continue"]boolValue]);assert(SAPContinueArtistDownloadSessionReleases(@[release(7200)],&error));pump(.02);assert(sentCount(@"AddDownload:")==resumeAdds+1);
    acceptAdd(uri(7200));waitForSession(^BOOL{return removeReplies[uri(7200)]!=nil;});finishRemove(uri(7200));waitForSession(^BOOL{return [resumeSnapshot[@"album_states"][uri(7200)][@"can_continue"]boolValue];});
    assert([resumeSnapshot[@"album_states"][uri(7201)][@"can_continue"]boolValue]);assert(fabs([resumeSnapshot[@"album_states"][uri(7200)][@"stopped_visual"][@"progress"]doubleValue]-.5)<.001);NSUInteger continueFreshReads=reads;
    assert(SAPContinueArtistDownloadSessionReleases(resumeScope,&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==resumeAdds+2;});assert([resumeSnapshot[@"album_states"][uri(7200)][@"stopped_visual"]count]==0);assert(reads>continueFreshReads);assertSubmitted(@[uri(7200)]);acceptAdd(uri(7200));complete(uri(7200));waitForSession(^BOOL{return sentCount(@"AddDownload:")==resumeAdds+3;});acceptAdd(uri(7201));complete(uri(7201));pump(.03);assert(![resumeSnapshot[@"album_states"][uri(7200)][@"can_continue"]boolValue]);detachResume();
    puts("PASS: Continue retains stopped queued intents in order, waits for pending Add and native Stop confirmation, performs fresh preflight and clears completed intents");
    native[uri(7210)]=@3;__block NSDictionary *staleSnapshot=nil;
    dispatch_block_t detachStale=SAPObserveArtistDownloadSession(@[release(7210)],^(NSDictionary *v){staleSnapshot=v;});waitForSession(^BOOL{return [staleSnapshot[@"album_states"][uri(7210)][@"state"]isEqual:@"downloaded"];});
    native[uri(7210)]=@0;members[uri(7210)]=@YES;NSUInteger staleAdds=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[release(7210)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==staleAdds+1;});acceptAdd(uri(7210));complete(uri(7210));pump(.02);detachStale();
    puts("PASS: a cached complete context cannot suppress a new request after native files are removed; fresh preflight determines whether Add is required");
    // A growing catalog must read only its added contexts. Foreground refresh
    // still asks Spotify for a complete fresh snapshot.
    NSMutableArray *largeCatalog=[NSMutableArray array];for(int n=9000;n<9723;n++){[largeCatalog addObject:release(n)];native[uri(n)]=@0;}
    NSUInteger incrementalReads=reads,incrementalURIStart=readURIs.count,oldStrategyReads=0;__block NSDictionary *incrementalSnapshot=nil;
    SAPArtistSessionObservation *incremental=SAPObserveArtistSession(@[],^(NSDictionary *v){incrementalSnapshot=v;});
    for(NSUInteger end=32;;end+=32){NSUInteger count=MIN(end,largeCatalog.count);[incremental extendReleases:[largeCatalog subarrayWithRange:NSMakeRange(0,count)]];oldStrategyReads+=2*((count+63)/64);if(count==largeCatalog.count)break;}
    assert(reads-incrementalReads==46 && oldStrategyReads==288);pump(.05);NSMutableDictionary *seenContexts=[NSMutableDictionary dictionary];for(NSUInteger i=incrementalURIStart;i<readURIs.count;i++)for(NSString *u in readURIs[i])seenContexts[u]=@([seenContexts[u]unsignedIntegerValue]+1);assert(seenContexts.count==723);for(NSNumber *count in seenContexts.allValues)assert(count.intValue==1);
    incrementalReads=reads;for(int n=0;n<20;n++)[incremental extendReleases:largeCatalog];assert(reads==incrementalReads);
    native[uri(9000)]=@3;[incremental refresh];assert(reads==incrementalReads+24);waitForSession(^BOOL{return [incrementalSnapshot[@"album_states"][uri(9000)][@"state"]isEqual:@"downloaded"];});[incremental invalidate];
    holdCatalogReads=YES;__block NSUInteger closedCallbacks=0;__block NSDictionary *otherSnapshot=nil;
    SAPArtistSessionObservation *closedOwner=SAPObserveArtistSession(@[release(9800),release(9801)],^(__unused NSDictionary *v){closedCallbacks++;});
    native[uri(9810)]=native[uri(9811)]=@3;SAPArtistSessionObservation *otherOwner=SAPObserveArtistSession(@[release(9810),release(9811)],^(NSDictionary *v){otherSnapshot=v;});
    NSUInteger closedBefore=closedCallbacks;[closedOwner invalidate];NSArray *lateReads=[heldInitialReads copy];[heldInitialReads removeAllObjects];for(dispatch_block_t reply in lateReads)reply();pump(.03);assert(closedCallbacks==closedBefore && [otherSnapshot[@"album_states"][uri(9810)][@"state"]isEqual:@"downloaded"]);[otherOwner invalidate];holdCatalogReads=NO;
    puts("PASS: 723 progressive releases use 46 initial RPCs instead of 288 cumulative rereads; each URI is read once, 20 identical extensions issue no RPCs, explicit refresh reads all 723 again, and closing one owner suppresses its late replies without canceling another owner");
    NSString *feedURI=@"spotify:playlist:0000000000000000000011";native[feedURI]=@0;__block NSDictionary *feedSnapshot=nil;dispatch_block_t detachFeed=SAPObserveArtistDownloadSession(@[@{@"uri":feedURI}],^(NSDictionary *v){feedSnapshot=v;});NSUInteger feedAdds=sentCount(@"AddDownload:");
    assert(SAPAppendArtistDownloadSessionReleases(@[@{@"uri":feedURI,@"incremental_playlist":@YES,@"refresh_after_append":@YES}],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==feedAdds+1;});native[feedURI]=@4;emitState(@[feedURI]);complete(feedURI);acceptAdd(feedURI);pump(.02);assert([feedSnapshot[@"album_states"][feedURI][@"owned"]boolValue] && [feedSnapshot[@"album_states"][feedURI][@"download_submitted"]boolValue]);
    native[feedURI]=@4;emitState(@[feedURI]);native[feedURI]=@3;emitState(@[feedURI]);assert(sentCount(@"AddDownload:")==feedAdds+1);SAPClosePlaylistDownloadFeed(feedURI);assert(![feedSnapshot[@"album_states"][feedURI][@"owned"]boolValue]);detachFeed();
    puts("PASS: incremental playlist ownership survives a completed pair before the original ACK, later pairs reuse the native offline context, and closing a completed feed releases its slot without another SetOfflineState");
    NSString *cancelFeedURI=@"spotify:playlist:0000000000000000000012";native[cancelFeedURI]=@0;__block NSDictionary *cancelFeedSnapshot=nil;
    dispatch_block_t detachCancelFeed=SAPObserveArtistDownloadSession(@[@{@"uri":cancelFeedURI}],^(NSDictionary *v){cancelFeedSnapshot=v;});
    assert(SAPAppendArtistDownloadSessionReleases(@[@{@"uri":cancelFeedURI,@"incremental_playlist":@YES,@"refresh_after_append":@YES}],&error));waitForSession(^BOOL{return addReplies[cancelFeedURI]!=nil;});
    NSUInteger removesBeforeCancel=sentCount(@"RemoveDownload:");SAPStopArtistDownloadSessionRelease(cancelFeedURI);assert(sentCount(@"RemoveDownload:")==removesBeforeCancel && [cancelFeedSnapshot[@"album_states"][cancelFeedURI][@"owned"]boolValue]);
    acceptAdd(cancelFeedURI);waitForSession(^BOOL{return removeReplies[cancelFeedURI]!=nil;});assert(sentCount(@"RemoveDownload:")==removesBeforeCancel+1);finishRemove(cancelFeedURI);SAPClosePlaylistDownloadFeed(cancelFeedURI);SAPForgetPlaylistDownloadIntent(cancelFeedURI);assert(![cancelFeedSnapshot[@"album_states"][cancelFeedURI][@"owned"]boolValue] && ![cancelFeedSnapshot[@"can_continue"]boolValue]);detachCancelFeed();
    puts("PASS: hard playlist cancellation waits for the original pending Add ACK, stops through the native playlist envelope exactly once, and removes the canceled Continue intent after Stop confirmation");
    NSString *fullFeedURI=@"spotify:playlist:0000000000000000000013";native[fullFeedURI]=@0;__block NSDictionary *fullFeedSnapshot=nil;dispatch_block_t detachFullFeed=SAPObserveArtistDownloadSession(@[@{@"uri":fullFeedURI}],^(NSDictionary *v){fullFeedSnapshot=v;});
    assert(SAPAppendArtistDownloadSessionReleases(@[@{@"uri":fullFeedURI,@"incremental_playlist":@YES}],&error));waitForSession(^BOOL{return addReplies[fullFeedURI]!=nil;});acceptAdd(fullFeedURI);native[fullFeedURI]=@3;emitState(@[fullFeedURI]);assert([fullFeedSnapshot[@"album_states"][fullFeedURI][@"owned"]boolValue]);SAPStopArtistDownloadSessionRelease(fullFeedURI);waitForSession(^BOOL{return removeReplies[fullFeedURI]!=nil;});assert([fullFeedSnapshot[@"album_states"][fullFeedURI][@"owned"]boolValue]);finishRemove(fullFeedURI);SAPForgetPlaylistDownloadIntent(fullFeedURI);assert(![fullFeedSnapshot[@"album_states"][fullFeedURI][@"owned"]boolValue]);detachFullFeed();
    ready(@[uri(10500),uri(10501)]);NSMutableArray *busySingles=[NSMutableArray array];for(int n=10500;n<=10501;n++){NSMutableDictionary *item=[release(n)mutableCopy];item[@"type"]=@2;item[@"track_count_verified"]=@YES;item[@"verified_track_count"]=@1;[busySingles addObject:item];}assert(SAPAppendArtistDownloadSessionReleases(busySingles,&error));waitForSession(^BOOL{return addReplies[uri(10500)]!=nil && addReplies[uri(10501)]!=nil;});
    NSString *queuedFeedURI=@"spotify:playlist:0000000000000000000014";native[queuedFeedURI]=@3;__block NSDictionary *queuedFeedSnapshot=nil;dispatch_block_t detachQueuedFeed=SAPObserveArtistDownloadSession(@[@{@"uri":queuedFeedURI}],^(NSDictionary *v){queuedFeedSnapshot=v;});assert(SAPAppendArtistDownloadSessionReleases(@[@{@"uri":queuedFeedURI,@"incremental_playlist":@YES}],&error));SAPStopArtistDownloadSessionRelease(queuedFeedURI);waitForSession(^BOOL{return removeReplies[queuedFeedURI]!=nil;});finishRemove(queuedFeedURI);SAPForgetPlaylistDownloadIntent(queuedFeedURI);assert(![queuedFeedSnapshot[@"album_states"][queuedFeedURI][@"stop_pending"]boolValue] && ![queuedFeedSnapshot[@"can_continue"]boolValue]);acceptAdd(uri(10500));acceptAdd(uri(10501));complete(uri(10500));complete(uri(10501));detachQueuedFeed();
    puts("PASS: a full incremental playlist and a queued existing offline playlist are explicitly disabled too; cached completion cannot let a late append restart canceled downloads");
    NSString *ownerA=@"spotify:artist:0000000000000000000101",*ownerB=@"spotify:artist:0000000000000000000102";ready(@[uri(10300),uri(10301),uri(10310)]);
    NSDictionary *(^ownedRelease)(int,NSString *)=^NSDictionary *(int n,NSString *artist){NSMutableDictionary *v=[release(n)mutableCopy];v[@"artist_uri"]=artist;return v;};__block NSDictionary *ownerSnapshotA=nil,*ownerSnapshotB=nil;
    SAPArtistSessionObservation *ownerObservationA=SAPObserveArtistSessionForArtist(ownerA,@[release(10300),release(10301)],^(NSDictionary *v){ownerSnapshotA=v;});SAPArtistSessionObservation *ownerObservationB=SAPObserveArtistSessionForArtist(ownerB,@[release(10300),release(10310)],^(NSDictionary *v){ownerSnapshotB=v;});
    NSUInteger ownerAdds=sentCount(@"AddDownload:"),ownerRemoves=sentCount(@"RemoveDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[ownedRelease(10300,ownerA),ownedRelease(10301,ownerA)],&error));waitForSession(^BOOL{return sentCount(@"AddDownload:")==ownerAdds+1;});assert(SAPAppendArtistDownloadSessionReleases(@[ownedRelease(10300,ownerB),ownedRelease(10310,ownerB)],&error));SAPCancelArtistDownloadSession(ownerA);assert(![ownerSnapshotA[@"can_cancel"]boolValue] && ![ownerSnapshotA[@"can_continue"]boolValue] && [ownerSnapshotB[@"can_cancel"]boolValue]);assert(sentCount(@"RemoveDownload:")==ownerRemoves);acceptAdd(uri(10300));complete(uri(10300));waitForSession(^BOOL{return addReplies[uri(10310)]!=nil;});acceptAdd(uri(10310));complete(uri(10310));assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(10301)])==0);[ownerObservationA invalidate];[ownerObservationB invalidate];
    ready(@[uri(10400),uri(10401),uri(10410)]);ownerAdds=sentCount(@"AddDownload:");ownerRemoves=sentCount(@"RemoveDownload:");ownerObservationA=SAPObserveArtistSessionForArtist(ownerA,@[release(10400),release(10401)],^(NSDictionary *v){ownerSnapshotA=v;});ownerObservationB=SAPObserveArtistSessionForArtist(ownerB,@[release(10410)],^(NSDictionary *v){ownerSnapshotB=v;});assert(SAPAppendArtistDownloadSessionReleases(@[ownedRelease(10400,ownerA),ownedRelease(10401,ownerA)],&error));waitForSession(^BOOL{return addReplies[uri(10400)]!=nil;});assert(SAPAppendArtistDownloadSessionReleases(@[ownedRelease(10410,ownerB)],&error));SAPCancelArtistDownloadSession(ownerA);assert(sentCount(@"RemoveDownload:")==ownerRemoves && ![ownerSnapshotA[@"can_continue"]boolValue]);acceptAdd(uri(10400));waitForSession(^BOOL{return removeReplies[uri(10400)]!=nil;});finishRemove(uri(10400));waitForSession(^BOOL{return addReplies[uri(10410)]!=nil;});acceptAdd(uri(10410));complete(uri(10410));assert(![ownerSnapshotA[@"can_continue"]boolValue] && sentExactCount([@"AddDownload:"stringByAppendingString:uri(10401)])==0);[ownerObservationA invalidate];[ownerObservationB invalidate];
    puts("PASS: Cancel removes only its artist's queued/exclusive work, preserves a shared release needed by another artist, waits for the original pending ACK, and never exposes a Continue intent for canceled work");
    ready(@[uri(10600)]);NSDictionary *taskA=@{@"uri":uri(10600),@"artist_uri":ownerA,@"owner_token":@"task-a"},*taskB=@{@"uri":uri(10600),@"artist_uri":ownerA,@"owner_token":@"task-b"};NSUInteger taskRemoves=sentCount(@"RemoveDownload:");assert(SAPAppendArtistDownloadSessionReleases(@[taskA],&error));waitForSession(^BOOL{return addReplies[uri(10600)]!=nil;});assert(SAPAppendArtistDownloadSessionReleases(@[taskB],&error));assert(!SAPCancelArtistDownloadOwner(ownerA,@"task-a") && sentCount(@"RemoveDownload:")==taskRemoves);acceptAdd(uri(10600));complete(uri(10600));
    ready(@[uri(10610)]);taskA=@{@"uri":uri(10610),@"artist_uri":ownerA,@"owner_token":@"exclusive-task"};assert(SAPAppendArtistDownloadSessionReleases(@[taskA],&error));waitForSession(^BOOL{return addReplies[uri(10610)]!=nil;});assert(SAPCancelArtistDownloadOwner(ownerA,@"exclusive-task"));acceptAdd(uri(10610));waitForSession(^BOOL{return removeReplies[uri(10610)]!=nil;});finishRemove(uri(10610));assert(!SAPCancelArtistDownloadOwner(ownerA,@"exclusive-task"));
    puts("PASS: task leases distinguish two playlist jobs of one artist; canceling one shared owner sends no Remove, while exclusive cancellation waits for its original pending ACK");
    ready(@[uri(10700),uri(10701)]);neverInvokedURI=uri(10700);__block NSDictionary *notSentSnapshot=nil;dispatch_block_t detachNotSent=SAPObserveArtistDownloadSession(@[release(10700),release(10701)],^(NSDictionary *v){notSentSnapshot=v;});assert(SAPAppendArtistDownloadSessionReleases(@[release(10700),release(10701)],&error));waitForSession(^BOOL{return addReplies[uri(10701)]!=nil;});assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(10700)])==0 && [notSentSnapshot[@"album_states"][uri(10700)][@"phase"]isEqual:@"failed"] && ![notSentSnapshot[@"album_states"][uri(10700)][@"owned"]boolValue]);acceptAdd(uri(10701));complete(uri(10701));detachNotSent();neverInvokedURI=nil;
    puts("PASS: definitely uninvoked Add reports a real failure and releases its queue slot, so another job can progress; no failed mutation is automatically retried");
    // Reserving the entire accepted batch makes future append readiness
    // independent of FIFO position. A later direct job waits behind A2.
    ready(@[uri(10800),uri(10801),uri(10802)]);
    NSDictionary *(^leased)(int,NSString *)=^NSDictionary *(int n,NSString *token){return @{@"uri":uri(n),@"name":@"Reserved fixture",@"artist_uri":ownerA,@"owner_token":token};};
    NSUInteger parkedReads=reads,parkedStreams=streamStarts,parkedMutations=sent.count;
    assert(SAPReserveArtistDownloadSessionReleases(@[leased(10800,@"fifo-a"),leased(10801,@"fifo-a")],&error));pump(.03);
    assert(reads==parkedReads && streamStarts==parkedStreams && sent.count==parkedMutations);
    assert(SAPAppendArtistDownloadSessionReleases(@[release(10802)],&error));pump(.03);
    assert(reads==parkedReads && streamStarts==parkedStreams && sent.count==parkedMutations);
    assert(SAPAppendArtistDownloadSessionReleases(@[leased(10800,@"fifo-a")],&error));waitForSession(^BOOL{return addReplies[uri(10800)]!=nil;});
    acceptAdd(uri(10800));complete(uri(10800));pump(.03);assert(!addReplies[uri(10802)]);
    parkedReads=reads;parkedStreams=streamStarts;pump(.04);assert(reads==parkedReads && streamStarts==parkedStreams);
    assert(SAPAppendArtistDownloadSessionReleases(@[leased(10801,@"fifo-a")],&error));waitForSession(^BOOL{return addReplies[uri(10801)]!=nil;});acceptAdd(uri(10801));complete(uri(10801));assert(!SAPCancelArtistDownloadOwner(ownerA,@"fifo-a"));waitForSession(^BOOL{return addReplies[uri(10802)]!=nil;});acceptAdd(uri(10802));complete(uri(10802));
    assert([addSubmissionOrder indexOfObject:uri(10800)]<[addSubmissionOrder indexOfObject:uri(10801)] && [addSubmissionOrder indexOfObject:uri(10801)]<[addSubmissionOrder indexOfObject:uri(10802)]);
    puts("PASS: full accepted batches reserve FIFO positions without native reads or mutations, and deferred A2 stays ahead of a later direct B");
    ready(@[uri(10810),uri(10811),uri(10812)]);NSUInteger parkedRemoves=sentCount(@"RemoveDownload:");
    assert(SAPReserveArtistDownloadSessionReleases(@[leased(10810,@"blocker"),leased(10811,@"ready-owner")],&error));
    assert(SAPReserveArtistDownloadSessionReleases(@[leased(10811,@"waiting-owner")],&error));
    assert(SAPAppendArtistDownloadSessionReleases(@[leased(10811,@"ready-owner"),release(10812)],&error));
    assert(!SAPCancelArtistDownloadOwner(ownerA,@"ready-owner"));assert(!SAPCancelArtistDownloadOwner(ownerA,@"blocker"));pump(.03);
    assert(!addReplies[uri(10811)] && !addReplies[uri(10812)] && sentCount(@"RemoveDownload:")==parkedRemoves);
    assert(SAPAppendArtistDownloadSessionReleases(@[leased(10811,@"waiting-owner")],&error));waitForSession(^BOOL{return addReplies[uri(10811)]!=nil;});acceptAdd(uri(10811));complete(uri(10811));assert(!SAPCancelArtistDownloadOwner(ownerA,@"waiting-owner"));waitForSession(^BOOL{return addReplies[uri(10812)]!=nil;});acceptAdd(uri(10812));complete(uri(10812));
    ready(@[uri(10820)]);assert(SAPReserveArtistDownloadSessionReleases(@[leased(10820,@"reserved-a"),leased(10820,@"reserved-b")],&error));assert(!SAPCancelArtistDownloadOwner(ownerA,@"reserved-a"));pump(.02);assert(!addReplies[uri(10820)] && sentCount(@"RemoveDownload:")==parkedRemoves);assert(!SAPCancelArtistDownloadOwner(ownerA,@"reserved-b"));pump(.02);assert(sentCount(@"RemoveDownload:")==parkedRemoves && sentExactCount([@"AddDownload:"stringByAppendingString:uri(10820)])==0);
    puts("PASS: cancelling an activated queued lease leaves another owner parked; duplicate reservations cancel independently and never send Remove before submission");
    ready(@[uri(10830)]);__block NSDictionary *endedSnapshot=nil;SAPArtistSessionObservation *endedObservation=SAPObserveArtistSession(@[@{@"uri":uri(10830),@"follow_external_changes":@YES},release(10831),release(10832)],^(NSDictionary *v){endedSnapshot=v;});
    assert(SAPAppendArtistDownloadSessionReleases(@[leased(10830,@"external-stop")],&error));waitForSession(^BOOL{return addReplies[uri(10830)]!=nil;});acceptAdd(uri(10830));native[uri(10830)]=@5;emitState(@[uri(10830)]);NSUInteger fullCountReads=reads;emitProgress(uri(10830),YES,1,1);pump(.02);assert(reads==fullCountReads+1);emitProgress(uri(10830),YES,1,1);pump(.02);assert(reads==fullCountReads+1);
    assert(![endedSnapshot[@"album_states"][uri(10830)][@"state"]isEqual:@"downloaded"]);consumeTerminal(uri(10830));native[uri(10830)]=@0;emitState(@[uri(10830)]);
    assert([endedSnapshot[@"album_states"][uri(10830)][@"native_cancelled"]boolValue] && [endedSnapshot[@"album_states"][uri(10830)][@"native_ended"]boolValue] && ![endedSnapshot[@"album_states"][uri(10830)][@"owned"]boolValue]);
    NSUInteger endedMutations=sent.count;assert(contexts.count && progressStreams.count);
    for(NSDictionary *request in contextRequests.allValues)assert([request[@"uris"]isEqual:@[uri(10830)]]);
    native[uri(10830)]=@4;emitState(@[uri(10830)]);assert(![endedSnapshot[@"album_states"][uri(10830)][@"native_cancelled"]boolValue]);
    native[uri(10830)]=@3;emitState(@[uri(10830)]);waitForSession(^BOOL{return [endedSnapshot[@"album_states"][uri(10830)][@"state"]isEqual:@"downloaded"];});assert(sent.count==endedMutations && ![endedSnapshot[@"album_states"][uri(10830)][@"native_cancelled"]boolValue]);[endedObservation invalidate];assert(!contexts.count && !progressStreams.count);assert(!SAPCancelArtistDownloadOwner(ownerA,@"external-stop"));
    puts("PASS: full totals never synthesize native completion; observed external Stop remains truthful after ownership ends, and a scoped held stream sees external 0-to-4-to-3 restart without mutation replay; invalidate closes that stream");
    ready(@[uri(10840),uri(10841)]);NSString *ticketPlaylist=@"spotify:playlist:0000000000000000000088";native[ticketPlaylist]=@0;
    assert(SAPReserveArtistDownloadSessionReleases(@[leased(10840,@"full-task")],&error));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10840,@"full-task"),release(10841)],&error));waitForSession(^BOOL{return addReplies[uri(10840)]!=nil;});acceptAdd(uri(10840));complete(uri(10840));pump(.03);assert(!addReplies[uri(10841)]);
    assert(SAPAppendArtistDownloadSessionReleases(@[@{@"uri":ticketPlaylist,@"artist_uri":ownerA,@"owner_token":@"full-task"}],&error));waitForSession(^BOOL{return addReplies[ticketPlaylist]!=nil;});assert(!addReplies[uri(10841)]);acceptAdd(ticketPlaylist);complete(ticketPlaylist);pump(.02);assert(!addReplies[uri(10841)]);assert(!SAPCancelArtistDownloadOwner(ownerA,@"full-task"));waitForSession(^BOOL{return addReplies[uri(10841)]!=nil;});acceptAdd(uri(10841));complete(uri(10841));
    puts("PASS: a task ticket keeps the final playlist ahead of later jobs, including the async registration gap, and successful task release admits the next FIFO job");
    ready(@[uri(10850),uri(10851)]);assert(SAPReserveArtistDownloadSessionReleases(@[leased(10850,@"rank-first")],&error));assert(SAPReserveArtistDownloadSessionReleases(@[leased(10851,@"rank-middle")],&error));assert(SAPReserveArtistDownloadSessionReleases(@[leased(10850,@"rank-last")],&error));assert(!SAPCancelArtistDownloadOwner(ownerA,@"rank-first"));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10851,@"rank-middle")],&error));waitForSession(^BOOL{return addReplies[uri(10851)]!=nil;});assert(!addReplies[uri(10850)]);acceptAdd(uri(10851));complete(uri(10851));assert(!SAPCancelArtistDownloadOwner(ownerA,@"rank-middle"));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10850,@"rank-last")],&error));waitForSession(^BOOL{return addReplies[uri(10850)]!=nil;});acceptAdd(uri(10850));complete(uri(10850));assert(!SAPCancelArtistDownloadOwner(ownerA,@"rank-last"));
    puts("PASS: cancelling the earliest shared reservation moves its URI to the surviving task rank, so a middle task can progress before a later task that shares its destination");
    // A younger duplicate lease cannot change the surviving batch's order.
    ready(@[uri(10860),uri(10861),uri(10862)]);assert(SAPReserveArtistDownloadSessionReleases(@[leased(10860,@"ordinal-old"),leased(10861,@"ordinal-old"),leased(10862,@"ordinal-old")],&error));assert(SAPReserveArtistDownloadSessionReleases(@[leased(10861,@"ordinal-young")],&error));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10860,@"ordinal-old")],&error));waitForSession(^BOOL{return addReplies[uri(10860)]!=nil;});assert(!SAPCancelArtistDownloadOwner(ownerA,@"ordinal-young"));acceptAdd(uri(10860));complete(uri(10860));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10861,@"ordinal-old")],&error));waitForSession(^BOOL{return addReplies[uri(10861)]!=nil;});assert(!addReplies[uri(10862)]);acceptAdd(uri(10861));complete(uri(10861));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10862,@"ordinal-old")],&error));waitForSession(^BOOL{return addReplies[uri(10862)]!=nil;});acceptAdd(uri(10862));complete(uri(10862));assert(!SAPCancelArtistDownloadOwner(ownerA,@"ordinal-old"));
    // When the oldest owner goes away, adopt the survivor's original ordinal.
    ready(@[uri(10870),uri(10871),uri(10872)]);assert(SAPReserveArtistDownloadSessionReleases(@[leased(10871,@"ordinal-first")],&error));assert(SAPReserveArtistDownloadSessionReleases(@[leased(10870,@"ordinal-survivor"),leased(10871,@"ordinal-survivor"),leased(10872,@"ordinal-survivor")],&error));assert(!SAPCancelArtistDownloadOwner(ownerA,@"ordinal-first"));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10870,@"ordinal-survivor")],&error));waitForSession(^BOOL{return addReplies[uri(10870)]!=nil;});acceptAdd(uri(10870));complete(uri(10870));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10871,@"ordinal-survivor")],&error));waitForSession(^BOOL{return addReplies[uri(10871)]!=nil;});assert(!addReplies[uri(10872)]);acceptAdd(uri(10871));complete(uri(10871));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10872,@"ordinal-survivor")],&error));waitForSession(^BOOL{return addReplies[uri(10872)]!=nil;});acceptAdd(uri(10872));complete(uri(10872));assert(!SAPCancelArtistDownloadOwner(ownerA,@"ordinal-survivor"));
    puts("PASS: shared-owner cancellation preserves an unchanged within-batch position and repositions changed ownership by the surviving release ordinal, keeping A-B-C in both cases");
    ready(@[uri(10880)]);NSString *sharedTicketPlaylist=@"spotify:playlist:0000000000000000000089";native[sharedTicketPlaylist]=@0;
    assert(SAPReserveArtistDownloadSessionReleases(@[leased(10880,@"joining-ticket")],&error));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10880,@"joining-ticket"),@{@"uri":sharedTicketPlaylist}],&error));waitForSession(^BOOL{return addReplies[uri(10880)]!=nil;});acceptAdd(uri(10880));complete(uri(10880));pump(.02);assert(!addReplies[sharedTicketPlaylist]);assert(SAPAppendArtistDownloadSessionReleases(@[@{@"uri":sharedTicketPlaylist,@"artist_uri":ownerA,@"owner_token":@"joining-ticket"}],&error));waitForSession(^BOOL{return addReplies[sharedTicketPlaylist]!=nil;});acceptAdd(sharedTicketPlaylist);complete(sharedTicketPlaylist);assert(!SAPCancelArtistDownloadOwner(ownerA,@"joining-ticket"));
    puts("PASS: a retained earlier task can join a newer queued final-playlist context and move it ahead of its own task barrier without duplicate native submission");
    ready(@[uri(10890),uri(10891)]);assert(SAPReserveArtistDownloadSessionReleases(@[leased(10890,@"completed-blocker")],&error));assert(SAPReserveArtistDownloadSessionReleases(@[leased(10891,@"completed-queued")],&error));assert(SAPAppendArtistDownloadSessionReleases(@[leased(10891,@"completed-queued")],&error));SAPArtistSessionObservation *completedQueuedObservation=SAPObserveArtistSession(@[@{@"uri":uri(10891)}],^(__unused NSDictionary *v){});native[uri(10891)]=@3;emitState(@[uri(10891)]);NSUInteger completedQueuedReads=reads;assert(!SAPCancelArtistDownloadOwner(ownerA,@"completed-blocker"));waitForSession(^BOOL{return reads>completedQueuedReads;});pump(.02);assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(10891)])==0);assert(!SAPCancelArtistDownloadOwner(ownerA,@"completed-queued"));[completedQueuedObservation invalidate];
    puts("PASS: genuine native completion for a queued ready release preserves readiness until its FIFO preflight consumes it, without an unnecessary Add");
    // Full audio plus a real native waiter gets one deliberate native recovery.
    SAPArtistSessionSetRecoverySettleForTesting(.04);
    if(!verifiedFixtureTrackCounts)verifiedFixtureTrackCounts=[NSMutableDictionary dictionary];
    for(int n=10900;n<=10915;n++)verifiedFixtureTrackCounts[uri(n)]=@8;
    __block NSDictionary *recoverySnapshot=nil;SAPArtistSessionObservation *recoveryObservation=SAPObserveArtistSession(@[release(10900),release(10901),release(10902),release(10903),release(10904),release(10905),release(10906),release(10907),release(10908),release(10909),release(10910),release(10911),release(10912),release(10913),release(10914),release(10915)],^(NSDictionary *v){recoverySnapshot=v;});
    ready(@[uri(10900)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10900)],&error));waitForSession(^BOOL{return addReplies[uri(10900)]!=nil;});acceptAdd(uri(10900));native[uri(10900)]=@5;emitState(@[uri(10900)]);NSUInteger recoveryRemoves=sentCount(@"RemoveDownload:");emitProgress(uri(10900),NO,8,8);pump(.01);complete(uri(10900));pump(.07);assert(sentCount(@"RemoveDownload:")==recoveryRemoves);
    puts("PASS: real native completion during recovery settling cancels the timer and sends no Remove");
    ready(@[uri(10901),uri(10902)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10901),release(10902)],&error));waitForSession(^BOOL{return addReplies[uri(10901)]!=nil;});acceptAdd(uri(10901));native[uri(10901)]=@5;emitState(@[uri(10901)]);NSUInteger itemReadsBefore=recoveryItemReads;emitProgress(uri(10901),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10901)]!=nil;});assert(recoveryItemReads==itemReadsBefore+1 && !addReplies[uri(10902)]);assert([recoverySnapshot[@"album_states"][uri(10901)][@"owned"]boolValue]);finishRemove(uri(10901));waitForSession(^BOOL{return addReplies[uri(10901)]!=nil;});assert(!addReplies[uri(10902)] && [recoverySnapshot[@"album_states"][uri(10901)][@"owned"]boolValue] && ![recoverySnapshot[@"album_states"][uri(10901)][@"state"]isEqual:@"downloaded"]);acceptAdd(uri(10901));native[uri(10901)]=@5;emitState(@[uri(10901)]);emitProgress(uri(10901),NO,8,8);pump(.08);assert(sentExactCount([@"RemoveDownload:"stringByAppendingString:uri(10901)])==1 && sentExactCount([@"AddDownload:"stringByAppendingString:uri(10901)])==2 && !addReplies[uri(10902)]);complete(uri(10901));waitForSession(^BOOL{return addReplies[uri(10902)]!=nil;});acceptAdd(uri(10902));complete(uri(10902));
    puts("PASS: exact eight downloaded native items gate one Remove/read-zero/Add, preserve the FIFO slot and remain truthful until real native 3; no second recovery");
    ready(@[uri(10903)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10903)],&error));waitForSession(^BOOL{return addReplies[uri(10903)]!=nil;});acceptAdd(uri(10903));native[uri(10903)]=@5;emitState(@[uri(10903)]);emitProgress(uri(10903),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10903)]!=nil;});failRemove(uri(10903),nil,@"timeout");pump(.08);assert(sentExactCount([@"RemoveDownload:"stringByAppendingString:uri(10903)])==1 && sentExactCount([@"AddDownload:"stringByAppendingString:uri(10903)])==1 && [recoverySnapshot[@"album_states"][uri(10903)][@"owned"]boolValue]);SAPStopArtistDownloadSessionRelease(uri(10903));pump(.03);assert(!removeReplies[uri(10903)]);consumeTerminal(uri(10903));native[uri(10903)]=@0;emitState(@[uri(10903)]);pump(.02);assert(![recoverySnapshot[@"album_states"][uri(10903)][@"owned"]boolValue]);
    puts("PASS: explicit Stop supersedes halted ambiguous Remove without replay and consumes its later native zero; ambiguous recovery Remove is never replayed and preserves truthful ownership until real completion");
    ready(@[uri(10904)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10904)],&error));waitForSession(^BOOL{return addReplies[uri(10904)]!=nil;});acceptAdd(uri(10904));native[uri(10904)]=@5;emitState(@[uri(10904)]);emitProgress(uri(10904),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10904)]!=nil;});SAPStopArtistDownloadSessionRelease(uri(10904));finishRemove(uri(10904));pump(.05);assert(sentExactCount([@"RemoveDownload:"stringByAppendingString:uri(10904)])==1 && sentExactCount([@"AddDownload:"stringByAppendingString:uri(10904)])==1 && ![recoverySnapshot[@"album_states"][uri(10904)][@"owned"]boolValue]);
    puts("PASS: Stop while recovery Remove is pending consumes its confirmed removal without recovery Add or duplicate Remove");
    ready(@[uri(10905)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10905)],&error));waitForSession(^BOOL{return addReplies[uri(10905)]!=nil;});acceptAdd(uri(10905));native[uri(10905)]=@5;emitState(@[uri(10905)]);emitProgress(uri(10905),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10905)]!=nil;});holdRecoveryZeroRead=YES;finishRemove(uri(10905));assert(heldRecoveryZeroRead);SAPStopArtistDownloadSessionRelease(uri(10905));heldRecoveryZeroRead();heldRecoveryZeroRead=nil;pump(.04);assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(10905)])==1 && ![recoverySnapshot[@"album_states"][uri(10905)][@"owned"]boolValue]);
    puts("PASS: Stop before recovery's fresh-zero response invalidates that read and permanently forbids recovery Add");
    ready(@[uri(10906)]);assert(SAPAppendArtistDownloadSessionReleases(@[leased(10906,@"recovery-shared-a"),leased(10906,@"recovery-shared-b")],&error));waitForSession(^BOOL{return addReplies[uri(10906)]!=nil;});acceptAdd(uri(10906));native[uri(10906)]=@5;emitState(@[uri(10906)]);emitProgress(uri(10906),NO,8,8);pump(.08);assert(!removeReplies[uri(10906)]);complete(uri(10906));assert(!SAPCancelArtistDownloadOwner(ownerA,@"recovery-shared-a"));assert(!SAPCancelArtistDownloadOwner(ownerA,@"recovery-shared-b"));
    ready(@[uri(10907)]);native[uri(10907)]=@5;assert(SAPAppendArtistDownloadSessionReleases(@[release(10907)],&error));pump(.03);emitProgress(uri(10907),NO,8,8);pump(.08);assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(10907)])==0 && !removeReplies[uri(10907)]);native[uri(10907)]=@3;emitState(@[uri(10907)]);
    puts("PASS: shared ownership and adopted external native downloads never qualify for automatic recovery");
    ready(@[uri(10908)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10908)],&error));waitForSession(^BOOL{return addReplies[uri(10908)]!=nil;});acceptAdd(uri(10908));native[uri(10908)]=@5;emitState(@[uri(10908)]);recoveryMissingItem=YES;emitProgress(uri(10908),NO,8,8);pump(.1);recoveryMissingItem=NO;assert(!removeReplies[uri(10908)] && [recoverySnapshot[@"album_states"][uri(10908)][@"owned"]boolValue] && [recoverySnapshot[@"album_states"][uri(10908)][@"error"]length]);NSUInteger haltedReads=reads;pump(.08);assert(reads==haltedReads);complete(uri(10908));
    puts("PASS: missing native item halts recovery without mutation, keeps the reservation and introduces no polling");
    ready(@[uri(10909)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10909)],&error));waitForSession(^BOOL{return addReplies[uri(10909)]!=nil;});acceptAdd(uri(10909));native[uri(10909)]=@5;emitState(@[uri(10909)]);emitProgress(uri(10909),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10909)]!=nil;});finishRemove(uri(10909));waitForSession(^BOOL{return addReplies[uri(10909)]!=nil;});failAdd(uri(10909),nil,@"timeout");pump(.08);assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(10909)])==2 && !removeReplies[uri(10909)] && [recoverySnapshot[@"album_states"][uri(10909)][@"owned"]boolValue]);SAPStopArtistDownloadSessionRelease(uri(10909));waitForSession(^BOOL{return removeReplies[uri(10909)]!=nil;});finishRemove(uri(10909));pump(.02);assert(![recoverySnapshot[@"album_states"][uri(10909)][@"owned"]boolValue]);
    puts("PASS: explicit Stop supersedes halted ambiguous Add and finishes confirmed native removal; ambiguous recovery Add is never replayed and never synthesizes completion");
    ready(@[uri(10910)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10910)],&error));waitForSession(^BOOL{return addReplies[uri(10910)]!=nil;});acceptAdd(uri(10910));native[uri(10910)]=@5;emitState(@[uri(10910)]);emitProgress(uri(10910),NO,8,8);pump(.01);emitProgress(uri(10910),YES,7,8);pump(.07);assert(!removeReplies[uri(10910)]);complete(uri(10910));
    ready(@[uri(10911)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10911)],&error));waitForSession(^BOOL{return addReplies[uri(10911)]!=nil;});acceptAdd(uri(10911));native[uri(10911)]=@5;emitState(@[uri(10911)]);emitProgress(uri(10911),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10911)]!=nil;});void(^zeroUnconfirmed)(NSData*,NSString*)=removeReplies[uri(10911)];[removeReplies removeObjectForKey:uri(10911)];zeroUnconfirmed(NSData.data,nil);pump(.08);assert(sentExactCount([@"AddDownload:"stringByAppendingString:uri(10911)])==1 && [recoverySnapshot[@"album_states"][uri(10911)][@"owned"]boolValue]);complete(uri(10911));
    assert([recoverySnapshot[@"album_states"][uri(10911)][@"owned"]boolValue]);SAPStopArtistDownloadSessionRelease(uri(10911));native[uri(10911)]=@0;emitState(@[uri(10911)]);pump(.02);assert(![recoverySnapshot[@"album_states"][uri(10911)][@"owned"]boolValue]);
    puts("PASS: renewed native activity cancels pending settlement; Remove ACK without fresh state zero never permits Add");
    ready(@[uri(10912)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10912)],&error));waitForSession(^BOOL{return addReplies[uri(10912)]!=nil;});acceptAdd(uri(10912));native[uri(10912)]=@5;emitState(@[uri(10912)]);neverInvokedRemoveURI=uri(10912);emitProgress(uri(10912),NO,8,8);pump(.1);assert(!removeReplies[uri(10912)] && sentExactCount([@"RemoveDownload:"stringByAppendingString:uri(10912)])==0);neverInvokedRemoveURI=nil;SAPStopArtistDownloadSessionRelease(uri(10912));waitForSession(^BOOL{return removeReplies[uri(10912)]!=nil;});finishRemove(uri(10912));pump(.02);assert(![recoverySnapshot[@"album_states"][uri(10912)][@"owned"]boolValue]);
    puts("PASS: definitely uninvoked recovery Remove does not poison the ordinary explicit Stop removal marker");
    ready(@[uri(10913)]);verifiedFixtureTrackCounts[uri(10913)]=@8;assert(SAPAppendArtistDownloadSessionReleases(@[release(10913)],&error));waitForSession(^BOOL{return addReplies[uri(10913)]!=nil;});acceptAdd(uri(10913));native[uri(10913)]=@5;emitState(@[uri(10913)]);emitProgress(uri(10913),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10913)]!=nil;});finishRemove(uri(10913));waitForSession(^BOOL{return addReplies[uri(10913)]!=nil;});acceptAdd(uri(10913));failNative(uri(10913));pump(.02);assert(![recoverySnapshot[@"album_states"][uri(10913)][@"owned"]boolValue]);
    puts("PASS: native error during recovery completion observation releases the failed operation immediately");
    // A completion arriving before an ambiguous Remove outcome must not
    // release the slot or show Downloaded. Explicit Stop still awaits zero.
    ready(@[uri(10914)]);verifiedFixtureTrackCounts[uri(10914)]=@8;
    assert(SAPAppendArtistDownloadSessionReleases(@[release(10914)],&error));waitForSession(^BOOL{return addReplies[uri(10914)]!=nil;});acceptAdd(uri(10914));
    native[uri(10914)]=@5;emitState(@[uri(10914)]);emitProgress(uri(10914),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10914)]!=nil;});
    native[uri(10914)]=@3;emitState(@[uri(10914)]);failRemove(uri(10914),nil,@"timeout");pump(.02);
    assert([recoverySnapshot[@"album_states"][uri(10914)][@"owned"]boolValue] && ![recoverySnapshot[@"album_states"][uri(10914)][@"state"]isEqual:@"downloaded"]);
    SAPStopArtistDownloadSessionRelease(uri(10914));pump(.02);assert([recoverySnapshot[@"album_states"][uri(10914)][@"owned"]boolValue]);
    consumeTerminal(uri(10914));native[uri(10914)]=@0;emitState(@[uri(10914)]);pump(.02);assert(![recoverySnapshot[@"album_states"][uri(10914)][@"owned"]boolValue]);
    puts("PASS: pre-outcome native completion cannot release an ambiguous recovery Remove or fake Downloaded; scoped Stop retains the lease until actual native zero");
    ready(@[uri(10915)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(10915)],&error));waitForSession(^BOOL{return addReplies[uri(10915)]!=nil;});acceptAdd(uri(10915));
    native[uri(10915)]=@5;emitState(@[uri(10915)]);emitProgress(uri(10915),NO,8,8);waitForSession(^BOOL{return removeReplies[uri(10915)]!=nil;});finishRemove(uri(10915));waitForSession(^BOOL{return addReplies[uri(10915)]!=nil;});
    emitState(@[uri(10915)]);assert(![recoverySnapshot[@"album_states"][uri(10915)][@"native_cancelled"]boolValue]);acceptAdd(uri(10915));native[uri(10915)]=@5;emitState(@[uri(10915)]);
    cancelNative(uri(10915));pump(.02);assert(![recoverySnapshot[@"album_states"][uri(10915)][@"owned"]boolValue] && [recoverySnapshot[@"album_states"][uri(10915)][@"native_cancelled"]boolValue]);
    puts("PASS: recovery's initial zero never becomes a false external Stop; a genuine later native cancellation releases the operation and retains Continue");
    // Review regressions: failed Stop preflight is retryable without replay.
    NSArray *reviewReleases=@[release(11000),release(11001),release(11002),release(11003),release(11004),release(11005),release(11006)];
    __block NSDictionary *reviewSnapshot=nil;
    SAPArtistSessionObservation *reviewObservation=SAPObserveArtistSession(reviewReleases,^(NSDictionary *v){reviewSnapshot=v;});
    ready(@[uri(11000)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(11000)],&error));waitForSession(^BOOL{return addReplies[uri(11000)]!=nil;});acceptAdd(uri(11000));native[uri(11000)]=@4;emitState(@[uri(11000)]);
    failContextReads=YES;SAPStopArtistDownloadSessionRelease(uri(11000));pump(.03);failContextReads=NO;
    assert(![reviewSnapshot[@"album_states"][uri(11000)][@"stopping"]boolValue]);
    assert([reviewSnapshot[@"album_states"][uri(11000)][@"owned"]boolValue] && !removeReplies[uri(11000)]);
    SAPStopArtistDownloadSessionRelease(uri(11000));waitForSession(^BOOL{return removeReplies[uri(11000)]!=nil;});finishRemove(uri(11000));pump(.02);
    puts("PASS: failed Stop preflight clears Stopping and allows one explicit retry");
    ready(@[uri(11005)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(11005)],&error));waitForSession(^BOOL{return addReplies[uri(11005)]!=nil;});acceptAdd(uri(11005));native[uri(11005)]=@4;emitState(@[uri(11005)]);
    neverInvokedRemoveURI=uri(11005);SAPStopArtistDownloadSessionRelease(uri(11005));pump(.03);
    assert(![reviewSnapshot[@"album_states"][uri(11005)][@"stopping"]boolValue] && !removeReplies[uri(11005)]);neverInvokedRemoveURI=nil;
    SAPStopArtistDownloadSessionRelease(uri(11005));waitForSession(^BOOL{return removeReplies[uri(11005)]!=nil;});finishRemove(uri(11005));pump(.02);
    ready(@[uri(11006)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(11006)],&error));waitForSession(^BOOL{return addReplies[uri(11006)]!=nil;});acceptAdd(uri(11006));native[uri(11006)]=@4;emitState(@[uri(11006)]);
    SAPStopArtistDownloadSessionRelease(uri(11006));waitForSession(^BOOL{return removeReplies[uri(11006)]!=nil;});failRemove(uri(11006),SAPProtoInteger(1,7),nil);pump(.03);
    assert(![reviewSnapshot[@"album_states"][uri(11006)][@"stopping"]boolValue]);
    SAPStopArtistDownloadSessionRelease(uri(11006));waitForSession(^BOOL{return removeReplies[uri(11006)]!=nil;});finishRemove(uri(11006));pump(.02);
    puts("PASS: definitely uninvoked/rejected ordinary Stop is retryable without automatic command replay");


    ready(@[uri(11001)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(11001)],&error));waitForSession(^BOOL{return addReplies[uri(11001)]!=nil;});acceptAdd(uri(11001));native[uri(11001)]=@4;emitState(@[uri(11001)]);
    SAPStopArtistDownloadSessionRelease(uri(11001));waitForSession(^BOOL{return removeReplies[uri(11001)]!=nil;});native[uri(11001)]=@3;emitState(@[uri(11001)]);pump(.02);
    assert([reviewSnapshot[@"album_states"][uri(11001)][@"owned"]boolValue]);
    assert(![reviewSnapshot[@"album_states"][uri(11001)][@"state"]isEqual:@"downloaded"]);
    failRemove(uri(11001),NSData.data,nil);pump(.02);
    assert([reviewSnapshot[@"album_states"][uri(11001)][@"owned"]boolValue]);
    finishRemove(uri(11001));pump(.02);assert(![reviewSnapshot[@"album_states"][uri(11001)][@"owned"]boolValue]);
    puts("PASS: state3 before/after ordinary Remove ACK retains ownership until native zero");

    verifiedFixtureTrackCounts[uri(11002)]=@6;
    ready(@[uri(11002)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(11002)],&error));waitForSession(^BOOL{return addReplies[uri(11002)]!=nil;});acceptAdd(uri(11002));native[uri(11002)]=@4;emitState(@[uri(11002)]);
    NSUInteger state4Reads=reads;emitProgress(uri(11002),NO,6,6);pump(.01);assert(reads==state4Reads+1);
    assert(![reviewSnapshot[@"album_states"][uri(11002)][@"state"]isEqual:@"downloaded"]);
    waitForSession(^BOOL{return removeReplies[uri(11002)]!=nil;});finishRemove(uri(11002));waitForSession(^BOOL{return addReplies[uri(11002)]!=nil;});acceptAdd(uri(11002));complete(uri(11002));
    assert(sentExactCount([@"RemoveDownload:"stringByAppendingString:uri(11002)])==1);
    puts("PASS: full state4 reconciles once and uses verified one-attempt native recovery");

    verifiedFixtureTrackCounts[uri(11003)]=@6;
    ready(@[uri(11003),uri(11004)]);assert(SAPAppendArtistDownloadSessionReleases(@[release(11003),release(11004)],&error));waitForSession(^BOOL{return addReplies[uri(11003)]!=nil;});acceptAdd(uri(11003));native[uri(11003)]=@4;emitState(@[uri(11003)]);nearTail(uri(11003));waitForSession(^BOOL{return addReplies[uri(11004)]!=nil;});acceptAdd(uri(11004));
    emitProgress(uri(11003),NO,5,6);pump(.06);assert(!removeReplies[uri(11003)]);
    emitProgress(uri(11003),NO,6,6);pump(.06);assert(!removeReplies[uri(11003)]);
    complete(uri(11004));waitForSession(^BOOL{return removeReplies[uri(11003)]!=nil;});finishRemove(uri(11003));waitForSession(^BOOL{return addReplies[uri(11003)]!=nil;});acceptAdd(uri(11003));complete(uri(11003));
    puts("PASS: incomplete state4 never recovers and full waiter is reconsidered after peer completion");
    NSString *forcedPlaylist=@"spotify:playlist:0000000000000000011007";
    NSDictionary *forcedRelease=@{@"uri":forcedPlaylist,@"incremental_playlist":@YES,@"artist_uri":ownerA,@"owner_token":@"forced-stop-review"};native[forcedPlaylist]=@3;
    SAPArtistSessionObservation *forcedObservation=SAPObserveArtistSession(@[forcedRelease],^(__unused NSDictionary *v){});pump(.03);
    assert(SAPReserveArtistDownloadSessionReleases(@[forcedRelease],&error));NSUInteger forcedRemoves=sentCount(@"RemoveDownload:");
    failContextReads=YES;SAPStopArtistDownloadSessionRelease(forcedPlaylist);pump(.03);failContextReads=NO;
    SAPStopArtistDownloadSessionRelease(forcedPlaylist);pump(.03);
    assert(sentCount(@"RemoveDownload:")==forcedRemoves);[forcedObservation invalidate];assert(!SAPCancelArtistDownloadOwner(ownerA,@"forced-stop-review"));
    puts("PASS: failed queued playlist Stop leaves no hidden forced removal intent");
    [reviewObservation invalidate];
    [recoveryObservation invalidate];SAPArtistSessionSetRecoverySettleForTesting(2);
    assertSubmitted(@[]);assert(peakSubmittedUnfinished==2);assert(addReplies.count==0 && removeReplies.count==0);
    for(NSString *u in addSubmissionOrder)assert(([terminalCounts[u]unsignedIntegerValue]==[addSubmissionOrder filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@",u]].count));
    printf("PASS: reliable-tail native overlap peak=%lu, conservative unknown-count FIFO, paused reservation cap and unproven-zero recovery, adopted pre-tail gate, independent progress and out-of-order completion, ACK-held capacity, ambiguous reconciliation, scoped stop ordering, stale reads/watches, inactivity pause/recovery, detached cleanup and cache protection\n",(unsigned long)peakSubmittedUnfinished);

    // Direct album path (production default): every selected release is sent
    // as soon as it is prepared, like tapping download in Spotify. Only
    // preparation is bounded; Spotify schedules the transfers itself.
    initFixture();SAPArtistSessionSetDirectAlbumSubmissionForTesting(YES);fixtureSubmittedLimit=256;fixtureNativeContextLimit=64;autoStreamResponses=YES;
    NSMutableArray *directReleases=[NSMutableArray array],*directURIs=[NSMutableArray array];
    for(int n=9000;n<9070;n++){NSMutableDictionary *item=[release(n)mutableCopy];item[@"type"]=@2;[directReleases addObject:item];[directURIs addObject:uri(n)];}
    ready(directURIs);for(int n=9000;n<9010;n++)members[uri(n)]=@NO;
    SAPArtistSessionObservation *directObservation=SAPObserveArtistSession(directReleases,^(NSDictionary *s){snapshot=s;});pump(.05);
    NSUInteger streamsBefore=streamStarts;entityReads=0;
    assert(SAPAppendArtistDownloadSessionReleases(directReleases,&error));
    waitForSession(^BOOL{return submittedUnfinishedURIs.count==70;});pump(.3);
    assert(addSubmissionOrder.count==70 && sentCount(@"save:")==10 && entityReads==0 && "all releases are sent before any native progress; singles need no extra metadata read");
    printf("direct stream starts: %lu\n",(unsigned long)(streamStarts-streamsBefore));assert(streamStarts-streamsBefore<=30 && "a burst of submissions renews the live streams a bounded number of times");
    NSMutableSet *observedDefault=[NSMutableSet set];for(NSArray *request in nativeDefaultContexts)[observedDefault addObjectsFromArray:request];
    for(NSString *u in directURIs)assert([observedDefault containsObject:u]);
    for(NSDictionary *request in contextRequests.allValues)if([request[@"state_only"]boolValue])for(NSString *u in directURIs)assert(![request[@"uris"]containsObject:u]);
    for(NSString *u in directURIs)acceptAdd(u);pump(.02);
    // Spotify finishes in its own order; nothing waits for an older release.
    for(NSString *u in directURIs.reverseObjectEnumerator)complete(u);
    waitForSession(^BOOL{return [snapshot[@"active"]boolValue]==NO;});
    assert(addSubmissionOrder.count==70 && submittedUnfinishedURIs.count==0 && addReplies.count==0);
    for(NSString *u in directURIs)assert([snapshot[@"album_states"][u][@"state"]isEqual:@"downloaded"]);
    puts("PASS: direct album path sends all 70 selected releases at once, saves missing library items first, observes them in 64-URI chunks and finishes out of order");

    // Preparation stays bounded to four releases; each sent one frees a place.
    NSMutableArray *windowReleases=[NSMutableArray array],*windowURIs=[NSMutableArray array];
    for(int n=9100;n<9110;n++){[windowReleases addObject:release(n)];[windowURIs addObject:uri(n)];}
    ready(windowURIs);[directObservation extendReleases:windowReleases];pump(.03);holdContains=YES;
    NSUInteger windowStart=addSubmissionOrder.count;
    assert(SAPAppendArtistDownloadSessionReleases(windowReleases,&error));pump(.05);
    assert(heldContains.count==4 && addSubmissionOrder.count==windowStart && "only four releases prepare at once");
    while(addSubmissionOrder.count<windowStart+10){
        assert(heldContains.count>0 && heldContains.count<=4);dispatch_block_t reply=heldContains.firstObject;[heldContains removeObjectAtIndex:0];reply();pump(.02);
    }
    holdContains=NO;assert(heldContains.count==0);
    for(NSString *u in windowURIs)acceptAdd(u);pump(.02);
    // Stop applies to every sent release, after its Add was acknowledged.
    SAPStopArtistDownloadSessionReleases(windowReleases);waitForSession(^BOOL{return removeReplies.count==10;});
    for(NSString *u in windowURIs)finishRemove(u);
    waitForSession(^BOOL{return submittedUnfinishedURIs.count==0 && [snapshot[@"active"]boolValue]==NO;});
    for(NSString *u in windowURIs)assert(sentExactCount([@"AddDownload:" stringByAppendingString:u])==1 && sentExactCount([@"RemoveDownload:" stringByAppendingString:u])==1);
    puts("PASS: direct preparation is bounded to four releases, each submission refills the window, and Stop removes every sent release exactly once");

    // A stream opened before AddDownload can still deliver the previous attempt's
    // error snapshot. It must not fail the new attempt while renewal is batched.
    NSString *stale=uri(9300);ready(@[stale]);native[stale]=@1;[directObservation extendReleases:@[release(9300)]];pump(.3);
    holdContains=YES;NSUInteger directStaleAdds=addSubmissionOrder.count;assert(SAPAppendArtistDownloadSessionReleases(@[release(9300)],&error));
    waitForSession(^BOOL{return heldContains.count==1;});pump(.3); // older streams now own the preparing release
    dispatch_block_t staleReply=heldContains.firstObject;[heldContains removeAllObjects];holdContains=NO;staleReply();
    assert(addSubmissionOrder.count==directStaleAdds+1);emitState(@[stale]);pump(.01);
    assert(![phase(stale) isEqual:@"failed"] && "a pre-Add error snapshot cannot end the new attempt");
    native[stale]=@4;pump(.3);acceptAdd(stale);pump(.02);assert(![phase(stale) isEqual:@"failed"]);
    complete(stale);waitForSession(^BOOL{return [snapshot[@"album_states"][stale][@"state"]isEqual:@"downloaded"];});
    puts("PASS: batched stream renewal ignores a stale pre-Add error for the new attempt and still reports its completion");
    // A release Spotify already has in progress is adopted without a second Add.
    NSString *adopted=uri(9200);ready(@[adopted]);native[adopted]=@4;[directObservation extendReleases:@[release(9200)]];pump(.03);
    NSUInteger adoptedAdds=addSubmissionOrder.count;assert(SAPAppendArtistDownloadSessionReleases(@[release(9200)],&error));pump(.05);
    assert(addSubmissionOrder.count==adoptedAdds && "an active native context is never sent again");
    native[adopted]=@3;emitState(@[adopted]);waitForSession(^BOOL{return [snapshot[@"active"]boolValue]==NO;});
    [directObservation invalidate];pump(.02);
    puts("PASS: direct path adopts an already active native download without another AddDownload");
    return 0;
}}
