#include "Diagnostics.h"
#import <Foundation/Foundation.h>
#import "TrackDownload.h"
#import "WireProto.h"
#import "NativeOffline.h"
#import "TrackJournal.h"
#import <objc/runtime.h>
#include <assert.h>
static BOOL prepareReady=YES,prepareDeferred;
static void (^pendingPreparation)(BOOL,NSString *);
static BOOL (^pendingRequested)(void);
void SAPPrepareNativeOffline(BOOL (^requested)(void),void (^completion)(BOOL,NSString *)) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(prepareDeferred) {pendingPreparation=completion;pendingRequested=requested;}
        else completion(prepareReady,@"test native preparation");
    });
}
void SAPReadNativeTrackState(NSString *uri) {}
void SAPRequestNativeAlbumDownload(NSString *uri, void (^completion)(BOOL, NSString *)) {
    if (completion) completion(YES, @"test album request");
}
NSUInteger SAPObservedAudioKeyCount(void) { return 0; }
void SAPJournalVerifyTrack(NSString *uri,void (^completion)(NSDictionary *)) {if(completion)completion(nil);}
NSDictionary *SAPNativeOfflineReport(void) { return @{@"test_stub":@YES}; }
// Журнал здесь подменён: проверяем, что транспортный хук отдаёт ему каждый вызов
// сервиса Offline, а TrackDownload отдаёт рабочий канал к ядру.
static NSMutableArray *journalObserved;
static SAPJournalCaller journalCaller;
static unsigned journalRefreshes;
void SAPJournalNoteAction(NSString *name,NSDictionary *facts) {}
void SAPJournalObserveCall(NSString *method, NSData *request, NSData *response, NSString *source) {
    if (!journalObserved) journalObserved = [NSMutableArray array];
    [journalObserved addObject:@{@"method": method ?: @"", @"request": @(request.length),
        @"response": @(response.length), @"source": source ?: @""}];
}
void SAPJournalSetCaller(SAPJournalCaller caller) { journalCaller = [caller copy]; }
BOOL SAPJournalOnOwnQueue(void) { return NO; }
static NSDictionary *nativeFailureForTesting;
static NSCondition *readOnlyGate;
static BOOL readOnlyGateEntered, readOnlyGateRelease;
NSDictionary *SAPJournalNativeErrorForURI(NSString *uri) {return [nativeFailureForTesting[@"uri"] isEqual:uri]?nativeFailureForTesting:nil;}
void SAPJournalRefresh(NSString *reason) { journalRefreshes++; }
void SAPJournalNoteCallIssue(NSString *method,NSString *uri,NSString *channel,NSString *issue) {}
NSString *SAPJournalSummaryText(void) { return @"test journal"; }
NSString *SAPJournalSummaryForReport(NSDictionary *report) {return @"test journal";}
static unsigned journalSaw(NSString *method) {
    unsigned count = 0;
    for (NSDictionary *entry in journalObserved) if ([entry[@"method"] isEqual:method]) count++;
    return count;
}

