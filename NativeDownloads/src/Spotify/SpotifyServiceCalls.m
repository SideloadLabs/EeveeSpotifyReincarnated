#import "SpotifyTransport.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#include <stdatomic.h>

#ifdef SAP_TESTING
static const double serviceTimeoutSeconds=.04,streamFirstResponseTimeoutSeconds=.12;
#else
static const double serviceTimeoutSeconds=8,streamFirstResponseTimeoutSeconds=8;
#endif

@interface SAPReadOnlyCall : NSObject { atomic_bool _cancelled; }
@property(nonatomic,copy) NSString *serviceName, *method;
@property(nonatomic,strong) NSData *payload;
@property(nonatomic,strong) NSArray *endpoints;
@property(nonatomic,strong) id lifetime;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,copy) void (^completion)(NSData *, NSString *);
@property(nonatomic,copy) void (^commandCompletion)(NSData *, NSString *, SAPCommandInvocationDisposition);
@property(nonatomic) NSUInteger endpointIndex, attempt;
@property(nonatomic) BOOL finished, invoked;
@property(nonatomic) SAPTraceID traceOperation;
- (BOOL)markCancelled;
- (BOOL)isCancelled;
@end
@implementation SAPReadOnlyCall
- (instancetype)init { if((self=[super init])) atomic_init(&_cancelled,false); return self; }
- (BOOL)markCancelled { return !atomic_exchange(&_cancelled,true); }
- (BOOL)isCancelled { return atomic_load(&_cancelled); }
@end
static NSMutableSet<SAPReadOnlyCall *> *readOnlyCalls;

@interface SAPReadOnlyStream : NSObject { atomic_bool _cancelled; }
@property(nonatomic,copy) NSString *serviceName, *method;
@property(nonatomic,strong) NSData *payload;
@property(nonatomic,strong) id endpoint, lifetime;
@property(nonatomic,strong) NSArray *endpoints, *verifiedEndpoints;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,copy) void (^onResponse)(NSData *, NSString *);
@property(nonatomic) BOOL finished, receivedFirstResponse;
@property(nonatomic) NSUInteger endpointIndex, attempt, candidateCount;
- (BOOL)markCancelled;
- (BOOL)isCancelled;
@end
@implementation SAPReadOnlyStream
- (instancetype)init { if((self=[super init])) atomic_init(&_cancelled,false); return self; }
- (BOOL)markCancelled { return !atomic_exchange(&_cancelled,true); }
- (BOOL)isCancelled { return atomic_load(&_cancelled); }
@end
static NSMutableSet<SAPReadOnlyStream *> *readOnlyStreams;

static BOOL supportedReadOnlyStream(NSString *serviceName, NSString *method) {
    return [serviceName isEqual:SAPOfflineService] &&
        ([method isEqual:@"SubscribeContexts"] || [method isEqual:@"SubscribeContextsProgress"] || [method isEqual:@"SubscribeItems"]);
}

static void noteStream(SAPReadOnlyStream *stream,NSString *stage,NSString *reason) {
    if(!SAPDiagnosticsEnabled())return;
    SEL selector=NSSelectorFromString(@"callStream:method:payload:onResponse:");Method method;
    BOOL valid=stream.endpoint && SAPTransportSignature(object_getClass(stream.endpoint),selector,6,'@',&method);
    SAP_JOURNAL_ACTION(@"artist_stream_transport",@{@"stage":stage,@"reason":reason?:@"",@"method":stream.method?:@"",
        @"endpoint_present":@(stream.endpoint!=nil),@"endpoint_class":stream.endpoint?NSStringFromClass(object_getClass(stream.endpoint)):@"",
        @"endpoint_identity":stream.endpoint?[NSString stringWithFormat:@"%p",(__bridge void *)stream.endpoint]:@"",
        @"stream_signature_valid":@(valid),@"candidates":@(stream.candidateCount),@"candidate_attempt":@(stream.endpointIndex)});
}
static void finishReadOnlyStream(SAPReadOnlyStream *stream, NSString *error) {
    if (stream.finished) return;
    noteStream(stream,@"cancel",error?:@"caller_cancelled_or_replaced");
    stream.finished = YES;
    stream.attempt++;
    if (stream.deadline) { dispatch_source_cancel(stream.deadline); stream.deadline = nil; }
    SAPCancelTransportHandle(stream.lifetime); stream.lifetime = nil;
    stream.endpoint = nil; stream.endpoints=nil;stream.verifiedEndpoints=nil;stream.payload = nil;
    void (^callback)(NSData *, NSString *) = stream.onResponse;
    if (error && callback && !stream.isCancelled) dispatch_async(dispatch_get_main_queue(), ^{
        if (!stream.isCancelled) callback(nil, error);
    });
    stream.onResponse = nil;
    [readOnlyStreams removeObject:stream];
}

