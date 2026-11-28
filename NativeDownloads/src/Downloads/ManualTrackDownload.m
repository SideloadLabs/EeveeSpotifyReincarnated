#import "Localization.h"
#import "TrackDownload.h"
#import "NativeOffline.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>
#include <os/lock.h>

// Native service access and manual jobs retain the same serial execution context.
#import "SpotifyTransport.h"
static atomic_uint_fast64_t preparationGeneration;
static NSArray *installed;
static os_unfair_lock reportLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *reportSnapshot;
static NSArray *history = @[];
static dispatch_source_t timer;
static id jobTransport, errorStream;
static NSArray *jobCandidates;
static NSUInteger candidateIndex, routeGeneration;
static CFAbsoluteTime candidateStarted;
static BOOL routeVerified;
static NSString *exceptionName;
static NSURL *jobURL;
static NSString *title, *phase = @"idle", *detail;
static CFAbsoluteTime started;
static CFAbsoluteTime commandSentAt, errorStateSince;
static NSUInteger nativeState, progress, polls, consecutiveComplete, generation;
static NSNumber *responseCode, *offlineAllowed, *streamError;
static BOOL itemFound, polling, sentRequest, watchItems, existingDownload;
static void (^notify)(NSString *);
static atomic_bool active;
static SAPTraceID jobTraceOperation;
#ifdef SAP_TESTING
static double pollSeconds = 0.01, startTimeoutSeconds = 0.12, totalTimeoutSeconds = 1;
static double candidateTimeoutSeconds = 0.03;
static double errorSettleSeconds = 0.12;
#else
static double pollSeconds = 1, startTimeoutSeconds = 30, totalTimeoutSeconds = 600;
static double candidateTimeoutSeconds = 3;
static double errorSettleSeconds = 30;
#endif

@interface SAPOfflineCall : NSObject
@property(nonatomic, strong) id lifetime, endpoint;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSData *payload;
@property(nonatomic, copy) void (^completion)(NSArray *);
@property(nonatomic) NSUInteger attempt, expected, expectedRoute;
@property(nonatomic) SAPTraceID traceOperation;
@end
@implementation SAPOfflineCall @end
static NSMutableSet<SAPOfflineCall *> *calls;
@interface SAPAlbumDownloadCall : NSObject
@property(nonatomic,copy) NSString *uri;
@property(nonatomic,strong) id lifetime;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,copy) void (^message)(NSString *);
@property(nonatomic) SAPTraceID traceOperation;
@end
@implementation SAPAlbumDownloadCall @end
static SAPAlbumDownloadCall *albumCall;

static void albumMessage(void (^callback)(NSString *), NSString *message) {
    SAP_JOURNAL_ACTION(@"album_user_message",@{@"text":message?:@""});
    if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(message); });
}

static void finishAlbumCall(SAPAlbumDownloadCall *call, BOOL cancel) {
    if (albumCall != call) return;
    if (call.deadline) { dispatch_source_cancel(call.deadline); call.deadline = nil; }
    if (cancel) SAPCancelTransportHandle(call.lifetime);
    call.lifetime = nil;
    albumCall = nil;
}

