#define SAP_EXPORT_WORKFLOW_TEST 1
#import "track_export.m"
#include <assert.h>

static NSUInteger state=0,secondState=0,contextState=0,readCount,commands,preparations,writes,completions;
static BOOL prepareOK=YES,holdRead,invalidReply;
static uint64_t resultCode;
static void (^lateRead)(NSData *,NSString *);
static NSString *lastError;
static NSString *const trackURI=@"spotify:track:0123456789012345678901";
static NSString *const secondURI=@"spotify:track:0123456789012345678902";
static BOOL metadataHasFiles;static NSUInteger metadataReads;
static NSData *fileID(void){return [NSData dataWithBytes:"01234567890123456789" length:20];}

static NSData *item(NSString *uri,NSUInteger code) {
    NSMutableData *fields=[SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];
    [fields appendData:SAPProtoInteger(2,code)];return SAPProtoBytes(1,fields);
}
void SAPCallReadOnlyService(NSString *service,NSString *method,NSData *request,void (^reply)(NSData *,NSString *)) {
    if([service isEqual:@"spotify.metadata_esperanto.proto.ClassicMetadataService"]) {
        assert([method isEqual:@"GetEntity"]);metadataReads++;
        NSMutableData *track=[SAPProtoBytes(2,[@"First" dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];
        [track appendData:SAPProtoInteger(7,360000)];
        if(metadataHasFiles)[track appendData:SAPProtoBytes(12,SAPProtoBytes(1,fileID()))];
        reply(SAPProtoBytes(1,SAPProtoBytes(4,track)),nil);return;
    }
    assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);
    readCount++;
    if(holdRead){lateRead=[reply copy];return;}
    if(invalidReply){reply(nil,@"synthetic read failure");return;}
    if([method isEqual:@"GetContexts"]) {
        NSMutableData *context=[SAPProtoBytes(1,[@"spotify:album:0123456789012345678901" dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];
        [context appendData:SAPProtoInteger(2,contextState)];
        reply(SAPProtoBytes(1,SAPProtoBytes(1,context)),nil);return;
    }
    assert([method isEqual:@"GetItems"]);
    NSMutableData *response=[item(trackURI,state)mutableCopy];
    for(NSDictionary *field in SAPProtoFields(request))
        if([field[@"value"]isEqual:[secondURI dataUsingEncoding:NSUTF8StringEncoding]])[response appendData:item(secondURI,secondState)];
    reply(response,nil);
}
void SAPPrepareNativeOffline(BOOL (^requested)(void),void (^reply)(BOOL,NSString *)) {
    preparations++;assert(requested());reply(prepareOK,@"synthetic preparation failure");
}
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void (^reply)(NSData *,NSString *)) {
    assert([method isEqual:@"AddDownload"] || [method isEqual:@"RemoveDownload"]);
    NSString *uri=SAPProtoString(SAPProtoFields(payload),2);
    assert([uri isEqual:trackURI] || [uri isEqual:secondURI] || [uri isEqual:@"spotify:album:0123456789012345678901"]);
    commands++;reply(SAPProtoInteger(1,resultCode),nil);
}

@interface SAPExportWorkflowFixture : SAPExportJob @end
@implementation SAPExportWorkflowFixture
- (void)writeFiles {
    writes++;
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    [self finish:@[[NSURL fileURLWithPath:@"/synthetic.ogg"]] error:nil];
}
@end
static NSUInteger recoveryCalls;
static NSArray *recoveryTargets;
@interface SAPExportRecoveryFixture:SAPExportWorkflowFixture @end
@implementation SAPExportRecoveryFixture
- (void)refreshKeysForTracks:(NSArray *)tracks {recoveryCalls++;recoveryTargets=tracks;}
@end
static SAPExportJob *job(BOOL album) {
    state=secondState=contextState=readCount=commands=preparations=writes=completions=resultCode=0;
    metadataHasFiles=NO;metadataReads=0;prepareOK=YES;holdRead=invalidReply=NO;lateRead=nil;lastError=nil;
    SAPExportWorkflowFixture *j=[SAPExportWorkflowFixture new];
    j.targetURI=album?@"spotify:album:0123456789012345678901":trackURI;
    j.resolved=[@[@{@"uri":trackURI,@"name":@"First",@"files":@[fileID()]}]mutableCopy];
    if(album)[j.resolved addObject:@{@"uri":secondURI,@"name":@"Second",@"files":@[fileID()]}];
    j.completion=^(NSArray *files,NSString *error){completions++;lastError=error;};
    activeJob=j;atomic_store(&exporting,true);return j;
}
static void drain(void) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:1];
    while(!completions && end.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
    assert(completions==1);
}
int main(void){@autoreleasepool {
    SAPExportJob *old=job(NO);[old finish:nil error:@"cancelled"];drain();
    SAPExportJob *next=job(NO);[old completeTemporaryFinish];
    assert(atomic_load(&exporting) && activeJob==next);
    [old deliverFiles:nil error:@"late"];assert(atomic_load(&exporting) && activeJob==next);
    [next finish:nil error:@"fixture done"];drain();
    SAPExportJob *j=job(NO);[j prepareNativeDownload];
    assert(commands==1 && preparations==1 && !writes);
    [j pollNativeDownload];assert(commands==1 && !writes);
    state=3;[j pollNativeDownload];assert(!writes);
    [j pollNativeDownload];drain();assert(writes==1 && !lastError && !j.poll && !j.deadline);
    NSUInteger reads=readCount;[j pollNativeDownload];assert(readCount==reads);

    j=job(NO);state=3;[j prepareNativeDownload];[j pollNativeDownload];drain();
    assert(commands==0 && preparations==0 && writes==1);

    j=job(NO);state=5;[j prepareNativeDownload];assert(commands==0 && j.observingExisting);
    state=3;[j pollNativeDownload];[j pollNativeDownload];drain();assert(writes==1 && commands==0);

    j=job(YES);[j prepareNativeDownload];assert(commands==1);
    contextState=3;[j pollNativeDownload];[j pollNativeDownload];drain();assert(writes==1);

    j=job(NO);resultCode=19;[j prepareNativeDownload];drain();
    assert(commands==1 && writes==0 && [lastError containsString:@"19"] && !j.poll && !j.deadline);

    j=job(NO);prepareOK=NO;[j prepareNativeDownload];drain();assert(commands==0 && writes==0 && lastError);

    j=job(NO);holdRead=YES;[j prepareNativeDownload];[j finish:nil error:@"synthetic cancellation"];
    lateRead(item(trackURI,3),nil);drain();assert(commands==0 && writes==0 && !j.poll && !j.deadline);

    j=job(NO);invalidReply=YES;[j prepareNativeDownload];drain();assert(commands==0 && writes==0 && lastError);

    j=job(NO);[j prepareNativeDownload];state=1;j.downloadStarted-=31;
    [j pollNativeDownload];drain();assert(commands==1 && writes==0 && [lastError containsString:@"state 1"]);

    j=job(YES);[j prepareNativeDownload];j.downloadStarted-=31;
    [j pollNativeDownload];drain();assert(commands==1 && writes==0 && [lastError containsString:@"did not enter"]);

    j=job(NO);holdRead=YES;[j prepareNativeDownload];SAPCancelAudioExport();drain();
    assert(commands==0 && writes==0 && [lastError containsString:@"cancelled"] && !atomic_load(&exporting));
    // Refreshed files can be plaintext: keys are not a completion prerequisite.
    j=job(NO);j.refreshAttempted=YES;j.refreshURIs=@[trackURI];j.refreshStarted=NSDate.timeIntervalSinceReferenceDate;state=3;
    [j waitKeys];assert(!writes);[j waitKeys];drain();assert(writes==1&&!lastError&&!j.refreshTimer);

    j=job(NO);j.refreshURIs=@[trackURI];invalidReply=YES;[j waitRemoved];drain();
    assert(commands==0 && writes==0 && lastError);

    j=job(NO);j.refreshURIs=@[trackURI];resultCode=19;[j removeNext:0];drain();
    assert(commands==1 && writes==0 && lastError);

    SAPExportRecoveryFixture *recovery=[SAPExportRecoveryFixture new];recovery.shareOnly=YES;
    NSDictionary *failed=@{@"uri":trackURI},*proof=@{@"stage":@"no_media_key",@"cache_seen":@YES,@"storage_decoded":@1,@"media_key_available":@NO};
    assert(![recovery recoverMissingCachedKey:failed evidence:proof]&&recoveryCalls==0);
    recovery.confirmedDownloadedURIs=[NSSet setWithObject:trackURI];
    recovery.commandRequested=YES;assert(![recovery recoverMissingCachedKey:failed evidence:proof]&&recoveryCalls==0);
    recovery.commandRequested=NO;recovery.observingExisting=YES;assert(![recovery recoverMissingCachedKey:failed evidence:proof]&&recoveryCalls==0);
    recovery.observingExisting=NO;
    assert([recovery recoverMissingCachedKey:failed evidence:proof]&&recoveryCalls==1&&recoveryTargets.count==1&&[recoveryTargets[0][@"uri"]isEqual:trackURI]);
    assert(recovery.refreshAttempted&&recovery.automaticKeyRefresh);
    assert(![recovery recoverMissingCachedKey:failed evidence:proof]&&recoveryCalls==1);

    // A track resolved before its download has no file ids: they are fetched again before writing.
    j=job(NO);j.resolved[0]=@{@"uri":trackURI,@"name":@"First",@"files":@[]};metadataHasFiles=YES;state=3;
    [j prepareNativeDownload];[j pollNativeDownload];[j pollNativeDownload];drain();
    assert(metadataReads==1&&writes==1&&!lastError&&[j.resolved[0][@"files"]count]==1);
    j=job(NO);j.resolved[0]=@{@"uri":trackURI,@"name":@"First",@"files":@[]};state=3;
    [j prepareNativeDownload];[j pollNativeDownload];[j pollNativeDownload];drain();
    assert(metadataReads==1&&writes==0&&[lastError containsString:@"no audio files"]);
    j=job(NO);state=3;[j prepareNativeDownload];[j pollNativeDownload];[j pollNativeDownload];drain();
    assert(metadataReads==0&&writes==1);

    // Album share: only the tracks Spotify does not have are requested, one AddDownload each.
    j=job(YES);j.shareOnly=YES;j.temporaryCaptured=YES;j.temporaryToken=@{@"initial_download_states":@{trackURI:@0,secondURI:@3}};
    secondState=3;[j prepareNativeDownload];assert(commands==1&&preparations==1&&!writes);
    state=3;[j pollNativeDownload];[j pollNativeDownload];drain();assert(writes==1&&commands==1);
    j=job(YES);j.shareOnly=YES;j.temporaryCaptured=YES;j.temporaryToken=@{@"initial_download_states":@{trackURI:@0,secondURI:@0}};
    [j prepareNativeDownload];assert(commands==2&&!writes);

    // A track Spotify accepts but never queues is skipped once the rest is finished, and named.
    j=job(YES);j.shareOnly=YES;j.temporaryCaptured=YES;j.temporaryToken=@{@"initial_download_states":@{trackURI:@0,secondURI:@0}};
    state=3;secondState=0;[j prepareNativeDownload];assert(commands==2&&!writes);
    [j pollNativeDownload];assert(!writes&&j.resolved.count==2);
    j.lastProgress-=61;[j pollNativeDownload];assert(j.resolved.count==1&&[j.resolved[0][@"album_skipped"]isEqual:@[@"Second"]]);
    [j pollNativeDownload];[j pollNativeDownload];drain();assert(writes==1);
    // Nothing downloaded at all is still a failure.
    j=job(YES);j.shareOnly=YES;j.temporaryCaptured=YES;j.temporaryToken=@{@"initial_download_states":@{trackURI:@0,secondURI:@0}};
    [j prepareNativeDownload];[j pollNativeDownload];j.lastProgress-=61;[j pollNativeDownload];drain();
    assert(!writes&&[lastError containsString:@"stopped downloading"]);

    puts("PASS 21 native export workflows: one AddDownload, track and album confirmation, no-start release, cancellation, errors, late callbacks, timer cleanup; Diagnostics off");
}}