static void deliverReadOnlyStreamResponse(SAPReadOnlyStream *stream, NSData *response) {
    if (stream.finished || stream.isCancelled) {
        if (stream.isCancelled) finishReadOnlyStream(stream, nil);
        return;
    }
    if (![response isKindOfClass:NSData.class] || response.length > 8 * 1024 * 1024) {
        finishReadOnlyStream(stream, @"Invalid or oversized Spotify stream response");
        return;
    }
    stream.receivedFirstResponse = YES;
    SAPRememberReadOnlyTransport(stream.endpoint,stream.serviceName,stream.method);
    // The active stream owns its endpoint. Candidate snapshots are retained
    // only during this finite handoff, never by a global strong cache.
    stream.endpoints=nil;stream.verifiedEndpoints=nil;
    if (stream.deadline) { dispatch_source_cancel(stream.deadline); stream.deadline = nil; }
    void (^callback)(NSData *, NSString *) = stream.onResponse;
    if (callback) dispatch_async(dispatch_get_main_queue(), ^{
        if (!stream.isCancelled) callback(response, nil);
    });
}

static void tryReadOnlyStream(SAPReadOnlyStream *stream,NSString *reason);
static void openReadOnlyStream(SAPReadOnlyStream *stream,NSUInteger attempt) {
    if(stream.finished || stream.isCancelled){finishReadOnlyStream(stream,nil);return;}
    if(stream.deadline){dispatch_source_cancel(stream.deadline);stream.deadline=nil;}
    SAPCancelTransportHandle(stream.lifetime);stream.lifetime=nil;
    SEL selector=NSSelectorFromString(@"callStream:method:payload:onResponse:");
    BOOL (^responseBlock)(NSData *)=^BOOL(NSData *response){
        dispatch_async(SAPTransportWorker(),^{if(!stream.finished && stream.attempt==attempt)deliverReadOnlyStreamResponse(stream,response);});
        return !stream.isCancelled;
    };
    noteStream(stream,@"subscribe",nil);
    @try {
        stream.lifetime=((id (*)(id,SEL,id,id,id,id))objc_msgSend)(stream.endpoint,selector,stream.serviceName,stream.method,stream.payload,responseBlock);
        if(!stream.lifetime){tryReadOnlyStream(stream,@"stream_lifetime_missing");return;}
        SAPAcquireTransportHandle(stream.lifetime);
    } @catch(__unused NSException *exception){tryReadOnlyStream(stream,@"stream_exception");return;}
    if(stream.isCancelled){finishReadOnlyStream(stream,nil);return;}
    stream.deadline=SAPScheduleDeadline(SAPTransportWorker(),streamFirstResponseTimeoutSeconds,^{
        if(!stream.finished && stream.attempt==attempt && !stream.receivedFirstResponse)tryReadOnlyStream(stream,@"first_response_timeout");
    });
}
static void tryReadOnlyStream(SAPReadOnlyStream *stream,NSString *reason) {
    if(stream.finished)return;
    if(stream.isCancelled){finishReadOnlyStream(stream,nil);return;}
    noteStream(stream,@"candidate_finished",reason);
    if(stream.deadline){dispatch_source_cancel(stream.deadline);stream.deadline=nil;}
    SAPCancelTransportHandle(stream.lifetime);stream.lifetime=nil;stream.endpoint=nil;
    NSUInteger attempt=++stream.attempt;
    if(stream.receivedFirstResponse || stream.endpointIndex>=stream.endpoints.count){
        finishReadOnlyStream(stream,@"No Spotify stream candidate passed read-only verification.");return;
    }
    stream.endpoint=stream.endpoints[stream.endpointIndex++];
    if([stream.verifiedEndpoints containsObject:stream.endpoint]){openReadOnlyStream(stream,attempt);return;}
    // An observed candidate is not proof of a working route. Probe only an
    // unproven fallback, using the corresponding exact read-only request.
    SEL selector=NSSelectorFromString(@"callSingle:method:payload:onResponse:");Method method;
    if(!SAPTransportSignature(object_getClass(stream.endpoint),selector,6,'@',&method)){tryReadOnlyStream(stream,@"single_signature_mismatch");return;}
    NSString *readMethod=[stream.method isEqual:@"SubscribeItems"]?@"GetItems":[stream.method isEqual:@"SubscribeContexts"]?@"GetContexts":@"GetContextsProgress";
    noteStream(stream,@"verify",nil);
    void (^responseBlock)(NSData *)=^(NSData *response){dispatch_async(SAPTransportWorker(),^{
        if(stream.finished || stream.attempt!=attempt)return;
        if(stream.isCancelled){finishReadOnlyStream(stream,nil);return;}
        NSArray *fields=[response isKindOfClass:NSData.class] && response.length<=8*1024*1024?SAPProtoFields(response):nil;
        if(!fields || ([readMethod isEqual:@"GetContexts"] && SAPProtoNumber(fields,2,0))){tryReadOnlyStream(stream,@"invalid_verification_response");return;}
        SAPRememberTransport(stream.endpoint,NO,YES);openReadOnlyStream(stream,attempt);
    });};
    @try {
        stream.lifetime=((id (*)(id,SEL,id,id,id,id))objc_msgSend)(stream.endpoint,selector,stream.serviceName,readMethod,stream.payload,responseBlock);
        if(!stream.lifetime){tryReadOnlyStream(stream,@"verification_lifetime_missing");return;}
        SAPAcquireTransportHandle(stream.lifetime);
    } @catch(__unused NSException *exception){tryReadOnlyStream(stream,@"verification_exception");return;}
    if(stream.isCancelled){finishReadOnlyStream(stream,nil);return;}
    stream.deadline=SAPScheduleDeadline(SAPTransportWorker(),serviceTimeoutSeconds,^{if(!stream.finished && stream.attempt==attempt)tryReadOnlyStream(stream,@"verification_timeout");});
}

