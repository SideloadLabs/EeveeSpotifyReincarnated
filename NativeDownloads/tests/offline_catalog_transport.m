#import <Foundation/Foundation.h>
#import "OfflineLibraryCatalog.h"
#import "SpotifyTransport.h"
#import "DiagnosticTrace.h"
#import "WireProto.h"
#import "TrackJournal.h"
#include <assert.h>

// Only the unavailable native boundary is replaced. The catalog, candidate
// registry, read-only service lifetimes and cancellation execute production code.
void SAPInstallTrackDownloader(void) { static dispatch_once_t once;dispatch_once(&once,^{SAPInitializeTransportRuntime();SAPInstallSpotifyTransportHooks();}); }
bool SAPDiagnosticsEnabled(void) { return false; }
bool SAPTraceIsActive(void) { return false; }
SAPTraceID SAPTraceCurrentOperation(void) { return 0; }
SAPTraceID SAPTraceBegin(NSString *kind,NSString *source,NSDictionary *facts) { return 0; }
void SAPTraceWithOperation(SAPTraceID op,dispatch_block_t work) { work(); }
void SAPTraceEvent(const char *category,const char *stage,SAPTraceID op,NSDictionary *facts) {}
void SAPJournalNoteAction(NSString *name,NSDictionary *facts) {}

void SAPTraceRegisterHook(Class cls,SEL sel,IMP installed,IMP original) {}
void SAPTraceHookCalled(Class cls,SEL sel) {}
SAPTraceRPC *SAPTraceRPCBegin(NSString *s,NSString *m,NSData *d,NSString *origin,id ep,BOOL stream) { return nil; }
void SAPTraceRPCReturned(SAPTraceRPC *call,id lifetime) {}
void SAPTraceRPCReply(SAPTraceRPC *call,id response) {}
void SAPTraceRPCException(SAPTraceRPC *call,NSException *error) {}
void SAPTraceRPCStreamEnd(SAPTraceRPC *call,NSString *reason) {}
@implementation SAPTraceRPC
- (SAPTraceID)identifier { return 0; }
@end
BOOL SAPJournalOnOwnQueue(void) { return NO; }
void SAPJournalSetCaller(SAPJournalCaller caller) {}
void SAPJournalObserveCall(NSString *m,NSData *q,NSData *a,NSString *origin) {}
void SAPJournalNoteCallIssue(NSString *m,NSString *uri,NSString *channel,NSString *issue) {}
void SAPObservePlayerRequest(id service,id method,id payload) {}
void SAPObservePlayerState(id state) {}
static unsigned active,maximum,calls;
@interface CatalogLifetime : NSObject
@property(nonatomic) BOOL acquired,cancelled,tracked;
@end
@implementation CatalogLifetime
- (void)acquire { assert(!self.acquired);self.acquired=YES; }
- (void)cancel { assert(self.acquired);if(!self.cancelled){self.cancelled=YES;if(self.tracked){assert(active);active--;}} }
@end

@interface CatalogEndpoint : NSObject
@property(nonatomic) unsigned requests;
@property(nonatomic) BOOL replies,invalid;
@property(nonatomic) double delay;
@property(nonatomic,strong) CatalogLifetime *lifetime;
@property(nonatomic,copy) void (^late)(NSData *);
@property(nonatomic) BOOL streamReturned;
@property(nonatomic) unsigned emissions;
@end
@implementation CatalogEndpoint
- (id)callSingle:(NSString *)service method:(NSString *)method payload:(NSData *)payload onResponse:(void (^)(NSData *))reply {
    if(![method isEqual:@"GetContexts"]) {
        CatalogLifetime *proof=CatalogLifetime.new;reply(self.invalid?nil:NSData.data);return proof;
    }
    assert([service isEqual:SAPOfflineService]);
    assert([payload isEqual:SAPProtoBytes(1,SAPProtoInteger(1,1))]);
    self.requests++;calls++;active++;maximum=MAX(maximum,active);
    self.lifetime=CatalogLifetime.new;self.lifetime.tracked=YES;self.late=reply;
    if(self.replies || self.invalid) {
        BOOL invalid=self.invalid;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self.delay*NSEC_PER_SEC)),SAPTransportWorker(),^{reply(invalid?nil:NSData.data);});
    }
    return self.lifetime;
}
- (id)callStream:(NSString *)service method:(NSString *)method payload:(NSData *)payload onResponse:(BOOL (^)(NSData *))reply {
    assert([service isEqual:SAPOfflineService] && [method isEqual:@"SubscribeContexts"]);
    for(unsigned i=0;i<MAX(1u,self.emissions);i++)self.streamReturned=reply(NSData.data);
    return CatalogLifetime.new;
}
@end
@interface SPTEsperantoTransportBridgeImpl : CatalogEndpoint @end
@implementation SPTEsperantoTransportBridgeImpl @end
@interface SPTEsperantoCosmosTransport : CatalogEndpoint @end
@implementation SPTEsperantoCosmosTransport @end