static NSString *errorName(uint64_t code) {
    switch (code) {
        case 0: return @"SUCCESS"; case 1: return @"GENERIC"; case 8: return @"DISK_FULL";
        case 14: return @"EXPIRED"; case 19: return @"TOO_MANY_TRACKS"; case 23: return @"NOT_ALLOWED";
        case 36: return @"CONNECTION_DISABLED"; case 7028: return @"DEVICE_LIMIT_REACHED";
        default: return @"UNKNOWN";
    }
}
static void publishActivity(BOOL isActive) {
    if(isActive&&!jobTraceOperation&&SAPTraceIsActive())jobTraceOperation=SAPTraceBegin(@"download_seen_after_diagnostics_enabled",@"pixie_monitor",@{@"started_before_trace":@YES,@"uri":jobURL.absoluteString?:@""});
    NSDictionary *report = @{@"phase": phase, @"detail": detail, @"track_uri": jobURL.absoluteString ?: @"",
        @"track_title": title ?: @"", @"api": @"Offline.AddDownload", @"item_state": @(nativeState),
        @"sync_progress": @(progress), @"item_found": @(itemFound), @"status_checks": @(polls),
        @"response_error": responseCode ?: NSNull.null, @"response_error_name": responseCode ? errorName(responseCode.unsignedLongLongValue) : @"NO_RESPONSE",
        @"offline_playback_allowed": offlineAllowed ?: NSNull.null, @"offline_stream_error": streamError ?: NSNull.null,
        @"request_sent": @(sentRequest), @"monitoring_existing": @(existingDownload),
        @"transport_class": jobTransport ? NSStringFromClass(object_getClass(jobTransport)) : @"",
        @"transport_candidate": @(candidateIndex), @"transport_candidates": @(jobCandidates.count),
        @"transport_verified": @(routeVerified), @"exception_name": exceptionName ?: NSNull.null,
        @"active": @(isActive),@"offline_audio_playback_tested":@NO,
        @"completion_evidence":[phase isEqual:@"completed"]?@"Spotify GetItems reported DOWNLOADED twice":@"No completed download confirmed by this monitor"};
    NSMutableDictionary *value=[report mutableCopy];
    SAP_TRACE("download","monitor_state",jobTraceOperation,report);
    value[@"error_settle_seconds"]=@(errorSettleSeconds);
    value[@"error_wait_seconds"]=@(errorStateSince>0?MAX(0,CFAbsoluteTimeGetCurrent()-errorStateSince):0);
    NSDictionary *nativeError=jobURL?SAPJournalNativeErrorForURI(jobURL.absoluteString):nil;
    if(nativeError) {
        value[@"latest_native_error"]=nativeError;
        double since=(commandSentAt>0?commandSentAt:started)+kCFAbsoluteTimeIntervalSince1970;
        value[@"native_error_during_attempt"]=@([nativeError[@"at"] doubleValue]>=since);
    }
    report=[value copy];
    os_unfair_lock_lock(&reportLock); reportSnapshot = report;
    if (!isActive && generation && SAPDiagnosticsEnabled()) {
        NSMutableArray *recent = [history mutableCopy]; [recent addObject:report];
        while (recent.count > 8) [recent removeObjectAtIndex:0]; history = [recent copy];
    }
    atomic_store(&active, isActive); os_unfair_lock_unlock(&reportLock);
}
static void publish(void) { publishActivity(atomic_load(&active)); }
static void cancelCallDeadline(SAPOfflineCall *call) {if(call.deadline){dispatch_source_cancel(call.deadline);call.deadline=nil;}}
static void sendMessage(NSString *message) {
    void (^callback)(NSString *) = notify;
    if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(message); });
}
static void finish(NSString *newPhase, NSString *message) {
    phase = newPhase; detail = message;
    SAP_JOURNAL_ACTION(@"single_track_finished",@{@"track_uri":jobURL.absoluteString?:@"",
        @"phase":newPhase?:@"",@"detail":message?:@"",
        @"request_sent":@(sentRequest),@"response_code":responseCode?:NSNull.null,
        @"observed_native_state":@(nativeState)});
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    for (SAPOfflineCall *call in calls) { cancelCallDeadline(call);SAPCancelTransportHandle(call.lifetime); call.lifetime = nil;call.completion=nil; }
    [calls removeAllObjects]; SAPCancelTransportHandle(errorStream); errorStream = nil;
    publishActivity(NO);
#ifndef SAP_TESTING
    // One write per finished attempt; no reporter/polling runs while idle.
    if(SAPDiagnosticsEnabled()) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *json = [NSJSONSerialization dataWithJSONObject:SAPTrackDownloadReport() options:NSJSONWritingPrettyPrinted error:NULL];
    [json writeToURL:[documents URLByAppendingPathComponent:@"SpotifyAudioProbeDownload.json"] atomically:YES];
    }