dispatch_block_t SAPSubscribeReadOnlyService(NSString *serviceName, NSString *method, NSData *payload,
                                              void (^onResponse)(NSData *response, NSString *error)) {
    SAPInstallTrackDownloader();
    SAPReadOnlyStream *stream = [SAPReadOnlyStream new];
    stream.onResponse = onResponse;
    if (!supportedReadOnlyStream(serviceName, method) || ![payload isKindOfClass:NSData.class] || payload.length > 8 * 1024 * 1024) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!stream.isCancelled && stream.onResponse) stream.onResponse(nil, @"Unsupported or invalid Spotify stream request");
            stream.onResponse = nil;
        });
        return ^{ [stream markCancelled]; };
    }
    stream.serviceName = serviceName; stream.method = method; stream.payload = payload;
    dispatch_async(SAPTransportWorker(), ^{
        if (stream.isCancelled) { finishReadOnlyStream(stream, nil); return; }
        if (!readOnlyStreams) readOnlyStreams = [NSMutableSet set];
        [readOnlyStreams addObject:stream];
        NSArray *available=SAPTransportCandidates();NSMutableArray *verified=[NSMutableArray array],*usable=[NSMutableArray array];
        id proven,bridge;SAPTransportVerifiedEndpoints(&proven,&bridge);
        if(proven)[verified addObject:proven];
        // Existing stream owners remain alive until replacement selection is
        // queued. They are verified only for this active observation handoff.
        for(SAPReadOnlyStream *old in readOnlyStreams)if(old!=stream && !old.finished && old.receivedFirstResponse && old.endpoint && ![verified containsObject:old.endpoint])[verified addObject:old.endpoint];
        if(bridge && ![verified containsObject:bridge])[verified addObject:bridge];
        NSMutableOrderedSet *ordered=[NSMutableOrderedSet orderedSetWithArray:verified];[ordered addObjectsFromArray:available];
        SEL selector=NSSelectorFromString(@"callStream:method:payload:onResponse:");Method method;
        for(id endpoint in ordered){
            stream.endpoint=endpoint;stream.candidateCount=ordered.count;
            if(!SAPTransportSignature(object_getClass(endpoint),selector,6,'@',&method)){noteStream(stream,@"candidate_rejected",@"stream_signature_mismatch");continue;}
            [usable addObject:endpoint];if(usable.count==2)break;
        }
        if(SAPDiagnosticsEnabled()){
            BOOL provenSignature=proven && SAPTransportSignature(object_getClass(proven),selector,6,'@',&method);
            SAP_JOURNAL_ACTION(@"artist_stream_transport_selection",@{@"method":stream.method,@"proven_endpoint_present":@(proven!=nil),@"proven_endpoint_class":proven?NSStringFromClass(object_getClass(proven)):@"",@"proven_stream_signature_valid":@(provenSignature),@"candidates":@(ordered.count),@"usable_candidates":@(usable.count),@"max_candidate_attempts":@2});
        }
        stream.endpoint=nil;stream.endpoints=usable;stream.verifiedEndpoints=verified;
        tryReadOnlyStream(stream,@"initial");
    });
    return ^{
        if (![stream markCancelled]) return;
        dispatch_async(SAPTransportWorker(), ^{ if (!stream.finished) finishReadOnlyStream(stream, nil); });
    };
}