static void pump(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
}
static void waitFor(BOOL (^condition)(void)) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!condition() && end.timeIntervalSinceNow>0)pump(.001);
    assert(condition());
}
static dispatch_block_t fetch(unsigned *done,BOOL expectError) {
    return SAPFetchOfflineLibrary(nil,^(NSArray *rows,NSString *error){
        assert(NSThread.isMainThread);
        assert(expectError?(!rows && error.length):(rows && !rows.count && !error));
        (*done)++;
    });
}
static void seed(CatalogEndpoint *bridge,CatalogEndpoint *cosmos) {
    SAPInitializeTransportRuntime();
    SAPRememberTransport(bridge,YES,YES);SAPRememberTransport(cosmos,NO,NO);
}
static void nativeProof(CatalogEndpoint *endpoint,NSString *service,NSString *method) {
    id lifetime=[endpoint callSingle:service method:method payload:NSData.data onResponse:^(NSData *data){}];
    SAPAcquireTransportHandle(lifetime);SAPCancelTransportHandle(lifetime);
}
int main(int argc,const char **argv) { @autoreleasepool {
    assert(argc==2);NSString *scenario=@(argv[1]);
    SPTEsperantoTransportBridgeImpl *bridge=SPTEsperantoTransportBridgeImpl.new;
    SPTEsperantoCosmosTransport *cosmos=SPTEsperantoCosmosTransport.new;
    SAPInstallTrackDownloader();seed(bridge,cosmos);__block unsigned done=0;
    if([scenario isEqual:@"service_route"] || [scenario isEqual:@"stream_route"] || [scenario isEqual:@"slow_route"] || [scenario isEqual:@"cancel_reopen"] || [scenario isEqual:@"late_reply"]) {
        if([scenario isEqual:@"stream_route"]) {
            id lifetime=[cosmos callStream:SAPOfflineService method:@"SubscribeContexts" payload:NSData.data onResponse:^BOOL(NSData *data){return NO;}];
            SAPAcquireTransportHandle(lifetime);SAPCancelTransportHandle(lifetime);
            assert(!cosmos.streamReturned); // Preserve the stock stream's callback contract.
        } else nativeProof(cosmos,SAPOfflineService,@"GetItems");
        SAPRememberTransport(bridge,YES,YES); // Global proof for another RPC must not override Offline evidence.
        cosmos.replies=YES;if([scenario isEqual:@"slow_route"])cosmos.delay=.025;
        dispatch_block_t cancel=fetch(&done,NO);
        if([scenario isEqual:@"cancel_reopen"]) {
            cosmos.delay=.025;
            waitFor(^BOOL{return calls>0;});cancel();cancel();waitFor(^BOOL{return active==0;});
            void (^late)(NSData *)=cosmos.late;
            fetch(&done,NO);waitFor(^BOOL{return done==1;});
            if(late)late(NSData.data);pump(.1);
            assert(cosmos.requests==2 && !bridge.requests && done==1);
        } else {
            waitFor(^BOOL{return done==1;});
            assert(!bridge.requests && cosmos.requests==1 && "Offline service evidence must select the correct endpoint on the first call");
            if([scenario isEqual:@"late_reply"]){cosmos.late(NSData.data);cosmos.late(NSData.data);pump(.1);assert(done==1);}
        }
        assert(!active && maximum==1);
    } else if([scenario isEqual:@"cancel_late_route"]) {
        nativeProof(cosmos,SAPOfflineService,@"GetItems");
        dispatch_block_t cancel=fetch(&done,NO);waitFor(^BOOL{return cosmos.requests==1;});
        cancel();waitFor(^BOOL{return active==0;});
        nativeProof(bridge,SAPOfflineService,@"GetItems");
        cosmos.late(NSData.data);pump(.02);assert(!done);
        bridge.replies=YES;fetch(&done,NO);waitFor(^BOOL{return done==1;});
        assert(bridge.requests==1 && cosmos.requests==1 && !active);
    } else if([scenario isEqual:@"method_route"]) {
        // The first read learns GetContexts specifically (Cosmos precedes the bridge for Offline reads).
        // Later GetItems success on a different endpoint must not displace that method route.
        cosmos.replies=YES;fetch(&done,NO);waitFor(^BOOL{return done==1;});
        assert(!bridge.requests && cosmos.requests==1);
        nativeProof(bridge,SAPOfflineService,@"GetItems");SAPRememberTransport(bridge,YES,YES);
        fetch(&done,NO);waitFor(^BOOL{return done==2;});
        assert(!bridge.requests && cosmos.requests==2 && !active);
    } else if([scenario isEqual:@"service_isolation"] || [scenario isEqual:@"invalid_proof"]) {
        bridge.replies=YES;
        if([scenario isEqual:@"invalid_proof"]){cosmos.invalid=YES;nativeProof(cosmos,SAPOfflineService,@"GetItems");cosmos.invalid=NO;}
        else nativeProof(cosmos,@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity");
        SAPRememberTransport(bridge,YES,YES);fetch(&done,NO);waitFor(^BOOL{return done==1;});
        // Evidence for another service (or an invalid reply) selects nothing: the silent Cosmos is tried
        // first by the default Offline order and the bridge answers as the fallback.
        assert(bridge.requests==1 && cosmos.requests==1 && !active);
    } else if([scenario isEqual:@"stream_once"]) {
        // A subscription replies thousands of times; the registry sees it once.
        SAPReadRouteStoreResetForTesting(nil);cosmos.emissions=1000;
        id lifetime=[cosmos callStream:SAPOfflineService method:@"SubscribeContexts" payload:NSData.data onResponse:^BOOL(NSData *data){return NO;}];
        SAPAcquireTransportHandle(lifetime);SAPCancelTransportHandle(lifetime);
        assert(SAPReadRouteRememberCountForTesting()==1);
        nativeProof(cosmos,SAPOfflineService,@"GetItems");nativeProof(cosmos,SAPOfflineService,@"GetItems");
        assert(SAPReadRouteRememberCountForTesting()==3 && "every separate call still proves its route");
    } else if([scenario isEqual:@"persisted_route"]) {
        // The bridge answered in a previous launch; the first read of the new launch
        // must trust that proof instead of the default bridge-last order, which
        // would wait on the silent Cosmos endpoint first.
        NSString *dir=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        SAPReadRouteStoreResetForTesting(dir);bridge.replies=YES;nativeProof(bridge,SAPOfflineService,@"GetItems");
        SAPReadRouteStoreFlushForTesting();
        assert([NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"read-routes.plist"]]);
        SAPReadRouteStoreResetForTesting(dir); // new launch: no weak routes, same endpoint classes
        NSArray *order=SAPTransportCandidatesForRead(SAPOfflineService,@"GetContexts");
        assert(order.count==2 && order[0]==bridge && order[1]==cosmos);
        fetch(&done,NO);waitFor(^BOOL{return done==1;});
        assert(bridge.requests==1 && !cosmos.requests && !active);
        SAPReadRouteStoreResetForTesting(nil);
    } else if([scenario isEqual:@"persisted_invalid"]) {
        // Stale class names, damaged files and oversized files only lose the hint.
        NSString *dir=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *file=[dir stringByAppendingPathComponent:@"read-routes.plist"];
        NSMutableArray *entries=NSMutableArray.array;
        [entries addObject:@[[NSString stringWithFormat:@"%@\n%@",SAPOfflineService,@""],@"SPTEsperantoRemovedTransport"]];
        [entries addObject:@"junk"];[entries addObject:@[@1,@2]];[entries addObject:@[[@"" stringByPaddingToLength:1000 withString:@"x" startingAtIndex:0],@"A"]];
        for(unsigned i=0;i<500;i++)[entries addObject:@[[NSString stringWithFormat:@"service%u\nmethod",i],@"SPTEsperantoCosmosTransport"]];
        [@{@"version":@1,@"routes":entries} writeToFile:file atomically:YES];
        SAPReadRouteStoreResetForTesting(dir);cosmos.replies=YES;
        NSArray *order=SAPTransportCandidatesForRead(SAPOfflineService,@"GetContexts");
        assert(order.count==2 && order[0]==cosmos && order[1]==bridge && "unknown persisted class falls back to the ordinary order");
        fetch(&done,NO);waitFor(^BOOL{return done==1;});assert(cosmos.requests==1 && !bridge.requests);
        [@"garbage" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        SAPReadRouteStoreResetForTesting(dir);fetch(&done,NO);waitFor(^BOOL{return done==2;});assert(cosmos.requests==2);
        SAPReadRouteStoreResetForTesting(nil);
    } else if([scenario isEqual:@"bridge_last"]) {
        // No learned route: Offline reads put the bridge after every other endpoint; other services keep the old order.
        bridge.replies=NO;cosmos.replies=YES;
        NSArray *offline=SAPTransportCandidatesForRead(SAPOfflineService,@"GetContexts");
        NSArray *other=SAPTransportCandidatesForRead(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity");
        assert(offline.count==2 && offline[0]==cosmos && offline[1]==bridge);
        assert(other.count==2 && other[0]==bridge && other[1]==cosmos);
        fetch(&done,NO);waitFor(^BOOL{return done==1;});
        assert(!bridge.requests && cosmos.requests==1 && !active);
    } else if([scenario isEqual:@"cancel_before_send"]) {
        dispatch_block_t cancel=fetch(&done,NO);cancel();cancel();pump(.12);
        assert(!done && !calls && !active);
    } else if([scenario isEqual:@"candidate_churn"]) {
        nativeProof(cosmos,SAPOfflineService,@"GetItems");
        // Unrelated live endpoints evict Cosmos from the generic discovery
        // ring. Its still-live service proof must remain independently usable.
        NSMutableArray *unrelated=NSMutableArray.array;
        for(unsigned i=0;i<8;i++) {
            CatalogEndpoint *other=CatalogEndpoint.new;[unrelated addObject:other];
            SAPRememberTransport(other,NO,NO);
        }
        SAPRememberTransport(bridge,YES,YES);
        assert([SAPTransportCandidates() indexOfObjectIdenticalTo:cosmos]==NSNotFound);
        cosmos.replies=YES;fetch(&done,NO);waitFor(^BOOL{return done==1;});
        assert(!bridge.requests && cosmos.requests==1 && calls==1 && !active);
    } else if([scenario isEqual:@"weak_route"]) {
        __weak CatalogEndpoint *weak;
        @autoreleasepool {
            CatalogEndpoint *temporary=SPTEsperantoCosmosTransport.new;weak=temporary;
            nativeProof(temporary,SAPOfflineService,@"GetItems");
        }
        assert(!weak);bridge.replies=YES;fetch(&done,NO);waitFor(^BOOL{return done==1;});
        assert(bridge.requests==1 && cosmos.requests==1 && !active);
    } else {
        assert([scenario isEqual:@"exhaustion"]);
        CatalogEndpoint *third=CatalogEndpoint.new,*fourth=CatalogEndpoint.new;
        SAPRememberTransport(third,NO,NO);SAPRememberTransport(fourth,NO,NO);
        fetch(&done,YES);waitFor(^BOOL{return done==1;});pump(.12);
        assert(calls==4 && maximum==1 && !active);
        assert(bridge.requests==1 && cosmos.requests==1 && third.requests==1 && fourth.requests==1);
    }
    puts([[NSString stringWithFormat:@"PASS: offline catalog transport %@",scenario]UTF8String]);
    return 0;
} }
