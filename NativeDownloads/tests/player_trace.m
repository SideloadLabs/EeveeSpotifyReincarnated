#include "Diagnostics.h"
#import <Foundation/Foundation.h>
#import "PlayerTrace.h"
#import "WireProto.h"
#import "DiagnosticTrace.h"
#include <assert.h>
static NSUInteger getterCalls;
static NSThread *observerThread;
static BOOL wrongGetterThread;
@interface TraceTrack:NSObject
@property(nonatomic,strong) NSURL *URI;
@end
@implementation TraceTrack @end
@interface TraceState:NSObject
@property(nonatomic,strong) TraceTrack *track;
@property(nonatomic) BOOL paused;
- (BOOL)isPlaying;
- (BOOL)isPaused;
@end
@implementation TraceState
- (BOOL)isPlaying {getterCalls++;wrongGetterThread |= NSThread.currentThread != observerThread;return !self.paused;}
- (BOOL)isPaused {getterCalls++;wrongGetterThread |= NSThread.currentThread != observerThread;return self.paused;}
@end
static NSString *service=@"spotify.player.esperanto.proto.ContextPlayer";
static NSData *prepare(void) {
    NSData *uri=[@"spotify:track:1iNKgHv2k6cB09aB5ozR55" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *context=[SAPProtoBytes(3,uri) mutableCopy];
    [context appendData:SAPProtoBytes(1,SAPProtoBytes(1,SAPProtoBytes(1,uri)))];
    [context appendData:SAPProtoBytes(4,[@"https://SECRET-CONTEXT" dataUsingEncoding:NSUTF8StringEncoding])];
    NSMutableData *options=[SAPProtoInteger(5,1) mutableCopy];
    [options appendData:SAPProtoInteger(9,1)];
    [options appendData:SAPProtoBytes(11,[@"SECRET-SESSION" dataUsingEncoding:NSUTF8StringEncoding])];
    [options appendData:SAPProtoBytes(12,[@"SECRET-LICENSE" dataUsingEncoding:NSUTF8StringEncoding])];
    NSMutableData *request=[SAPProtoBytes(1,context) mutableCopy];
    [request appendData:SAPProtoBytes(2,options)];return request;
}
int main(void){@autoreleasepool{
    SAPDiagnosticsSetEnabled(true);

    observerThread=NSThread.currentThread;
    SAPObservePlayerRequest(service,@"PreparePlay",prepare());SAPPlayerTraceDrainForTesting();
    assert([SAPPlayerTraceReport()[@"event_count"] intValue]==0);
    __block NSUInteger emitted=0;
    SAPPlayerTraceSetSink(^(NSDictionary *event){emitted++;});
    SAPPlayerTraceSetActive(YES);
    SAPTraceID operation=SAPTraceBegin(@"playback_test",@"fixture",@{});
    SAPTraceWithOperation(operation,^{SAPObservePlayerRequest(service,@"PreparePlay",prepare());});SAPPlayerTraceDrainForTesting();
    NSDictionary *e=[SAPPlayerTraceReport()[@"events"] lastObject];
    assert([e[@"trace_operation_id"]unsignedLongLongValue]==operation);
    assert([e[@"context_pages"] intValue]==1 && [e[@"context_explicit_tracks"] intValue]==1);
    assert([e[@"initially_paused_effective"] boolValue] && [e[@"prefetch_level_effective"] intValue]==1);
    assert([e[@"license_present"] boolValue] && [e[@"license_bytes"] intValue]==14);
    assert([e[@"session_fingerprint"] length]==16);
    NSString *json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:SAPPlayerTraceReport() options:0 error:NULL] encoding:NSUTF8StringEncoding];
    assert(![json containsString:@"SECRET"] && ![json containsString:@"https://"]);
    TraceTrack *track=[TraceTrack new];track.URI=[NSURL URLWithString:@"spotify:track:1iNKgHv2k6cB09aB5ozR55"];
    TraceState *state=[TraceState new];state.track=track;state.paused=YES;
    SAPObservePlayerState(state);SAPPlayerTraceDrainForTesting();
    e=[SAPPlayerTraceReport()[@"events"] lastObject];assert([e[@"track_uri"] isEqual:track.URI.absoluteString]);
    NSUInteger prior=emitted;SAPObservePlayerState(state);SAPPlayerTraceDrainForTesting();assert(emitted==prior);
    state.paused=NO;SAPObservePlayerState(state);SAPPlayerTraceDrainForTesting();assert(emitted==prior+1);
    SAPObservePlayerRequest(@"other",@"PreparePlay",prepare());SAPPlayerTraceDrainForTesting();assert(emitted==prior+1);
    // Hold the trace queue while the subscription callback observes a mutable
    // state. Mutating it before queue drain must not rewrite that observation.
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    SAPPlayerTraceSetSink(^(NSDictionary *event){
        emitted++;
        if([event[@"method"] isEqual:@"DeleteSession"]){
            dispatch_semaphore_signal(entered);
            assert(dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
        }
    });
    SAPObservePlayerRequest(service,@"DeleteSession",NSData.data);
    assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    state.paused=YES;NSUInteger callsBefore=getterCalls;
    NSString *observedURI=track.URI.absoluteString;
    SAPObservePlayerState(state);
    assert(getterCalls==callsBefore+2 && !wrongGetterThread);
    state.paused=NO;track.URI=[NSURL URLWithString:@"spotify:track:0aNdtLrUvMMSKZ2EqEFYJK"];
    dispatch_semaphore_signal(release);SAPPlayerTraceDrainForTesting();
    e=[SAPPlayerTraceReport()[@"events"] lastObject];
    assert([e[@"paused"] boolValue] && ![e[@"playing"] boolValue]);
    assert([e[@"track_uri"] isEqual:observedURI] && getterCalls==callsBefore+2);
    SAPPlayerTraceSetSink(^(NSDictionary *event){emitted++;});
    for(unsigned i=0;i<150;i++){SAPObservePlayerRequest(service,@"PreparePlay",prepare());SAPPlayerTraceDrainForTesting();}
    assert([SAPPlayerTraceReport()[@"events"] count]==120);
    SAPPlayerTraceSetActive(NO);
    assert([SAPPlayerTraceReport()[@"active"]boolValue]);
    SAPObservePlayerRequest(service,@"DeleteSession",NSData.data);SAPPlayerTraceDrainForTesting();
    assert(emitted>0);
    SAPDiagnosticsSetEnabled(false);SAPPlayerTraceSetActive(NO);prior=emitted;NSUInteger oldCalls=getterCalls;
    SAPObservePlayerState(state);SAPObservePlayerRequest(service,@"PreparePlay",prepare());SAPPlayerTraceDrainForTesting();
    assert(emitted==prior && getterCalls==oldCalls && ![SAPPlayerTraceReport()[@"active"] boolValue]);
    assert(!wrongGetterThread);
    SAPPlayerTraceReset();
    assert([SAPPlayerTraceReport()[@"events"] count]==0 && [SAPPlayerTraceReport()[@"event_count"] intValue]==0);
    assert(![SAPPlayerTraceReport()[@"active"] boolValue]);
    SAPDiagnosticsSetEnabled(true);
    // Reset from the sink while older work is queued. Those observations must
    // be discarded, and an explicit new activation must start at sequence1.
    SAPPlayerTraceSetActive(YES);
    SAPPlayerTraceSetSink(^(NSDictionary *event){
        emitted++;
        if([event[@"method"] isEqual:@"DeleteSession"]){
            dispatch_semaphore_signal(entered);
            assert(dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
            SAPPlayerTraceReset();
        }
    });
    SAPObservePlayerRequest(service,@"DeleteSession",NSData.data);
    assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    SAPObservePlayerState(state);SAPObservePlayerRequest(service,@"PreparePlay",prepare());
    dispatch_semaphore_signal(release);SAPPlayerTraceDrainForTesting();
    NSDictionary *reset=SAPPlayerTraceReport();
    assert(![reset[@"active"] boolValue] && [reset[@"events"] count]==0);
    assert([reset[@"event_count"] intValue]==0 && [reset[@"pending"] intValue]==0);
    SAPPlayerTraceSetSink(^(NSDictionary *event){emitted++;});
    SAPPlayerTraceSetActive(YES);
    SAPObservePlayerState(state);SAPPlayerTraceDrainForTesting();
    e=[SAPPlayerTraceReport()[@"events"] lastObject];
    assert([e[@"sequence"] intValue]==1 && ![e[@"paused"] boolValue]);
    SAPPlayerTraceReset();
    puts("PASS: bounded passive player trace, callback-thread snapshots, queued mutation isolation, reset generations, disabled fast path, secret redaction");
}return 0;}