@interface FakeTrack : NSObject
@property(nonatomic, strong) NSURL *URI;
@property(nonatomic, copy) NSString *trackTitle;
@end
@implementation FakeTrack @end
@interface FakeState : NSObject
@property(nonatomic, strong) FakeTrack *track;
@end
@implementation FakeState @end
@interface SPTEsperantoPlayer : NSObject
@property(nonatomic, strong) FakeState *state;
- (void)addPlayerObserver:(id)observer;
- (void)fetchState:(id)callback on:(id)queue;
- (void)globalPlayerSubscription:(id)subscription gotStateUpdate:(id)state;
@end
@implementation SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer { assert([observer isEqual:@"test"]); }
- (void)fetchState:(id)callback on:(id)queue {}
- (void)globalPlayerSubscription:(id)subscription gotStateUpdate:(id)state {}
@end
@interface FakeLifetime : NSObject
@property(nonatomic) BOOL cancelled, acquired;
@property(nonatomic, copy) dispatch_block_t onCancel;
- (void)cancel;
- (void)acquire;
@end
@implementation FakeLifetime
- (void)cancel { assert(self.acquired); if(self.cancelled)return;self.cancelled = YES;if(self.onCancel)self.onCancel(); }
- (void)acquire { self.acquired = YES; }
@end
@interface SPTEsperantoTransportBridgeImpl : NSObject
@property(nonatomic) unsigned scenario, queries, requests, removes;
@property(nonatomic) unsigned commandBehavior, commandCount;
@property(nonatomic) unsigned playlistBehavior, playlistCount;
@property(nonatomic,copy) void (^playlistLateCallback)(NSData *);
@property(nonatomic) unsigned collectionBehavior, collectionCount;
@property(nonatomic,copy) void (^collectionLateCallback)(NSData *);
@property(nonatomic,copy) void (^commandLateCallback)(NSData *);
@property(nonatomic) unsigned readOnlyBehavior, readOnlyCount;
@property(nonatomic,copy) void (^readOnlyLateCallback)(NSData *);
@property(nonatomic,strong) FakeLifetime *readOnlyLifetime;
@property(nonatomic, copy) NSString *requested;
@property(nonatomic, copy) void (^lateCallback)(NSData *);
@property(nonatomic, copy) BOOL (^errorCallback)(NSData *);
@property(nonatomic, strong) FakeLifetime *streamLifetime;
@property(nonatomic) unsigned contextStreamCount, contextStreamBehavior,itemStreamCount,itemReadCount;
@property(nonatomic, copy) BOOL (^contextStreamCallback)(NSData *);
- (id)callSingle:(NSString *)service method:(NSString *)method payload:(NSData *)payload onResponse:(void (^)(NSData *))callback;
- (id)callStream:(NSString *)service method:(NSString *)method payload:(NSData *)payload onResponse:(BOOL (^)(NSData *))callback;
@end
static NSString *const trackURI = @"spotify:track:1234567890123456789012";
static NSData *join(NSData *a, NSData *b) { NSMutableData *d = [a mutableCopy]; [d appendData:b]; return d; }
@implementation SPTEsperantoTransportBridgeImpl
- (id)callStream:(NSString *)service method:(NSString *)method payload:(NSData *)payload onResponse:(BOOL (^)(NSData *))callback {
    assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);
    if([method isEqual:@"SubscribeItems"]){assert(payload.length==38 && ((uint8_t *)payload.bytes)[0]==0x0a);self.itemStreamCount++;self.streamLifetime=[FakeLifetime new];self.contextStreamCallback=callback;callback(SAPProtoBytes(1,join(SAPProtoBytes(1,[trackURI dataUsingEncoding:NSUTF8StringEncoding]),SAPProtoInteger(2,3))));return self.streamLifetime;}
    assert(payload.length==0);
    self.streamLifetime = [FakeLifetime new];
    if ([method isEqual:@"SubscribeError"]) { self.errorCallback = callback; return self.streamLifetime; }
    assert([method isEqual:@"SubscribeContexts"] || [method isEqual:@"SubscribeContextsProgress"]);
    self.contextStreamCount++; self.contextStreamCallback = callback;
    if (self.contextStreamBehavior == 1) {
        callback([NSData dataWithBytes:(uint8_t[]){0x08,0x01} length:2]);
        callback([NSData dataWithBytes:(uint8_t[]){0x08,0x02} length:2]);
    }
    return self.streamLifetime;
}
- (id)callSingle:(NSString *)service method:(NSString *)method payload:(NSData *)payload onResponse:(void (^)(NSData *))callback {
    if ([method isEqual:@"warmup"]) return nil;
    if (self.scenario == 12) return nil; // Wrong/stale native channel: never answers.
    if([service isEqual:@"spotify.playlist_esperanto.proto.PlaylistService"]) {
        assert([method isEqual:@"SetOfflineState"]);
        assert([SAPProtoString(SAPProtoFields(payload),1)isEqual:@"spotify:playlist:1234567890123456789012"]);
        assert(SAPProtoNumber(SAPProtoFields(payload),3,0)==1);
        self.playlistCount++;
        if(self.playlistBehavior==1)self.playlistLateCallback=callback;
        else if(self.playlistBehavior==2)callback(nil);
        else if(self.playlistBehavior==3)@throw [NSException exceptionWithName:@"TestInvocationException" reason:nil userInfo:nil];
        else callback(NSData.data);
        return [FakeLifetime new];
    }
    if([method isEqual:@"GetContexts"]) {
        assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);
        self.readOnlyCount++;self.readOnlyLifetime=[FakeLifetime new];
        if(self.readOnlyBehavior==1)self.readOnlyLateCallback=callback;
        else if(self.readOnlyBehavior==3)callback(nil);
        else {
            if(self.readOnlyBehavior==2) {
                [readOnlyGate lock];readOnlyGateEntered=YES;[readOnlyGate broadcast];
                while(!readOnlyGateRelease)[readOnlyGate wait];
                [readOnlyGate unlock];
            }
            callback(NSData.data);
        }
        return self.readOnlyLifetime;
    }
    if([service isEqual:@"spotify.collection_esperanto.proto.CollectionService"]) {
        assert([method isEqual:@"Add"]);
        // Independent exact 40-byte native album-button payload from log 22:
        // items(field2) -> item.uri(field1) -> 36 UTF-8 album URI bytes.
        const uint8_t *bytes=payload.bytes;assert(payload.length==40 && bytes[0]==0x12 && bytes[1]==0x26 && bytes[2]==0x0a && bytes[3]==0x24);
        assert(!memcmp(bytes+4,"spotify:album:1234567890123456789012",36));
        self.collectionCount++;
        if(self.collectionBehavior==1)self.collectionLateCallback=callback;
        else if(self.collectionBehavior==2)callback(nil);
        else callback([NSData dataWithBytes:(uint8_t[]){0x0a,0x03,0x08,0xc8,0x01} length:5]);
        return [FakeLifetime new];
    }
    assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);
    if([method isEqual:@"RemoveDownload"] && payload.length==38 && !memcmp((uint8_t *)payload.bytes+2,"spotify:album:",14)) {
        assert(((uint8_t*)payload.bytes)[0]==0x12 && ((uint8_t*)payload.bytes)[1]==0x24);
        assert(!memcmp((uint8_t*)payload.bytes+2,"spotify:album:1234567890123456789012",36));
        self.removes++;callback(NSData.data);return [FakeLifetime new];
    }
    if([method isEqual:@"SetOfflinePlaybackAllowed"]) {
        self.commandCount++;assert([payload isEqual:SAPProtoInteger(1,1)]);
        if(self.commandBehavior==1)self.commandLateCallback=callback;
        else if(self.commandBehavior==2)callback(nil);
        else if(self.commandBehavior==3)@throw [NSException exceptionWithName:@"TestInvocationException" reason:nil userInfo:nil];
        else callback(SAPProtoInteger(1,1));
        return [FakeLifetime new];
    }
    if ([method isEqual:@"GetOfflinePlaybackStatus"]) {
        callback([NSData dataWithBytes:(uint8_t[]){0x08,0x01} length:2]);
    } else if ([method isEqual:@"AddDownload"] || [method isEqual:@"RemoveDownload"]) {
        // DownloadRequest.uri is field 2; device omitted means local device.
        // Header 0x12 0x24 and these exact 36 UTF-8 bytes are independent of decoder.
        assert(payload.length == 38 && ((uint8_t *)payload.bytes)[0] == 0x12 && ((uint8_t *)payload.bytes)[1] == 0x24);
        assert(memcmp((uint8_t *)payload.bytes + 2, trackURI.UTF8String, 36) == 0);
        if ([method isEqual:@"RemoveDownload"]) { self.removes++; callback(NSData.data); }
        else {
            self.requests++; self.requested = trackURI;
            if (self.scenario == 1) callback([NSData dataWithBytes:(uint8_t[]){0x08,0x17} length:2]); // NOT_ALLOWED=23
            else if (self.scenario == 6) self.lateCallback = callback;
            else if (self.scenario == 10) callback([NSData dataWithBytes:(uint8_t[]){0xff} length:1]);
            else if (self.scenario == 11) callback(nil);
            else callback(NSData.data); // Valid protobuf default error=0.
        }
    } else if ([method isEqual:@"GetItems"]) {
        self.itemReadCount++;
        assert(payload.length == 38 && ((uint8_t *)payload.bytes)[0] == 0x0a && ((uint8_t *)payload.bytes)[1] == 0x24);
        assert(memcmp((uint8_t *)payload.bytes + 2, trackURI.UTF8String, 36) == 0);
        unsigned status = self.scenario == 3 ? 3 : self.scenario >= 14 ? 1 : 0;
        if (self.requested) {
            self.queries++;
            if(self.scenario==14 || self.scenario==16) {
                status=self.queries<=4?1:self.queries==5?5:3;
                if(self.scenario==16 && self.queries==1)
                    nativeFailureForTesting=@{@"uri":trackURI,@"code":@7004,@"name":@"sync_error_offline_key_failed",@"at":@(NSDate.date.timeIntervalSince1970)};
            }
            else if(self.scenario==15 || self.scenario==17) {
                status=1;
                if(self.scenario==17 && self.queries==1)
                    nativeFailureForTesting=@{@"uri":trackURI,@"code":@7004,@"name":@"sync_error_offline_key_failed",@"at":@(NSDate.date.timeIntervalSince1970)};
            }
            else if (self.scenario == 2 || self.scenario == 8) status = 0;
            else if (self.scenario == 4) status = 6;
            else if (self.scenario == 5) { unsigned values[] = {3,5,3,3}; status = values[MIN(self.queries - 1, 3)]; }
            else if (self.scenario == 9) { self.errorCallback([NSData dataWithBytes:(uint8_t[]){0x08,0x17} length:2]); status = 1; }
            else status = self.queries == 1 ? 6 : self.queries < 4 ? 5 : 3;
        }
        NSString *uri = self.scenario == 8 ? @"spotify:track:2222222222222222222222" : trackURI;
        NSData *item = join(SAPProtoBytes(1, [uri dataUsingEncoding:NSUTF8StringEncoding]), SAPProtoInteger(2, status));
        item = join(item, SAPProtoInteger(4, status == 3 ? 100 : 20));
        callback(SAPProtoBytes(1, item));
    } else assert(!"unexpected RPC");
    return [FakeLifetime new];
}
@end
@interface SPTEsperantoCosmosTransport : SPTEsperantoTransportBridgeImpl @end
@implementation SPTEsperantoCosmosTransport
- (id)callSingle:(NSString *)service method:(NSString *)method payload:(NSData *)payload onResponse:(void (^)(NSData *))callback {
    // Initial GetItems answers; subsequent reads silently disappear after AddDownload.
    if(self.scenario==13 && self.requests>0 && [method isEqual:@"GetItems"])return [FakeLifetime new];
    return [super callSingle:service method:method payload:payload onResponse:callback];
}
@end
static void waitFor(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
    if (!condition()) NSLog(@"Timeout: %@", SAPTrackDownloadReport());
    assert(condition());
}
static void reset(SPTEsperantoTransportBridgeImpl *t, unsigned scenario) {
    t.scenario = scenario; t.queries = 0; t.requested = nil; t.errorCallback = nil;
}
int main(void) { @autoreleasepool {
    readOnlyGate=[NSCondition new];
    SAPDiagnosticsSetEnabled(true);

    SAPInstallTrackDownloader(); SAPInstallTrackDownloader();
    assert([SAPTrackDownloadReport()[@"installed_hooks"] count] == 7);
    // A valid mutation with no verified endpoint is definitely not invoked.
    __block unsigned unsentReplies=0;
    void (^unsent)(NSData *,NSString *,SAPCommandInvocationDisposition)=^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        assert(NSThread.isMainThread && !data && [error isEqual:@"No verified Spotify transport. Refresh the device state first."]);
        assert(disposition==SAPCommandNotInvoked);unsentReplies++;
    };
    SAPCallOfflineCommandOnceWithDisposition(@"AddDownload",SAPProtoBytes(2,[@"spotify:album:1234567890123456789012" dataUsingEncoding:NSUTF8StringEncoding]),unsent);
    SAPSetPlaylistOfflineOnceWithDisposition(@"spotify:playlist:1234567890123456789012",YES,unsent);
    waitFor(^BOOL{return unsentReplies==2;});
    puts("PASS: album and playlist mutations with no verified endpoint report NotInvoked on main");
    SPTEsperantoPlayer *player = [SPTEsperantoPlayer new];
    FakeTrack *track = [FakeTrack new]; track.URI = [NSURL URLWithString:trackURI]; track.trackTitle = @"Original track";
    FakeState *state = [FakeState new]; state.track = track; player.state = state;
    [player addPlayerObserver:@"test"];
    __block NSString *last;
    void (^callback)(NSString *) = ^(NSString *message) { last = message; };
    SAPDownloadCurrentTrack(callback); assert(last.length && !SAPTrackDownloadActive());
    SPTEsperantoTransportBridgeImpl *bad = [SPTEsperantoTransportBridgeImpl new]; bad.scenario = 12;
    [bad callSingle:@"" method:@"warmup" payload:NSData.data onResponse:nil];
    SPTEsperantoTransportBridgeImpl *t = [SPTEsperantoTransportBridgeImpl new];
    [t callSingle:@"" method:@"warmup" payload:NSData.data onResponse:nil];
    SAPDownloadCurrentTrack(callback);
    waitFor(^BOOL{ return t.requests == 1; });
    assert(![SAPTrackDownloadReport()[@"phase"] isEqual:@"completed"]);
    FakeTrack *next = [FakeTrack new]; next.URI = [NSURL URLWithString:@"spotify:track:2222222222222222222222"]; next.trackTitle = @"Next";
    state.track = next;
    waitFor(^BOOL{ return !SAPTrackDownloadActive(); });
    assert([SAPTrackDownloadReport()[@"phase"] isEqual:@"completed"] && t.queries == 5);
    assert([SAPTrackDownloadReport()[@"transport_candidate"] unsignedIntValue] == 2 && bad.requests == 0);
    assert([SAPTrackDownloadReport()[@"track_uri"] isEqual:trackURI] && t.streamLifetime.cancelled);
    unsigned queries = t.queries;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.04];
    while (until.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
    assert(t.queries == queries); // No polling after completion.
    state.track = track;
    [bad callSingle:@"" method:@"warmup" payload:NSData.data onResponse:nil]; // Unrelated calls must not replace proven channel.
    for (unsigned scenario = 1; scenario <= 11; scenario++) {
        if (scenario == 7) continue;
        reset(t, scenario); unsigned requests = t.requests;
        SAPDownloadCurrentTrack(callback);
        if (scenario == 4) {
            waitFor(^BOOL{ return t.requests > requests && t.queries > 0; });
            SAPCancelTrackDownload(); waitFor(^BOOL{ return !SAPTrackDownloadActive(); });
            assert(t.removes == 1 && [SAPTrackDownloadReport()[@"phase"] isEqual:@"cancelled"]); continue;
        }
        waitFor(^BOOL{ return [SAPTrackDownloadReport()[@"active"] boolValue] || t.requests > requests || scenario == 3; });
        if (scenario == 3) waitFor(^BOOL{ return [SAPTrackDownloadReport()[@"monitoring_existing"] boolValue]; });
        waitFor(^BOOL{ return !SAPTrackDownloadActive(); });
        NSDictionary *report = SAPTrackDownloadReport();
        if (scenario == 1) assert([report[@"phase"] isEqual:@"rejected"] && [report[@"response_error"] intValue] == 23);
        if (scenario == 2 || scenario == 8) assert([report[@"phase"] isEqual:@"unconfirmed"] && ![report[@"detail"] containsString:@"не принял"]);
        if (scenario == 3) assert([report[@"phase"] isEqual:@"completed"] && t.requests == requests);
        if (scenario == 5) assert([report[@"phase"] isEqual:@"completed"] && t.queries == 4);
        if (scenario == 6) assert([report[@"phase"] isEqual:@"unconfirmed"] && report[@"response_error"] == NSNull.null);
        if (scenario == 9) assert([report[@"phase"] isEqual:@"failed"] && [report[@"offline_stream_error"] intValue] == 23);
        if (scenario == 10 || scenario == 11) assert([report[@"phase"] isEqual:@"invalid_response"]);
    }
    // A delayed completion from an older request must not corrupt a new job.
    void (^old)(NSData *) = t.lateCallback;
    reset(t, 0); unsigned requests = t.requests;
    SAPDownloadCurrentTrack(callback); waitFor(^BOOL{ return t.requests > requests; });
    old([NSData dataWithBytes:(uint8_t[]){0x08,0x17} length:2]);
    waitFor(^BOOL{ return !SAPTrackDownloadActive(); });
    assert([SAPTrackDownloadReport()[@"phase"] isEqual:@"completed"]);
    assert([SAPTrackDownloadReport()[@"history"] count] == 8);
    track.URI = [NSURL URLWithString:@"spotify:album:1234567890123456789012"];
    requests = t.requests; SAPDownloadCurrentTrack(callback); assert(t.requests == requests);
    track.URI = [NSURL URLWithString:trackURI];
    prepareReady=NO;
    SAPDownloadCurrentTrack(callback);
    waitFor(^BOOL{return [SAPTrackDownloadReport()[@"phase"] isEqual:@"native_preparation_failed"];});
    assert([SAPTrackDownloadReport()[@"phase"] isEqual:@"native_preparation_failed"]&&t.requests==requests);
    prepareReady=YES;prepareDeferred=YES;
    SAPDownloadCurrentTrack(callback);waitFor(^BOOL{return pendingPreparation!=nil;});
    SAPCancelTrackDownload();waitFor(^BOOL{return !SAPTrackDownloadActive();});
    assert(!pendingRequested());pendingPreparation(YES,@"late preparation");
    prepareDeferred=NO;reset(t,0);
    SAPDownloadCurrentTrack(callback);waitFor(^BOOL{return t.requests>requests;});
    waitFor(^BOOL{return !SAPTrackDownloadActive();});
    assert([SAPTrackDownloadReport()[@"phase"] isEqual:@"completed"]);
    // Хук транспорта обязан показать журналу и команду, и опросы состояния, не меняя их.
    assert(journalRefreshes > 0 && journalCaller != nil);
    assert(journalSaw(@"AddDownload") > 0 && journalSaw(@"GetItems") > 0);
    assert(journalSaw(@"GetOfflinePlaybackStatus") > 0 && journalSaw(@"SubscribeError") > 0);
    for (NSDictionary *entry in journalObserved) assert([entry[@"source"] hasPrefix:@"app:"] || [entry[@"source"] hasPrefix:@"menu:"]);
    unsigned beforeQueries = t.queries, seen = journalSaw(@"GetItems");
    id lifetime = journalCaller(@"GetItems", SAPProtoBytes(1, [trackURI dataUsingEncoding:NSUTF8StringEncoding]), NO, 0, ^(NSData *data){});
    assert(lifetime != nil && t.queries == beforeQueries + 1 && journalSaw(@"GetItems") == seen + 1);
    // A proven Cosmos route may stop answering later. Replay only its read on
    // the native bridge, while keeping the acknowledged AddDownload single-shot.
    SPTEsperantoCosmosTransport *cosmos=[SPTEsperantoCosmosTransport new];cosmos.scenario=13;
    unsigned observedBefore=journalSaw(@"GetItems");
    [cosmos callSingle:@"spotify.offline_esperanto.proto.Offline" method:@"GetItems"
        payload:SAPProtoBytes(1,[trackURI dataUsingEncoding:NSUTF8StringEncoding]) onResponse:^(NSData *data){}];
    assert(journalSaw(@"GetItems")==observedBefore+1); // Cosmos -> bridge counted once
    unsigned bridgeAdds=t.requests;
    SAPDownloadCurrentTrack(callback);waitFor(^BOOL{return cosmos.requests==1;});
    waitFor(^BOOL{return !SAPTrackDownloadActive();});
    assert([SAPTrackDownloadReport()[@"phase"] isEqual:@"completed"]);
    assert([SAPTrackDownloadReport()[@"transport_class"] isEqual:@"SPTEsperantoTransportBridgeImpl"]);
    assert(cosmos.requests==1 && t.requests==bridgeAdds);
    // Even a burst of native calls creates at most 64 one-shot watchdogs.
    // Timers drain after their deadline and do not form an idle polling loop.
    waitFor(^BOOL{return [SAPTrackDownloadReport()[@"application_watches_pending"] unsignedIntegerValue]==0;});
    NSUInteger droppedBefore=[SAPTrackDownloadReport()[@"application_watches_dropped"] unsignedIntegerValue];
    for(unsigned i=0;i<100;i++) {
        [t callSingle:@"spotify.offline_esperanto.proto.Offline" method:@"GetItems"
            payload:SAPProtoBytes(1,[trackURI dataUsingEncoding:NSUTF8StringEncoding]) onResponse:^(NSData *data){}];
        assert([SAPTrackDownloadReport()[@"application_watches_pending"] unsignedIntegerValue]==0);
    }
    assert([SAPTrackDownloadReport()[@"application_watches_dropped"] unsignedIntegerValue]==droppedBefore);
    puts("PASS: answered native requests release their watchdog immediately without filling the 64-call budget");
    SPTEsperantoTransportBridgeImpl *quiet=[SPTEsperantoTransportBridgeImpl new];quiet.scenario=12;
    for(unsigned i=0;i<74;i++)
        [quiet callSingle:@"spotify.offline_esperanto.proto.Offline" method:@"GetItems"
            payload:SAPProtoBytes(1,[trackURI dataUsingEncoding:NSUTF8StringEncoding]) onResponse:^(NSData *data){assert(!"unexpected reply");}];
    assert([SAPTrackDownloadReport()[@"application_watches_pending"] unsignedIntegerValue]<=64);
    assert([SAPTrackDownloadReport()[@"application_watches_dropped"] unsignedIntegerValue]>=10);
    waitFor(^BOOL{return [SAPTrackDownloadReport()[@"application_watches_pending"] unsignedIntegerValue]==0;});
    assert(quiet.requests==0);
    // Neither an old ERROR state nor a fresh key_denied is a permanent verdict.
    // Acknowledged AddDownload is sent once, while ERROR -> DOWNLOADING ->
    // DOWNLOADED is observed during the bounded settling period.
    for(unsigned scenario=14;scenario<=16;scenario++) {
        nativeFailureForTesting=@{@"uri":trackURI,@"code":@7004,@"name":@"sync_error_offline_key_failed",@"at":@(NSDate.date.timeIntervalSince1970-60)};
        reset(t,scenario);unsigned addsBefore=t.requests;SAPDownloadCurrentTrack(callback);
        waitFor(^BOOL{return t.requests>addsBefore;});
        waitFor(^BOOL{return [SAPTrackDownloadReport()[@"phase"] isEqual:@"waiting_error_update"];});
        waitFor(^BOOL{return !SAPTrackDownloadActive();});
        NSDictionary *value=SAPTrackDownloadReport();
        assert(t.requests==addsBefore+1);
        if(scenario==15) {
            assert([value[@"phase"] isEqual:@"failed"]);
            assert(![value[@"native_error_during_attempt"] boolValue]);
            assert(![value[@"detail"] containsString:@"key_denied / 7004"]);
        } else assert([value[@"phase"] isEqual:@"completed"] && t.queries==7);
    }
    reset(t,17);unsigned beforeNativeFailure=t.requests;SAPDownloadCurrentTrack(callback);waitFor(^BOOL{return t.requests>beforeNativeFailure;});waitFor(^BOOL{return !SAPTrackDownloadActive();});
    assert([SAPTrackDownloadReport()[@"phase"] isEqual:@"failed"]);
    assert([SAPTrackDownloadReport()[@"native_error_during_attempt"] boolValue]);
    assert([SAPTrackDownloadReport()[@"detail"] containsString:@"key_denied / 7004"]);
    assert([SAPTrackDownloadReport()[@"error_wait_seconds"] doubleValue]>=0.12);
    nativeFailureForTesting=nil;
    // Optional diagnostics must not be required for AddDownload, verified
    // completion or read-only fallback. No extra streams or journal work.
    SAPDiagnosticsSetEnabled(false);reset(t,0);t.streamLifetime=nil;t.errorCallback=nil;
    NSUInteger oldJournal=journalObserved.count;unsigned oldRefresh=journalRefreshes;unsigned oldAdds=t.requests;
    SAPDownloadCurrentTrack(callback);waitFor(^BOOL{return t.requests>oldAdds;});
    waitFor(^BOOL{return !SAPTrackDownloadActive();});
    assert([SAPTrackDownloadReport()[@"phase"] isEqual:@"completed"] && t.requests==oldAdds+1);
    assert(t.streamLifetime==nil && journalObserved.count==oldJournal && journalRefreshes==oldRefresh);
    assert([SAPTrackDownloadReport()[@"application_watches_pending"] unsignedIntegerValue]==0);
    // Switching off in the middle cancels only the diagnostic stream.
    SAPDiagnosticsSetEnabled(true);reset(t,4);oldAdds=t.requests;unsigned oldRemoves=t.removes;
    SAPDownloadCurrentTrack(callback);waitFor(^BOOL{return t.requests>oldAdds && t.streamLifetime!=nil;});
    FakeLifetime *diagnosticStream=t.streamLifetime;SAPDiagnosticsSetEnabled(false);
    waitFor(^BOOL{return diagnosticStream.cancelled;});assert(SAPTrackDownloadActive() && t.removes==oldRemoves);
    SAPCancelTrackDownload();waitFor(^BOOL{return !SAPTrackDownloadActive();});assert(t.removes==oldRemoves+1);
    SAPDiagnosticsSetEnabled(true);
    puts("PASS: diagnostics OFF keeps native download and completion; toggling OFF does not cancel the track");
    // Unlike read-only requests, explicit mutations must never fall back to a
    // second transport, including after a timeout or invalid response.
    reset(t,0);
    // Hold the worker inside one transport call, enqueue a second request,
    // cancel it before its worker turn, then release the first request. The
    // canceled request must never reach callSingle.
    readOnlyGateEntered=NO;readOnlyGateRelease=NO;t.readOnlyBehavior=2;
    unsigned beforeReadOnly=t.readOnlyCount;__block unsigned blockerReplies=0;
    dispatch_block_t blockerCancel=SAPCallReadOnlyServiceCancellable(
        @"spotify.offline_esperanto.proto.Offline",@"GetContexts",NSData.data,
        ^(NSData *d,NSString *e){assert(d && !e);blockerReplies++;});
    waitFor(^BOOL{[readOnlyGate lock];BOOL entered=readOnlyGateEntered;[readOnlyGate unlock];return entered;});
    __block unsigned canceledReplies=0;
    dispatch_block_t cancelBeforeSend=SAPCallReadOnlyServiceCancellable(
        @"spotify.offline_esperanto.proto.Offline",@"GetContexts",NSData.data,
        ^(NSData *d,NSString *e){canceledReplies++;});
    cancelBeforeSend();cancelBeforeSend();
    [readOnlyGate lock];readOnlyGateRelease=YES;[readOnlyGate broadcast];[readOnlyGate unlock];
    waitFor(^BOOL{return blockerReplies==1;});
    assert(t.readOnlyCount==beforeReadOnly+1 && canceledReplies==0);
    blockerCancel=nil;cancelBeforeSend=nil;t.readOnlyBehavior=0;
    puts("PASS: cancellable read-only request canceled before send is skipped on worker");

    // A sent but unanswered read owns an acquired lifetime. Cancellation
    // releases it, suppresses completion, and makes a late native reply inert.
    t.readOnlyBehavior=1;beforeReadOnly=t.readOnlyCount;__block unsigned lateReplies=0;
    dispatch_block_t cancelActive=SAPCallReadOnlyServiceCancellable(
        @"spotify.offline_esperanto.proto.Offline",@"GetContexts",NSData.data,
        ^(NSData *d,NSString *e){lateReplies++;});
    waitFor(^BOOL{return t.readOnlyCount==beforeReadOnly+1 && t.readOnlyLifetime.acquired;});
    FakeLifetime *canceledReadLifetime=t.readOnlyLifetime;cancelActive();
    waitFor(^BOOL{return canceledReadLifetime.cancelled;});
    assert(t.readOnlyLateCallback!=nil && lateReplies==0);
    t.readOnlyLateCallback(NSData.data);
    until=[NSDate dateWithTimeIntervalSinceNow:0.08];
    while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    assert(lateReplies==0 && t.readOnlyCount==beforeReadOnly+1 && canceledReadLifetime.cancelled);
    cancelActive=nil;t.readOnlyBehavior=0;
    puts("PASS: active read cancellation cancels acquired lifetime and ignores late reply");

    // Streams are pinned to the verified Offline transport and stay open after
    // the first event. The initial-response deadline must not become idle polling.
    t.contextStreamBehavior=1;unsigned beforeStreams=t.contextStreamCount;
    NSMutableArray *streamEvents=[NSMutableArray array];__block unsigned streamErrors=0;
    dispatch_block_t cancelStream=SAPSubscribeReadOnlyService(
        @"spotify.offline_esperanto.proto.Offline",@"SubscribeContexts",NSData.data,
        ^(NSData *data,NSString *error){if(error)streamErrors++;else [streamEvents addObject:data];});
    waitFor(^BOOL{return streamEvents.count==2;});
    FakeLifetime *activeStreamLifetime=t.streamLifetime;
    assert(t.contextStreamCount==beforeStreams+1 && activeStreamLifetime.acquired && !activeStreamLifetime.cancelled);
    until=[NSDate dateWithTimeIntervalSinceNow:0.2];
    while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    assert(streamEvents.count==2 && streamErrors==0 && !activeStreamLifetime.cancelled);
    BOOL (^lateStreamEvent)(NSData *)=t.contextStreamCallback;
    cancelStream();cancelStream();waitFor(^BOOL{return activeStreamLifetime.cancelled;});
    lateStreamEvent(NSData.data);
    until=[NSDate dateWithTimeIntervalSinceNow:0.04];
    while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    assert(streamEvents.count==2 && streamErrors==0 && t.contextStreamCount==beforeStreams+1);
    cancelStream=nil;t.contextStreamBehavior=0;
    puts("PASS: stream delivers multiple events, disarms its first-response deadline, and explicit cancellation suppresses late events");

    // Queue a stream behind a blocked worker and cancel it before dispatch.
    readOnlyGateEntered=NO;readOnlyGateRelease=NO;t.readOnlyBehavior=2;
    beforeReadOnly=t.readOnlyCount;beforeStreams=t.contextStreamCount;blockerReplies=0;
    blockerCancel=SAPCallReadOnlyServiceCancellable(
        @"spotify.offline_esperanto.proto.Offline",@"GetContexts",NSData.data,
        ^(NSData *d,NSString *e){assert(d&&!e);blockerReplies++;});
    waitFor(^BOOL{[readOnlyGate lock];BOOL entered=readOnlyGateEntered;[readOnlyGate unlock];return entered;});
    __block unsigned canceledStreamReplies=0;
    dispatch_block_t cancelQueuedStream=SAPSubscribeReadOnlyService(
        @"spotify.offline_esperanto.proto.Offline",@"SubscribeContextsProgress",NSData.data,
        ^(NSData *d,NSString *e){canceledStreamReplies++;});
    cancelQueuedStream();
    [readOnlyGate lock];readOnlyGateRelease=YES;[readOnlyGate broadcast];[readOnlyGate unlock];
    waitFor(^BOOL{return blockerReplies==1;});
    until=[NSDate dateWithTimeIntervalSinceNow:0.04];
    while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    assert(t.readOnlyCount==beforeReadOnly+1 && t.contextStreamCount==beforeStreams && canceledStreamReplies==0);
    blockerCancel=nil;cancelQueuedStream=nil;t.readOnlyBehavior=0;
    puts("PASS: stream canceled before its worker turn never calls the transport");

    // An unanswered active stream times out once, releases its lifetime, and
    // ignores a native callback delivered after cleanup.
    __block unsigned timeoutErrors=0,timeoutEvents=0;beforeStreams=t.contextStreamCount;
    dispatch_block_t timeoutStream=SAPSubscribeReadOnlyService(
        @"spotify.offline_esperanto.proto.Offline",@"SubscribeContexts",NSData.data,
        ^(NSData *d,NSString *e){if(e)timeoutErrors++;else timeoutEvents++;});
    waitFor(^BOOL{return t.contextStreamCount==beforeStreams+1 && t.streamLifetime.acquired;});
    FakeLifetime *timedOutStreamLifetime=t.streamLifetime;BOOL (^lateTimeoutEvent)(NSData *)=t.contextStreamCallback;
    waitFor(^BOOL{return timeoutErrors==1 && timedOutStreamLifetime.cancelled;});
    lateTimeoutEvent(NSData.data);
    until=[NSDate dateWithTimeIntervalSinceNow:0.2];
    while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    assert(timeoutErrors==1 && timeoutEvents==0 && timedOutStreamLifetime.cancelled);
    timeoutStream();timeoutStream=nil;
    __block BOOL rejectedStream=NO;beforeStreams=t.contextStreamCount;
    SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"AddDownload",NSData.data,
        ^(NSData *d,NSString *e){assert(!d&&e.length);rejectedStream=YES;});
    waitFor(^BOOL{return rejectedStream;});assert(t.contextStreamCount==beforeStreams);
    puts("PASS: first-response timeout reports one error and unsupported mutating stream names are rejected before send");

    // Native endpoint discovery is weak. During renewal, the old stream is
    // deliberately its endpoint's only owner until the replacement is healthy.
    __weak SPTEsperantoTransportBridgeImpl *leasedEndpoint;
    __block unsigned leaseEvents=0,leaseErrors=0;
    __block dispatch_block_t cancelOldLease=nil,cancelNewLease=nil;
    @autoreleasepool {
        SPTEsperantoTransportBridgeImpl *ephemeral=[SPTEsperantoTransportBridgeImpl new];
        ephemeral.contextStreamBehavior=1;leasedEndpoint=ephemeral;
        [ephemeral callSingle:@"spotify.offline_esperanto.proto.Offline" method:@"GetContexts"
            payload:NSData.data onResponse:^(NSData *data){assert(data);}];
        cancelOldLease=SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"SubscribeContexts",NSData.data,
            ^(NSData *data,NSString *error){if(error)leaseErrors++;else leaseEvents++;});
        waitFor(^BOOL{return leaseEvents==2;});
    }
    assert(leasedEndpoint && leasedEndpoint.streamLifetime.acquired);
    FakeLifetime *oldLeaseLifetime=leasedEndpoint.streamLifetime;
    oldLeaseLifetime.onCancel=^{assert(leasedEndpoint && leasedEndpoint.streamLifetime.acquired && !leasedEndpoint.streamLifetime.cancelled);};
    cancelNewLease=SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"SubscribeContextsProgress",NSData.data,
        ^(NSData *data,NSString *error){if(error)leaseErrors++;else leaseEvents++;});
    cancelOldLease();waitFor(^BOOL{return oldLeaseLifetime.cancelled && leaseEvents==4;});cancelOldLease=nil;
    FakeLifetime *newLeaseLifetime=leasedEndpoint.streamLifetime;
    assert(newLeaseLifetime!=oldLeaseLifetime && newLeaseLifetime.acquired && oldLeaseLifetime.cancelled);
    assert(leasedEndpoint && !newLeaseLifetime.cancelled && leaseErrors==0);
    cancelNewLease();waitFor(^BOOL{return newLeaseLifetime.cancelled;});cancelNewLease=nil;
    waitFor(^BOOL{return leasedEndpoint==nil;});
    oldLeaseLifetime.onCancel=nil;oldLeaseLifetime=nil;newLeaseLifetime=nil;
    puts("PASS: replacement stream acquires before the old lease cancels; an endpoint owned only by streams is released after every cancellation");

    // Item streams use the exact item request for discovery, never a context probe.
    unsigned itemReadsBefore=t.itemReadCount,itemStreamsBefore=t.itemStreamCount,contextReadsBefore=t.readOnlyCount,addsBeforeItems=t.requests;
    __block unsigned itemEvents=0,itemErrors=0;
    dispatch_block_t cancelItems=SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"SubscribeItems",SAPProtoBytes(1,[trackURI dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){if(error)itemErrors++;else {assert([SAPProtoString(SAPProtoFields(SAPProtoData(SAPProtoFields(data),1)),1)isEqual:trackURI]);itemEvents++;}});
    waitFor(^BOOL{return itemEvents==1||itemErrors>0;});
    assert(itemEvents==1&&itemErrors==0&&t.itemReadCount==itemReadsBefore+1&&t.itemStreamCount==itemStreamsBefore+1&&t.readOnlyCount==contextReadsBefore&&t.requests==addsBeforeItems);
    FakeLifetime *itemLifetime=t.streamLifetime;BOOL (^lateItem)(NSData *)=t.contextStreamCallback;
    assert(itemLifetime.acquired&&!itemLifetime.cancelled);cancelItems();waitFor(^BOOL{return itemLifetime.cancelled;});cancelItems=nil;lateItem(NSData.data);
    until=[NSDate dateWithTimeIntervalSinceNow:.08];while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];assert(itemEvents==1&&itemErrors==0);
    puts("PASS: SubscribeItems probes exact GetItems once, acquires/cancels its native lifetime, ignores late events, and sends no mutations or context queries");

    // Retire the item proof as well before testing context-route discovery independently.
    @autoreleasepool {SPTEsperantoTransportBridgeImpl *temporaryProof=[SPTEsperantoTransportBridgeImpl new];[temporaryProof callSingle:@"spotify.offline_esperanto.proto.Offline" method:@"GetContexts" payload:NSData.data onResponse:^(NSData *data){assert(data);}];}
    // Once that last proof disappears, a replacement may establish fresh
    // evidence with a bounded read-only probe of a discovered native endpoint.
    t.contextStreamBehavior=1;unsigned recoveryReads=t.readOnlyCount,recoveryAdds=t.requests;
    __block unsigned recoveredEvents=0,recoveredErrors=0;
    dispatch_block_t recoveredStream=SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"SubscribeContexts",NSData.data,
        ^(NSData *data,NSString *error){if(error)recoveredErrors++;else recoveredEvents++;});
    waitFor(^BOOL{return recoveredEvents==2 || recoveredErrors>0;});
    assert(recoveredEvents==2 && recoveredErrors==0 && t.readOnlyCount==recoveryReads+1 && t.requests==recoveryAdds);
    FakeLifetime *recoveredLifetime=t.streamLifetime;recoveredStream();waitFor(^BOOL{return recoveredLifetime.cancelled;});recoveredStream=nil;t.contextStreamBehavior=0;
    puts("PASS: a lost weak proof recovers through one bounded native read-only probe and starts a healthy stream without replaying AddDownload");

    // Invalid replies and unanswered reads may try each available candidate
    // once. Completion and late callbacks cannot start an unbounded retry loop.
    t.readOnlyBehavior=1;cosmos.readOnlyBehavior=3;
    unsigned fallbackReads=t.readOnlyCount,invalidReads=cosmos.readOnlyCount;
    __block unsigned fallbackErrors=0;
    [t callSingle:@"spotify.offline_esperanto.proto.Offline" method:@"GetOfflinePlaybackStatus" payload:NSData.data onResponse:^(NSData *data){}];
    dispatch_block_t cancelFallback=SAPCallReadOnlyServiceCancellable(@"spotify.offline_esperanto.proto.Offline",@"GetContexts",NSData.data,
        ^(NSData *data,NSString *error){assert(!data && [error isEqual:@"Spotify did not answer the request"]);fallbackErrors++;});
    waitFor(^BOOL{return fallbackErrors==1;});
    assert(t.readOnlyCount==fallbackReads+1 && cosmos.readOnlyCount==invalidReads+1);
    void(^lateFallback)(NSData *)=t.readOnlyLateCallback;lateFallback(NSData.data);
    until=[NSDate dateWithTimeIntervalSinceNow:.2];
    while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(fallbackErrors==1 && t.readOnlyCount==fallbackReads+1 && cosmos.readOnlyCount==invalidReads+1);
    cancelFallback();cancelFallback=nil;t.readOnlyBehavior=0;cosmos.readOnlyBehavior=0;
    puts("PASS: timeout and invalid read responses exhaust a finite fallback list once, report the exact error, and ignore late replies without mutation replay");

    __block BOOL answered=NO;
    SAPCallReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"GetOfflinePlaybackStatus",NSData.data,^(NSData *d,NSString *e){assert(d && !e);answered=YES;});
    waitFor(^BOOL{return answered;});
    for(unsigned behavior=0;behavior<3;behavior++) {
        t.commandBehavior=behavior;unsigned before=t.commandCount;__block unsigned completions=0;
        SAPCallOfflineCommandOnce(@"SetOfflinePlaybackAllowed",SAPProtoInteger(1,1),^(NSData *d,NSString *e){
            assert(behavior==0?(d!=nil && e==nil):(d==nil && e!=nil));completions++;
        });
        waitFor(^BOOL{return completions==1;});assert(t.commandCount==before+1 && cosmos.commandCount==0 && bad.commandCount==0);
        if(behavior==1){t.commandLateCallback(SAPProtoInteger(1,1));
            NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.08];
            while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
            assert(completions==1 && t.commandCount==before+1);
        }
    }
    unsigned before=t.commandCount;answered=NO;
    SAPCallOfflineCommandOnce(@"UnknownMutation",NSData.data,^(NSData *d,NSString *e){assert(!d && e);answered=YES;});
    waitFor(^BOOL{return answered;});assert(t.commandCount==before);
    puts("PASS: explicit enable uses one proven endpoint once; timeout/invalid/late replies never replay it; unknown mutations are rejected");
    // Invocation is separate from an ACK: even a native exception, missing
    // reply or nil reply leaves the mutation ambiguous and cannot permit replay.
    for(unsigned kind=0;kind<2;kind++)for(unsigned behavior=0;behavior<4;behavior++) {
        t.commandBehavior=behavior;t.playlistBehavior=behavior;
        unsigned previous=kind?t.playlistCount:t.commandCount;__block unsigned completions=0;
        void (^result)(NSData *,NSString *,SAPCommandInvocationDisposition)=^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
            assert(NSThread.isMainThread && disposition==SAPCommandInvoked);
            assert(behavior==0?(data!=nil && !error):(!data && error.length));completions++;
        };
        if(kind)SAPSetPlaylistOfflineOnceWithDisposition(@"spotify:playlist:1234567890123456789012",YES,result);
        else SAPCallOfflineCommandOnceWithDisposition(@"SetOfflinePlaybackAllowed",SAPProtoInteger(1,1),result);
        waitFor(^BOOL{return completions==1;});
        assert((kind?t.playlistCount:t.commandCount)==previous+1);
        assert(cosmos.commandCount==0 && cosmos.playlistCount==0 && bad.commandCount==0 && bad.playlistCount==0);
        if(behavior==1) {
            if(kind)t.playlistLateCallback(NSData.data);else t.commandLateCallback(SAPProtoInteger(1,1));
            until=[NSDate dateWithTimeIntervalSinceNow:.08];
            while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
            assert(completions==1 && (kind?t.playlistCount:t.commandCount)==previous+1);
        }
    }
    t.commandBehavior=0;t.playlistBehavior=0;
    __block unsigned validationReplies=0;unsigned validationCommands=t.commandCount,validationPlaylists=t.playlistCount;
    void (^invalidCommand)(NSData *,NSString *,SAPCommandInvocationDisposition)=^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        assert(NSThread.isMainThread && !data && error.length && disposition==SAPCommandNotInvoked);validationReplies++;
    };
    SAPCallOfflineCommandOnceWithDisposition(@"UnknownMutation",NSData.data,invalidCommand);
    SAPSetPlaylistOfflineOnceWithDisposition(trackURI,YES,invalidCommand);
    waitFor(^BOOL{return validationReplies==2;});
    assert(t.commandCount==validationCommands && t.playlistCount==validationPlaylists);
    // A previously proven object's changed signature fails before objc_msgSend.
    SEL singleSelector=NSSelectorFromString(@"callSingle:method:payload:onResponse:");
    Class originalSingleClass=object_getClass(t);
    Class incompatibleSingle=objc_allocateClassPair(originalSingleClass,"SAPIncompatibleSingleBridgeFixture",0);
    assert(incompatibleSingle && class_addMethod(incompatibleSingle,singleSelector,
        method_getImplementation(class_getInstanceMethod(originalSingleClass,singleSelector)),"v@:@@@@"));
    objc_registerClassPair(incompatibleSingle);object_setClass(t,incompatibleSingle);
    SAPCallOfflineCommandOnceWithDisposition(@"SetOfflinePlaybackAllowed",SAPProtoInteger(1,1),invalidCommand);
    SAPSetPlaylistOfflineOnceWithDisposition(@"spotify:playlist:1234567890123456789012",YES,invalidCommand);
    waitFor(^BOOL{return validationReplies==4;});
    assert(t.commandCount==validationCommands && t.playlistCount==validationPlaylists);
    object_setClass(t,originalSingleClass);
    puts("PASS: mutation disposition separates invalid/signature-rejected requests from success, timeout, nil reply and native exception; each invocation occurs once and late replies stay inert");
    for(unsigned behavior=0;behavior<3;behavior++) {
        t.collectionBehavior=behavior;unsigned previous=t.collectionCount;__block unsigned completions=0;
        SAPAddAlbumToLibraryOnce(@"spotify:album:1234567890123456789012",^(NSData *d,NSString *e){
            assert(behavior==0?(d.length==5 && !e):(!d && e.length));completions++;
        });
        waitFor(^BOOL{return completions==1;});assert(t.collectionCount==previous+1 && cosmos.collectionCount==0 && bad.collectionCount==0);
        if(behavior==1) {
            t.collectionLateCallback(NSData.data);NSDate *until=[NSDate dateWithTimeIntervalSinceNow:.08];
            while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
            assert(completions==1 && t.collectionCount==previous+1);
        }
    }
    unsigned previousCollections=t.collectionCount;answered=NO;
    SAPAddAlbumToLibraryOnce(trackURI,^(NSData *d,NSString *e){assert(!d && e.length);answered=YES;});waitFor(^BOOL{return answered;});assert(t.collectionCount==previousCollections);
    puts("PASS: exact native Collection.Add album payload, one proven endpoint once; timeout/invalid/late replies never replay the mutation; non-album identities rejected");
    unsigned previousAlbumRemoves=t.removes;answered=NO;
    SAPCallOfflineCommandOnce(@"RemoveDownload",SAPProtoBytes(2,[@"spotify:album:1234567890123456789012" dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *d,NSString *e){assert(d&&!e);answered=YES;});
    waitFor(^BOOL{return answered;});assert(t.removes==previousAlbumRemoves+1);
    puts("PASS: exact native album RemoveDownload uses one verified endpoint once");
    // A discovered object with an incompatible stream signature cannot be
    // invoked, even if a prior single reply established transport evidence.
    SEL streamSelector=NSSelectorFromString(@"callStream:method:payload:onResponse:");
    Class bridgeClass=SPTEsperantoTransportBridgeImpl.class,cosmosClass=SPTEsperantoCosmosTransport.class;
    Method bridgeStream=class_getInstanceMethod(bridgeClass,streamSelector),cosmosStream=class_getInstanceMethod(cosmosClass,streamSelector);
    IMP bridgeImplementation=method_getImplementation(bridgeStream),cosmosImplementation=method_getImplementation(cosmosStream);
    Class incompatibleBridge=objc_allocateClassPair(bridgeClass,"SAPIncompatibleStreamBridgeFixture",0),incompatibleCosmos=objc_allocateClassPair(cosmosClass,"SAPIncompatibleStreamCosmosFixture",0);
    assert(incompatibleBridge && incompatibleCosmos);assert(class_addMethod(incompatibleBridge,streamSelector,bridgeImplementation,"v@:@@@@"));assert(class_addMethod(incompatibleCosmos,streamSelector,cosmosImplementation,"v@:@@@@"));objc_registerClassPair(incompatibleBridge);objc_registerClassPair(incompatibleCosmos);
    object_setClass(t,incompatibleBridge);object_setClass(bad,incompatibleBridge);object_setClass(quiet,incompatibleBridge);object_setClass(cosmos,incompatibleCosmos);
    __block unsigned signatureErrors=0;unsigned signatureStreams=t.contextStreamCount+cosmos.contextStreamCount+bad.contextStreamCount+quiet.contextStreamCount;
    dispatch_block_t cancelInvalidSignature=SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"SubscribeContexts",NSData.data,
        ^(NSData *data,NSString *error){assert(!data && [error isEqual:@"No Spotify stream candidate passed read-only verification."]);signatureErrors++;});
    waitFor(^BOOL{return signatureErrors==1;});
    until=[NSDate dateWithTimeIntervalSinceNow:.2];while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(signatureErrors==1 && t.contextStreamCount+cosmos.contextStreamCount+bad.contextStreamCount+quiet.contextStreamCount==signatureStreams);
    cancelInvalidSignature();cancelInvalidSignature=nil;
    object_setClass(t,bridgeClass);object_setClass(bad,bridgeClass);object_setClass(quiet,bridgeClass);object_setClass(cosmos,cosmosClass);
    puts("PASS: incompatible stream signatures are never called, return one exact verification error, and schedule no infinite retry");
    puts("PASS: native preparation failure/cancellation; native transport/descriptor routing; exact one-track wire request; journal observation of every Offline call; actual rejection codes vs no response; independent item-state completion; transient/incorrect/nil responses; cached track; cancellation; stale callback; no idle polling");
} }