static void finishReadOnlyCall(SAPReadOnlyCall *call, NSData *response, NSString *error) {
    if (call.finished) return;
    call.finished = YES;
    if (call.deadline) { dispatch_source_cancel(call.deadline); call.deadline = nil; }
    SAPCancelTransportHandle(call.lifetime); call.lifetime = nil;
    void (^completion)(NSData *, NSString *) = call.completion;
    void (^commandCompletion)(NSData *, NSString *, SAPCommandInvocationDisposition) = call.commandCompletion;
    SAPCommandInvocationDisposition disposition=call.invoked?SAPCommandInvoked:SAPCommandNotInvoked;
    call.completion = nil; call.commandCompletion=nil; call.endpoints = nil; call.payload = nil;
    [readOnlyCalls removeObject:call];
    if ((completion || commandCompletion) && !call.isCancelled) dispatch_async(dispatch_get_main_queue(), ^{
        // Cancellation may race with a response already queued for main.
        if(call.isCancelled)return;
        SAPTraceWithOperation(call.traceOperation,^{
            if(completion)completion(response,error);
            if(commandCompletion)commandCompletion(response,error,disposition);
        });
    });
}

static void tryReadOnlyCall(SAPReadOnlyCall *call) {
    if (call.finished) return;
    if (call.isCancelled) { finishReadOnlyCall(call,nil, nil); return; }
    if (call.deadline) { dispatch_source_cancel(call.deadline); call.deadline = nil; }
    SAPCancelTransportHandle(call.lifetime); call.lifetime = nil;
    if (call.endpointIndex >= call.endpoints.count) {
        finishReadOnlyCall(call, nil, @"Spotify did not answer the request");
        return;
    }
    id endpoint = call.endpoints[call.endpointIndex++];
    SEL selector = NSSelectorFromString(@"callSingle:method:payload:onResponse:");
    Method method;
    if (!SAPTransportSignature(object_getClass(endpoint), selector, 6, '@', &method)) {
        tryReadOnlyCall(call);
        return;
    }
    NSUInteger attempt = ++call.attempt;
    SAP_TRACE("service_call","attempt",call.traceOperation,@{@"method":call.method,@"service":call.serviceName,@"attempt":@(attempt),@"transport":NSStringFromClass(object_getClass(endpoint)),@"replay_policy":call.endpoints.count==1?@"single_endpoint":@"read_only_fallback"});
    void (^responseBlock)(NSData *) = ^(NSData *response) {
        dispatch_async(SAPTransportWorker(), ^{
            if (call.finished || call.isCancelled || call.attempt != attempt) {
                if(!call.finished && call.isCancelled)finishReadOnlyCall(call,nil,nil);
                return;
            }
            if (![response isKindOfClass:NSData.class] || response.length > 8 * 1024 * 1024) {
                tryReadOnlyCall(call);
                return;
            }
            SAPRememberTransport(endpoint, NO, YES);
            if(!call.commandCompletion)SAPRememberReadOnlyTransport(endpoint,call.serviceName,call.method);
            finishReadOnlyCall(call, response, nil);
        });
    };
    @try {
        SAPTraceWithOperation(call.traceOperation,^{
            // From this point a failed response cannot prove the command was unsent.
            call.invoked=YES;
            call.lifetime=((id (*)(id,SEL,id,id,id,id))objc_msgSend)(endpoint,selector,call.serviceName,call.method,call.payload,responseBlock);
        });
        SAPAcquireTransportHandle(call.lifetime);
    } @catch (__unused NSException *exception) {
        tryReadOnlyCall(call);
        return;
    }
    if(call.isCancelled) { finishReadOnlyCall(call,nil,nil); return; }
    call.deadline = SAPScheduleDeadline(SAPTransportWorker(), serviceTimeoutSeconds, ^{
        if (!call.finished && call.attempt == attempt) tryReadOnlyCall(call);
    });
}

dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *serviceName, NSString *method, NSData *payload,
                                                    void (^completion)(NSData *response, NSString *error)) {
    SAPInstallTrackDownloader();
    SAPReadOnlyCall *call = [SAPReadOnlyCall new];
    call.completion = completion;
    if (!serviceName.length || !method.length || ![payload isKindOfClass:NSData.class]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if(!call.isCancelled && call.completion)call.completion(nil, @"Invalid metadata request");
            call.completion=nil;
        });
        return ^{ [call markCancelled]; };
    }
    call.serviceName = serviceName; call.method = method; call.payload = payload;
    SAPTraceID parent=SAPTraceCurrentOperation();
    if(!parent&&SAPTraceIsActive())parent=SAPTraceBegin(@"read_only_service",@"pixie",@{@"service":serviceName,@"method":method});
    call.traceOperation=parent;
    dispatch_async(SAPTransportWorker(), ^{
        if(call.isCancelled) { finishReadOnlyCall(call,nil,nil); return; }
        call.endpoints = SAPTransportCandidatesForRead(serviceName,method); call.completion = completion;
        if (!readOnlyCalls) readOnlyCalls = [NSMutableSet set];
        [readOnlyCalls addObject:call];
        tryReadOnlyCall(call);
    });
    return ^{
        if(![call markCancelled])return;
        dispatch_async(SAPTransportWorker(), ^{ if(!call.finished)finishReadOnlyCall(call,nil,nil); });
    };
}
void SAPCallReadOnlyService(NSString *serviceName, NSString *method, NSData *payload,
                            void (^completion)(NSData *response, NSString *error)) {
    SAPCallReadOnlyServiceCancellable(serviceName,method,payload,completion);
}
void SAPInvokeServiceOnce(NSString *serviceName,NSString *method,NSData *payload,
    void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)) {
    SAPInstallTrackDownloader();
    BOOL offline=[serviceName isEqual:SAPOfflineService];
    BOOL playlist=[serviceName hasPrefix:@"spotify.playlist_esperanto.proto."];
    BOOL storage=[serviceName hasPrefix:@"spotify.storage.esperanto.proto."];
    NSString *requestedEvent=offline?@"offline_explicit_command_requested":playlist?@"playlist_explicit_command_requested":storage?@"storage_explicit_command_requested":@"collection_explicit_command_requested";
    NSString *replyEvent=offline?@"offline_explicit_command_reply":playlist?@"playlist_explicit_command_reply":storage?@"storage_explicit_command_reply":@"collection_explicit_command_reply";
    SAPTraceID parent=SAPTraceCurrentOperation();
    if(!parent&&SAPTraceIsActive())parent=SAPTraceBegin(offline?@"explicit_offline_command":playlist?@"explicit_playlist_command":storage?@"explicit_storage_command":@"explicit_collection_command",@"pixie",@{@"service":serviceName,@"method":method});
    dispatch_async(SAPTransportWorker(),^{
        id endpoint=SAPProvenTransport();
        if(!endpoint){if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"No verified Spotify transport. Refresh the device state first.",SAPCommandNotInvoked);});return;}
        SAPReadOnlyCall *call=[SAPReadOnlyCall new];
        call.serviceName=serviceName;call.method=method;call.payload=payload;call.endpoints=@[endpoint];
        call.traceOperation=parent;
        call.commandCompletion=^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
            SAP_JOURNAL_ACTION(replyEvent,@{@"service":serviceName,@"method":method,@"response_received":@(data!=nil),@"response_bytes":@(data.length),@"error":error?:@"",@"automatic_replay":@NO,@"transport_invoked":@(disposition==SAPCommandInvoked)});
            if(completion)completion(data,error,disposition);
        };
        if(!readOnlyCalls)readOnlyCalls=[NSMutableSet set];[readOnlyCalls addObject:call];
        SAP_JOURNAL_ACTION(requestedEvent,@{@"service":serviceName,@"method":method,@"automatic_replay":@NO,@"transport_class":NSStringFromClass(object_getClass(endpoint))});
        tryReadOnlyCall(call); // Its endpoint list contains exactly one entry.
    });
}