#endif
    sendMessage(message); notify = nil; jobTransport = nil; jobCandidates = nil;
}
// The bridge's completion is void (^)(NSData *), confirmed at 0x10a03ea78;
// a zero-length NSData is a valid protobuf default response, nil is not.
static NSString *timeoutMessage(void);
static BOOL currentCall(SAPOfflineCall *call,NSUInteger attempt) {
    return atomic_load(&active) && generation==call.expected && routeGeneration==call.expectedRoute &&
        [calls containsObject:call] && call.attempt==attempt;
}
static void invokeSingle(SAPOfflineCall *call);
static void singleFailed(SAPOfflineCall *call,NSUInteger attempt,NSString *reason) {
    if(!currentCall(call,attempt))return;
    cancelCallDeadline(call);
    SAPJournalNoteCallIssue(call.method,jobURL.absoluteString,NSStringFromClass(object_getClass(call.endpoint)),reason);
    SAPCancelTransportHandle(call.lifetime);call.lifetime=nil;
    BOOL readOnly=[call.method isEqual:@"GetItems"] || [call.method isEqual:@"GetOfflinePlaybackStatus"];
    if(readOnly && attempt<3) {
        NSMutableArray *bridges=[NSMutableArray array];
        for(id endpoint in jobCandidates)
            if([NSStringFromClass(object_getClass(endpoint)) isEqual:@"SPTEsperantoTransportBridgeImpl"])[bridges addObject:endpoint];
        // Try distinct bridges in order, starting with the last bridge that answered.
        NSUInteger next=attempt;
        if(next<bridges.count && bridges[next]==call.endpoint)next++;
        if(next<bridges.count) {call.endpoint=bridges[next];call.attempt=next+1;invokeSingle(call);return;}
    }
    [calls removeObject:call];void (^completion)(NSArray *)=call.completion;call.completion=nil;
    if([call.method isEqual:@"AddDownload"] && [reason isEqual:@"no response before timeout"]) {
        finish(@"unconfirmed",timeoutMessage());return;
    }
    if(completion)completion(nil);
}
static void invokeSingle(SAPOfflineCall *call) {
    NSUInteger attempt=call.attempt;
    void (^callback)(NSData *)=^(NSData *data){
        dispatch_async(SAPTransportWorker(),^{
            if(!currentCall(call,attempt)){SAP_TRACE("download","callback_ignored",call.traceOperation,@{@"method":call.method,@"reason":@"attempt_or_job_no_longer_current"});return;}
            NSArray *fields=[data isKindOfClass:NSData.class] && data.length<=262144?SAPProtoFields(data):nil;
            if(!fields) {singleFailed(call,attempt,@"invalid or missing reply");return;}
            cancelCallDeadline(call);[calls removeObject:call];call.lifetime=nil;
            if(attempt) {jobTransport=call.endpoint;SAPRememberTransport(jobTransport,NO,YES);}
            void (^completion)(NSArray *)=call.completion;call.completion=nil;
            if(completion)completion(fields);
        });
    };
    @try {
        SAPTraceWithOperation(call.traceOperation,^{call.lifetime=((id(*)(id,SEL,id,id,id,id))objc_msgSend)(call.endpoint,
            NSSelectorFromString(@"callSingle:method:payload:onResponse:"),SAPOfflineService,call.method,call.payload,callback);});
        SAPAcquireTransportHandle(call.lifetime);
    } @catch(NSException *exception) {exceptionName=exception.name;singleFailed(call,attempt,exception.name);return;}
    // Retrying is restricted to reads. An unacknowledged AddDownload is never replayed.
    BOOL readOnly=[call.method isEqual:@"GetItems"] || [call.method isEqual:@"GetOfflinePlaybackStatus"];
    double timeout=readOnly?candidateTimeoutSeconds:startTimeoutSeconds;
    call.deadline=SAPScheduleDeadline(SAPTransportWorker(),timeout,^{
        singleFailed(call,attempt,@"no response before timeout");
    });
}
static void single(NSString *method,NSData *payload,void (^completion)(NSArray *)) {
    SAPOfflineCall *call=[SAPOfflineCall new];call.endpoint=jobTransport;
    call.method=method;call.payload=payload;call.completion=completion;
    SAPTraceWithOperation(jobTraceOperation,^{call.traceOperation=SAPTraceIsActive()?SAPTraceBegin(@"download_service_call",@"pixie_download",@{@"method":method,@"track_uri":jobURL.absoluteString?:@""}):0;});
    call.expected=generation;call.expectedRoute=routeGeneration;[calls addObject:call];invokeSingle(call);
}
static NSString *timeoutMessage(void) {
    if (!sentRequest) return SAPLocalized(@"getitems_did_not_return_the_track");
    if (!responseCode) return SAPLocalized(@"offline_adddownload_did_not_reply_within");
    if (streamError.unsignedLongLongValue)
        return [NSString stringWithFormat:SAPLocalized(@"the_download_start_is_not_confirmed"), errorName(streamError.unsignedLongLongValue), streamError];
    return SAPLocalized(@"the_api_accepted_the_command_but");
}
static void readItem(NSArray *fields) {
    itemFound = NO; nativeState = progress = 0;
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] != 1 || [field[@"wire"] unsignedIntValue] != 2) continue;
        NSArray *item = SAPProtoFields(field[@"value"]);
        if (![SAPProtoString(item, 1) isEqual:jobURL.absoluteString]) continue;
        itemFound = YES; nativeState = SAPProtoNumber(item, 2, 0); progress = SAPProtoNumber(item, 4, 0); break;
    }
}
static void queryItem(void) {
    if (polling) return; polling = YES;
    single(@"GetItems", SAPProtoBytes(1, [jobURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]), ^(NSArray *fields) {
        polling = NO; polls++;
        if (!fields) { finish(@"invalid_response", SAPLocalized(@"no_valid_getitems_response_downloading_is")); return; }
        readItem(fields);
        if(!itemFound || nativeState!=1)errorStateSince=0;
        if (itemFound && nativeState == 3) {
            phase = @"verifying"; detail = SAPLocalized(@"spotify_reported_the_track_as_downloaded");
            if (++consecutiveComplete >= 2) {
                finish(@"completed", [NSString stringWithFormat:SAPLocalized(@"spotify_twice_reported_as_downloaded_offline"), title]); return;
            }
        } else {
            consecutiveComplete = 0;
            if (itemFound && nativeState == 1) {
                // GetItems can still contain the error from a previous attempt
                // after AddDownload SUCCESS. Observe a bounded settling period;
                // do not replay AddDownload or mark the track as downloaded.
                double now=CFAbsoluteTimeGetCurrent();
                if(!errorStateSince)errorStateSince=now;
                if(now-errorStateSince<errorSettleSeconds) {
                    phase=@"waiting_error_update";
                    detail=SAPLocalized(@"the_core_still_reports_error_waiting");
                    publish();return;
                }
                NSDictionary *nativeError=SAPJournalNativeErrorForURI(jobURL.absoluteString);
                double since=(commandSentAt>0?commandSentAt:started)+kCFAbsoluteTimeIntervalSince1970;
                BOOL fresh=[nativeError[@"at"] doubleValue]>=since;
                if(fresh && ([nativeError[@"code"] integerValue]==7004 || [nativeError[@"name"] isEqual:@"key_denied"] || [nativeError[@"name"] isEqual:@"sync_error_offline_key_failed"])) {
                    finish(@"failed",SAPLocalized(@"the_core_reported_key_denied_7004"));return;
                }
                NSString *code = streamError ? [NSString stringWithFormat:SAPLocalized(@"core_event"), errorName(streamError.unsignedLongLongValue), streamError] : @"";
                finish(@"failed", [SAPLocalized(@"the_track_remained_in_error_for") stringByAppendingString:code]); return;
            }
            if (itemFound && nativeState == 5) { phase = @"downloading"; detail = [NSString stringWithFormat:SAPLocalized(@"spotify_is_downloading_the_track"), (unsigned long)progress]; }
            else if (itemFound && (nativeState == 4 || nativeState == 6)) { phase = @"queued"; detail = SAPLocalized(@"track_queued_in_spotify"); }
            else if (itemFound && nativeState == 7) { finish(@"failed", SAPLocalized(@"spotify_reported_waiting_limit_exceeded_the")); return; }
        }
        publish();
    });
}
static void selectNextCandidate(void);
static void check(void) {
    if (!atomic_load(&active)) return;
    if ([phase isEqual:@"preparing_native"]) return;
    double elapsed = CFAbsoluteTimeGetCurrent() - started;
    if (!routeVerified) {
        if (CFAbsoluteTimeGetCurrent() - candidateStarted >= candidateTimeoutSeconds) selectNextCandidate();
        return;
    }
    if (elapsed >= totalTimeoutSeconds) {
        finish(@"timeout", SAPLocalized(@"completion_was_not_confirmed_within_10")); return;
    }
    if (elapsed >= startTimeoutSeconds && (!watchItems || !itemFound || nativeState == 0 || nativeState == 2)) {
        finish(@"unconfirmed", timeoutMessage()); return;
    }
    if (watchItems) queryItem();
}
static void addDownload(void) {
    commandSentAt=CFAbsoluteTimeGetCurrent();
    sentRequest = YES; phase = @"requesting"; publish();
    single(@"AddDownload", SAPProtoBytes(2, [jobURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]), ^(NSArray *fields) {
        if (!fields) { finish(@"invalid_response", SAPLocalized(@"invalid_offline_adddownload_response_downloading_is")); return; }
        responseCode = @(SAPProtoNumber(fields, 1, 0));
        if (responseCode.unsignedLongLongValue) {
            finish(@"rejected", [NSString stringWithFormat:SAPLocalized(@"offline_adddownload_returned_this_is_the"), errorName(responseCode.unsignedLongLongValue), responseCode]); return;
        }
        watchItems = YES; phase = @"accepted"; detail = SAPLocalized(@"offline_adddownload_returned_success_checking_that");
        publish(); sendMessage(detail); queryItem();
    });
}
static void startDiagnosticObservers(void) {
    if(!SAPDiagnosticsEnabled() || !atomic_load(&active) || !routeVerified || errorStream)return;
    // Error stream is diagnostic: its events are global and alone never prove
    // that this particular track failed. The one-track response/state is authoritative.
    Method method; SEL streamSel = NSSelectorFromString(@"callStream:method:payload:onResponse:");
    if (SAPTransportSignature(object_getClass(jobTransport), streamSel, 6, '@', &method)) {
        NSUInteger expected = generation;
        BOOL (^callback)(NSData *) = ^BOOL(NSData *data) {
            if(!SAPDiagnosticsEnabled())return YES;
            dispatch_async(SAPTransportWorker(), ^{
                if (!SAPDiagnosticsEnabled() || !atomic_load(&active) || generation != expected) return;
                NSArray *fields = data.length <= 1024 ? SAPProtoFields(data) : nil;
                if (fields) { streamError = @(SAPProtoNumber(fields, 1, 0)); publish(); }
            });
            return YES;
        };
        @try {
            errorStream = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(jobTransport, streamSel, SAPOfflineService, @"SubscribeError", NSData.data, callback);
            SAPAcquireTransportHandle(errorStream);
        }
        @catch (NSException *exception) {}
    }
    single(@"GetOfflinePlaybackStatus", NSData.data, ^(NSArray *fields) {
        if (fields) offlineAllowed = @(SAPProtoNumber(fields, 1, 0) != 0);
        publish();
    });
}
static void startRequest(void) {
    startDiagnosticObservers();
    if (itemFound && (nativeState == 3 || nativeState == 4 || nativeState == 5 || nativeState == 6)) {
        existingDownload = YES; watchItems = YES;
        consecutiveComplete = nativeState == 3 ? 1 : 0;
        phase = @"checking_existing"; detail = SAPLocalized(@"the_track_is_already_downloaded_or");
        publish();
    } else addDownload();
}
static void selectNextCandidate(void) {
    for (SAPOfflineCall *call in calls) { cancelCallDeadline(call);SAPCancelTransportHandle(call.lifetime); call.lifetime = nil;call.completion=nil; }
    [calls removeAllObjects]; routeGeneration++;
    if (candidateIndex >= jobCandidates.count) {
        finish(@"transport_unavailable", SAPLocalized(@"no_available_core_transport_replied_to")); return;
    }
    jobTransport = jobCandidates[candidateIndex++]; candidateStarted = CFAbsoluteTimeGetCurrent();
    phase = @"probing_transport"; detail = SAPLocalized(@"checking_downloader_access_through_getitems"); publish();
    single(@"GetItems", SAPProtoBytes(1, [jobURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]), ^(NSArray *fields) {
        if (!fields) { selectNextCandidate(); return; }
        routeVerified = YES; SAPRememberTransport(jobTransport, NO, YES); polls++; readItem(fields);
        started = CFAbsoluteTimeGetCurrent(); startRequest();
    });
}
void SAPInstallTrackDownloader(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detail=SAPLocalized(@"no_download_started");
        SAPInitializeTransportRuntime();
        [NSNotificationCenter.defaultCenter addObserverForName:SAPDiagnosticsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note){
            dispatch_async(SAPTransportWorker(),^{
                if(SAPDiagnosticsEnabled())startDiagnosticObservers();
                else {
                    SAPCancelTransportHandle(errorStream);errorStream=nil;
                    for(SAPOfflineCall *call in [calls copy])if([call.method isEqual:@"GetOfflinePlaybackStatus"]) {
                        cancelCallDeadline(call);SAPCancelTransportHandle(call.lifetime);call.lifetime=nil;call.completion=nil;[calls removeObject:call];
                    }
                }
            });
        }];
        calls = [NSMutableSet set];
        installed=SAPInstallSpotifyTransportHooks();publish();
    });
}
void SAPDownloadCurrentTrack(void (^message)(NSString *)) {
    SAPInstallTrackDownloader();
    SAPTraceID trace=SAPTraceCurrentOperation();if(!trace&&SAPTraceIsActive())trace=SAPTraceBegin(@"download_current_track",@"pixie_api",@{});
    if(SAPDiagnosticsEnabled())SAPJournalRefresh(@"download button");
    if (atomic_load(&active)) { if (message) message(SAPTrackDownloadSummary()); return; }
    id state = SAPTransportObject(SAPTransportPlayer(), @"state"), track = SAPTransportObject(state, @"track"), uri = SAPTransportObject(track, @"URI");
    NSString *urlString = [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : [uri isKindOfClass:NSString.class] ? uri : nil;
    NSString *trackTitle = SAPTransportObject(track, @"trackTitle");
    NSString *identifier = [urlString hasPrefix:@"spotify:track:"] ? [urlString substringFromIndex:14] : nil;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"].invertedSet;
    if (identifier.length != 22 || [identifier rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        SAP_JOURNAL_ACTION(@"single_track_rejected",@{@"reason":@"current_track_uri_unavailable"});
        if (message) message(SAPLocalized(@"could_not_identify_the_current_music")); return;
    }
    NSArray *available = SAPTransportCandidates(); id currentTransport = available.firstObject; Method method;
    if (!SAPTransportSignature(object_getClass(currentTransport), NSSelectorFromString(@"callSingle:method:payload:onResponse:"), 6, '@', &method)) {
        SAP_JOURNAL_ACTION(@"single_track_rejected",@{@"track_uri":urlString,@"reason":@"spotify_transport_unavailable"});
        if (message) message(SAPLocalized(@"the_spotify_core_transport_is_not")); return;
    }
    SAP_JOURNAL_ACTION(@"single_track_requested",@{@"track_uri":urlString,@"transport_available":@YES});
    dispatch_async(SAPTransportWorker(), ^{
        if (atomic_load(&active)) return;
        jobTraceOperation=trace;
        generation++; jobCandidates = available; candidateIndex = 0; routeVerified = NO; exceptionName = nil;
        jobURL = [NSURL URLWithString:urlString];
        title = [trackTitle isKindOfClass:NSString.class] && trackTitle.length ? [trackTitle copy] : identifier;
        nativeState = progress = polls = consecutiveComplete = 0;
        commandSentAt=errorStateSince=0;
        itemFound = polling = sentRequest = watchItems = existingDownload = NO;
        responseCode = offlineAllowed = streamError = nil;
        phase = @"preparing_native"; detail = SAPLocalized(@"preparing_the_native_download_manager");
        started = CFAbsoluteTimeGetCurrent(); notify = [message copy]; publishActivity(YES);
        sendMessage([NSString stringWithFormat:SAPLocalized(@"requesting_for_spotify_offline_storage"), title]);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, SAPTransportWorker());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pollSeconds * NSEC_PER_SEC)),
            (uint64_t)(pollSeconds * NSEC_PER_SEC), (uint64_t)(pollSeconds / 10 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{ check(); }); dispatch_resume(timer);
        NSUInteger expected = generation;
        atomic_store(&preparationGeneration, expected);
        SAPTraceWithOperation(jobTraceOperation,^{SAPPrepareNativeOffline(^BOOL{
            return atomic_load(&active) && atomic_load(&preparationGeneration) == expected;
        }, ^(BOOL ready, NSString *reason) {
            dispatch_async(SAPTransportWorker(), ^{
                if (!atomic_load(&active) || generation != expected) return;
                if (!ready) { finish(@"native_preparation_failed", reason); return; }
                selectNextCandidate();
            });
        });});
    });
}
void SAPDownloadCurrentAlbum(void (^message)(NSString *)) {
    SAPInstallTrackDownloader();
    SAPTraceID trace=SAPTraceCurrentOperation();if(!trace&&SAPTraceIsActive())trace=SAPTraceBegin(@"download_current_album",@"pixie_api",@{});
    id state = SAPTransportObject(SAPTransportPlayer(), @"state"), track = SAPTransportObject(state, @"track");
    id value = SAPTransportObject(track, @"albumURI");
    NSString *albumURI = [value isKindOfClass:NSURL.class] ? [value absoluteString] :
                         [value isKindOfClass:NSString.class] ? value : nil;
    NSString *prefix = @"spotify:album:";
    NSString *identifier = [albumURI hasPrefix:prefix] ? [albumURI substringFromIndex:prefix.length] : nil;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:
        @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"].invertedSet;
    if (identifier.length != 22 || [identifier rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        SAP_JOURNAL_ACTION(@"album_rejected",@{@"reason":@"current_album_uri_unavailable"});
        if (message) message(SAPLocalized(@"could_not_identify_the_current_track"));
        return;
    }
    SAP_JOURNAL_ACTION(@"album_requested",@{@"album_uri":albumURI});
    void (^reply)(NSString *) = [message copy];
    SAPTraceWithOperation(trace,^{SAPPrepareNativeOffline(^BOOL { return YES; }, ^(BOOL ready, NSString *reason) {
        if (!ready) { SAP_JOURNAL_ACTION(@"album_preparation_failed",@{@"album_uri":albumURI,@"reason":reason?:@""});albumMessage(reply, reason); return; }
        dispatch_async(SAPTransportWorker(), ^{
            if (albumCall) {
                albumMessage(reply, SAPLocalized(@"an_album_download_request_is_already"));
                return;
            }
            id endpoint = SAPTransportCandidates().firstObject;
            SEL selector = NSSelectorFromString(@"callSingle:method:payload:onResponse:");
            Method method;
            if (!SAPTransportSignature(object_getClass(endpoint), selector, 6, '@', &method)) {
                albumMessage(reply, SAPLocalized(@"the_spotify_downloader_transport_is_unavailable"));
                return;
            }
            SAPAlbumDownloadCall *call = [SAPAlbumDownloadCall new];
            call.traceOperation=trace;
            call.uri = albumURI;
            call.message = reply;
            albumCall = call;
            NSData *payload = SAPProtoBytes(2, [albumURI dataUsingEncoding:NSUTF8StringEncoding]);
            void (^onResponse)(NSData *) = ^(NSData *response) {
                dispatch_async(SAPTransportWorker(), ^{
                    if (albumCall != call) return;
                    NSArray *fields = [response isKindOfClass:NSData.class] && response.length <= 4096 ?
                                      SAPProtoFields(response) : nil;
                    finishAlbumCall(call, NO);
                    if (!fields) {
                        SAP_JOURNAL_ACTION(@"album_add_reply_invalid",@{@"album_uri":albumURI,@"response_bytes":@([response isKindOfClass:NSData.class]?response.length:0)});
                        albumMessage(reply, SAPLocalized(@"spotify_returned_an_invalid_reply_the"));
                        return;
                    }
                    uint64_t code = SAPProtoNumber(fields, 1, 0);
                    SAP_JOURNAL_ACTION(@"album_add_reply",@{@"album_uri":albumURI,@"result_code":@(code),@"response_bytes":@(response.length)});
                    if (code) {
                        albumMessage(reply, [NSString stringWithFormat:
                            SAPLocalized(@"spotify_rejected_the_album_download"),
                            errorName(code), (unsigned long long)code]);
                        return;
                    }
                    // A successful RPC acknowledges the command. Confirm that
                    // Spotify actually created a context before reporting a start.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), SAPTransportWorker(), ^{
                        NSMutableData *query = [SAPProtoBytes(1, SAPProtoInteger(1, 1)) mutableCopy];
                        [query appendData:SAPProtoBytes(3, [albumURI dataUsingEncoding:NSUTF8StringEncoding])];
                        SAPTraceWithOperation(call.traceOperation,^{SAPCallReadOnlyService(SAPOfflineService, @"GetContexts", query,
                            ^(NSData *data, NSString *error) {
                                NSArray *envelope = data ? SAPProtoFields(data) : nil;
                                NSArray *info = SAPProtoFields(SAPProtoData(envelope, 1));
                                NSArray *context = SAPProtoFields(SAPProtoData(info, 1));
                                NSString *returnedURI = SAPProtoString(context, 1);
                                SAP_JOURNAL_ACTION(@"album_context_check",@{@"album_uri":albumURI,
                                    @"returned_uri":returnedURI?:@"",@"state":@(SAPProtoNumber(context,2,0)),
                                    @"read_error":error?:@""});
                                if (![returnedURI isEqualToString:albumURI]) {
                                    albumMessage(reply, SAPLocalized(@"spotify_accepted_the_command_but_the_album"));
                                    return;
                                }
                                uint64_t state = SAPProtoNumber(context, 2, 0);
                                if (state == 3) {
                                    albumMessage(reply, SAPLocalized(@"the_album_is_already_fully_downloaded"));
                                } else if (state == 2 || state == 4 || state == 5) {
                                    albumMessage(reply, SAPLocalized(@"the_album_download_has_started_check"));
                                } else {
                                    albumMessage(reply, SAPLocalized(@"spotify_accepted_the_command_but_the"));
                                }
                            });});
                    });
                });
            };
            @try {
                SAPTraceWithOperation(call.traceOperation,^{call.lifetime=((id (*)(id,SEL,id,id,id,id))objc_msgSend)(endpoint,selector,SAPOfflineService,@"AddDownload",payload,onResponse);});
                SAPAcquireTransportHandle(call.lifetime);
                SAP_JOURNAL_ACTION(@"album_add_sent",@{@"album_uri":albumURI,@"lifetime_returned":@(call.lifetime!=nil)});
            } @catch (NSException *exception) {
                SAP_JOURNAL_ACTION(@"album_add_exception",@{@"album_uri":albumURI,@"name":exception.name?:@"unknown"});
                finishAlbumCall(call, YES);
                albumMessage(reply, SAPLocalized(@"spotify_did_not_accept_the_album_download"));
                return;
            }
            call.deadline = SAPScheduleDeadline(SAPTransportWorker(), 30, ^{
                if (albumCall != call) return;
                SAP_JOURNAL_ACTION(@"album_add_timeout",@{@"album_uri":albumURI,@"seconds":@30});
                finishAlbumCall(call, YES);
                albumMessage(reply, SAPLocalized(@"spotify_did_not_answer_within_30"));
            });
        });
    });});
}
void SAPVerifyCurrentTrack(void (^message)(NSString *)) {
    id value=SAPTransportObject(SAPTransportObject(SAPTransportObject(SAPTransportPlayer(),@"state"),@"track"),@"URI");
    NSString *uri=[value isKindOfClass:NSURL.class]?[value absoluteString]:[value isKindOfClass:NSString.class]?value:nil;
    if(![uri hasPrefix:@"spotify:track:"]) {SAP_JOURNAL_ACTION(@"verify_track_rejected",@{@"reason":@"current_track_uri_unavailable"});if(message)message(SAPLocalized(@"the_current_music_track_is_not"));return;}
    SAP_JOURNAL_ACTION(@"verify_track_requested",@{@"track_uri":uri});
    if(SAPDiagnosticsEnabled())SAPReadNativeTrackState(uri);
    SAPJournalVerifyTrack(uri,^(NSDictionary *track){
        SAP_JOURNAL_ACTION(@"verify_track_result",@{@"track_uri":uri,@"state":track[@"state"]?:@"unseen",
            @"state_code":track[@"state_code"]?:NSNull.null,@"progress":track[@"progress"]?:NSNull.null});
        if(!message)return;
        if(!track || [track[@"state"] isEqual:@"unseen"]) {
            message(SAPDiagnosticsEnabled()?SAPLocalized(@"the_core_did_not_confirm_this"):SAPLocalized(@"the_core_did_not_confirm_this_track"));return;
        }
        if(!SAPDiagnosticsEnabled()) {
            message([NSString stringWithFormat:SAPLocalized(@"core_progress"),uri,track[@"state"],track[@"state_code"],track[@"progress"]?:@0]);return;
        }
        message([NSString stringWithFormat:SAPLocalized(@"core_row_icon_observation_data_and"),uri,track[@"state"],track[@"state_code"],
            track[@"legacy_state"]?:SAPLocalized(@"not_received"),track[@"ui_status"]?:SAPLocalized(@"not_observed_2")]);
    });
}
void SAPCancelTrackDownload(void) {
    if (!SAPTransportWorker()) return;
    dispatch_async(SAPTransportWorker(), ^{
        if (!atomic_load(&active)) return;
        SAP_JOURNAL_ACTION(@"single_track_cancel_requested",@{@"track_uri":jobURL.absoluteString?:@"",
            @"add_acknowledged":@(sentRequest&&responseCode&&responseCode.unsignedLongLongValue==0)});
        // RemoveDownload has the exact same DownloadRequest schema. It is only
        // sent for a request that AddDownload acknowledged during this job.
        if (sentRequest && responseCode && responseCode.unsignedLongLongValue == 0) {
            NSData *payload = SAPProtoBytes(2, [jobURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]);
            SEL sel = NSSelectorFromString(@"callSingle:method:payload:onResponse:");
            @try {
                __block id lifetime;
                SAPTraceWithOperation(jobTraceOperation,^{lifetime = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(jobTransport, sel, SAPOfflineService, @"RemoveDownload", payload, ^(NSData *response) {});});
                // acquire transfers request ownership to the native transport;
                // no observer/timer remains in our tweak after cancellation.
                if ([lifetime respondsToSelector:NSSelectorFromString(@"acquire")]) ((void (*)(id, SEL))objc_msgSend)(lifetime, NSSelectorFromString(@"acquire"));
                SAP_JOURNAL_ACTION(@"single_track_remove_sent",@{@"track_uri":jobURL.absoluteString?:@"",
                    @"lifetime_returned":@(lifetime!=nil),@"reply_confirmed":@NO});
            } @catch (NSException *exception) {}
        }
        finish(@"cancelled", SAPLocalized(@"monitoring_stopped_if_the_command_was"));
    });
}
BOOL SAPTrackDownloadActive(void) { return atomic_load(&active); }
NSDictionary *SAPTrackDownloadReport(void) {return SAPTrackDownloadReportWithJournal(nil);}
NSDictionary *SAPTrackDownloadReportWithJournal(NSDictionary *journalReport) {
    os_unfair_lock_lock(&reportLock); NSDictionary *snapshot = reportSnapshot; NSArray *recent = history; os_unfair_lock_unlock(&reportLock);
    NSMutableDictionary *report = [snapshot mutableCopy] ?: [@{@"phase": @"not_installed"} mutableCopy];
    report[@"installed_hooks"] = installed ?: @[];
    report[@"native_offline"] = SAPNativeOfflineReport();
    report[@"player_available"] = @(SAPTransportPlayer() != nil); report[@"transport_available"] = @(SAPCurrentTransport() != nil);
    report[@"journal_summary"] = (journalReport?SAPJournalSummaryForReport(journalReport):SAPJournalSummaryText()) ?: @"";
    report[@"history"] = recent;
    [report addEntriesFromDictionary:SAPTransportWatchReport()];
    return report;
}
NSString *SAPTrackDownloadSummary(void) {
    os_unfair_lock_lock(&reportLock);NSDictionary *report=reportSnapshot;os_unfair_lock_unlock(&reportLock);
    return [NSString stringWithFormat:@"%@%@%@", report[@"track_title"] ?: @"", [report[@"track_title"] length] ? @"\n" : @"", report[@"detail"] ?: SAPLocalized(@"no_download_started")];
}
