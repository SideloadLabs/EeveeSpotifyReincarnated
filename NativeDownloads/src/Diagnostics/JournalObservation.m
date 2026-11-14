#import "JournalPrivate.h"

static void sampleQuota(void) {
    if(SAPJournalStateStorage.quotaSampler && CFAbsoluteTimeGetCurrent()-SAPJournalStateStorage.lastQuotaSample>=30) {
        SAPJournalStateStorage.lastQuotaSample=CFAbsoluteTimeGetCurrent();SAPJournalStateStorage.quotaSampler();
    }
}

// --- собственные read-only вызовы, подписки и опрос ------------------------

// Each batch/context has its own identity. A reply to one GetItems batch cannot
// acknowledge a different batch, and passive subscription updates acknowledge none.
@interface SAPJournalRead : NSObject
@property(nonatomic,copy) NSString *identifier, *method;
@property(nonatomic,copy) NSData *payload;
@property(nonatomic,strong) id lifetime;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic) NSUInteger attempt;
@property(nonatomic) double sentAt;
@property(nonatomic,copy) NSString *verificationURI;
@property(nonatomic,copy) void (^verification)(NSDictionary *);
@end
@implementation SAPJournalRead @end
#ifdef SAP_TESTING
static const double answerTimeout=0.04;
#else
static const double answerTimeout=4;
#endif
static void releaseRead(SAPJournalRead *operation, BOOL cancel) {
    if(operation.deadline){dispatch_source_cancel(operation.deadline);operation.deadline=nil;}
    if(cancel && [operation.lifetime respondsToSelector:@selector(cancel)]) [operation.lifetime performSelector:@selector(cancel)];
    operation.lifetime=nil;
}
static void sendReadAttempt(SAPJournalRead *operation);
static void readTimedOut(SAPJournalRead *operation, NSUInteger attempt, NSString *reason) {
    if(SAPJournalStateStorage.outstanding[operation.identifier]!=operation || operation.attempt!=attempt)return;
    releaseRead(operation,YES);
    SAPJournalNoteCallIssue(operation.method,operation.verificationURI,attempt?@"bridge":@"preferred",reason);
    SAPJournalWriterLog(@"silent", @"id=%@ %@ bytes=%lu attempt=%lu %@", operation.identifier,operation.method,
        (unsigned long)operation.payload.length,(unsigned long)attempt+1,reason);
    if(attempt<3) { operation.attempt++;sendReadAttempt(operation);return; }
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    [SAPJournalStateStorage.outstanding removeObjectForKey:operation.identifier];
    if(SAPDiagnosticsEnabled())[SAPJournalStateStorage.unanswered addObject:@{@"id":operation.identifier,@"method":operation.method,@"bytes":@(operation.payload.length),
        @"attempts":@4,@"reason":reason,@"at":stamp(rightNow())?:@0,
        @"requested_uris":SAPJournalStringList(SAPProtoFields(operation.payload),[operation.method isEqual:@"GetContexts"]?3:1)}];
    trimEvents(SAPJournalStateStorage.unanswered,maximumEvents);
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    void (^completion)(NSDictionary *)=operation.verification;operation.verification=nil;
    if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil);});
}
static void sendReadAttempt(SAPJournalRead *operation) {
    NSUInteger attempt=operation.attempt;operation.sentAt=rightNow();
    SAPJournalWriterLog(@"call", @"id=%@ %@ sent bytes=%lu route=%@",operation.identifier,operation.method,
        (unsigned long)operation.payload.length,attempt?@"bridge":@"preferred");
    id lifetime=nil;
    @try {
        lifetime=SAPJournalStateStorage.caller(operation.method,operation.payload,NO,attempt,^(NSData *data){
            SAPJournalOnQueue(^{
                if(SAPJournalStateStorage.outstanding[operation.identifier]!=operation || operation.attempt!=attempt)return;
                if(![data isKindOfClass:NSData.class] || data.length>4*1024*1024 || !SAPProtoFields(data)) {
                    readTimedOut(operation,attempt,@"invalid or missing reply");return;
                }
                os_unfair_lock_lock(&SAPJournalStateStorage.lock);[SAPJournalStateStorage.outstanding removeObjectForKey:operation.identifier];os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
                releaseRead(operation,NO);
                SAPJournalWriterLog(@"reply", @"id=%@ %@ bytes=%lu route=%@",operation.identifier,operation.method,
                    (unsigned long)data.length,attempt?@"bridge":@"preferred");
                SAPJournalDecodeCall(operation.method,operation.payload,data,attempt?@"probe:bridge":@"probe:preferred");
                void (^completion)(NSDictionary *)=operation.verification;operation.verification=nil;
                if(completion) {
                    NSDictionary *result=nil;
                    for(NSArray *item in SAPJournalSubMessages(SAPProtoFields(data),1)) {
                        if(![SAPProtoString(item,1) isEqual:operation.verificationURI])continue;
                        NSUInteger state=SAPProtoNumber(item,2,0);
                        result=@{@"uri":operation.verificationURI,@"state":SAPJournalItemStateName(state),
                            @"state_code":@(state),@"progress":@(SAPProtoNumber(item,4,0)),@"source":@"manual:GetItems"};
                        if(SAPDiagnosticsEnabled()) {
                            os_unfair_lock_lock(&SAPJournalStateStorage.lock);SAPTrack *record=SAPJournalStateStorage.tracks[operation.verificationURI];
                            if(record)result=SAPJournalTrackDictionary(record,rightNow());os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
                        }
                        break;
                    }
                    dispatch_async(dispatch_get_main_queue(),^{completion(result);});
                }
                SAPJournalEndSessionIfIdle();
            });
        });
    } @catch(NSException *exception) { readTimedOut(operation,attempt,exception.name);return; }
    // A synchronous invalid callback can queue a retry; only this attempt owns its handle.
    if(SAPJournalStateStorage.outstanding[operation.identifier]==operation && operation.attempt==attempt)operation.lifetime=lifetime;
    operation.deadline=SAPScheduleDeadline(SAPJournalStateStorage.journal,answerTimeout,^{
        readTimedOut(operation,attempt,@"no response before timeout");
    });
}
static SAPJournalRead *send(NSString *method, NSData *payload, BOOL stream) {
    if(!SAPJournalStateStorage.caller)return nil;
    NSData *body=payload?:NSData.data;
    if(stream) {
        NSUInteger expected=SAPJournalStateStorage.subscriptionGeneration;
        id lifetime=SAPJournalStateStorage.caller(method,body,YES,0,^(NSData *data){
            SAPJournalOnQueue(^{
                if(expected!=SAPJournalStateStorage.subscriptionGeneration || !SAPJournalStateStorage.subscribed)return;
                if([data isKindOfClass:NSData.class] && data.length<=4*1024*1024)SAPJournalDecodeCall(method,body,data,@"probe:stream");
            });
        });
        if(lifetime)[SAPJournalStateStorage.lifetimes addObject:lifetime];
        return nil;
    }
    // Coalesce identical pending reads, but retain separate operations for different payloads.
    for(SAPJournalRead *pending in SAPJournalStateStorage.outstanding.allValues)
        if([pending.method isEqual:method] && [pending.payload isEqual:body])return pending;
    if(SAPJournalStateStorage.outstanding.count>=64) {SAPJournalWriterLog(@"call",@"%@ skipped: pending read limit",method);return nil;}
    SAPJournalRead *operation=[SAPJournalRead new];operation.identifier=NSUUID.UUID.UUIDString;
    operation.method=method;operation.payload=body;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);SAPJournalStateStorage.outstanding[operation.identifier]=operation;os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    sendReadAttempt(operation);return operation;
}
void SAPJournalVerifyTrack(NSString *uri,void (^completion)(NSDictionary *)) {
    if(![uri hasPrefix:@"spotify:track:"] || uri.length>256) {
        if(completion)completion(nil);return;
    }
    SAPJournalOnQueue(^{
        if(SAPDiagnosticsEnabled()){os_unfair_lock_lock(&SAPJournalStateStorage.lock);SAPJournalStateStorage.focusedURI=[uri copy];os_unfair_lock_unlock(&SAPJournalStateStorage.lock);}
        SAPJournalRead *operation=send(@"GetItems",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),NO);
        if(operation) {operation.verificationURI=uri;operation.verification=completion;}
        else if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil);});
    });
}
void SAPJournalNoteCallIssue(NSString *method,NSString *uri,NSString *channel,NSString *issue) {
    if(!SAPDiagnosticsEnabled())return;
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        [SAPJournalStateStorage.transportEvents addObject:@{@"method":method?:@"",@"uri":uri?:@"",@"channel":channel?:@"",@"issue":issue?:@"",@"at":stamp(rightNow())?:@0}];
        trimEvents(SAPJournalStateStorage.transportEvents,maximumEvents);os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalWriterLog(@"transport",@"%@ uri=%@ channel=%@ %@",method?:@"",uri?:@"",channel?:@"",issue?:@"");
    });
}
void SAPJournalRequestReconciliation(NSString *uri) {
    if(!SAPDiagnosticsEnabled())return;
    if(!SAPJournalStateStorage.caller || ![uri hasPrefix:@"spotify:track:"])return;
    if(!SAPJournalStateStorage.reconciliationTimes)SAPJournalStateStorage.reconciliationTimes=[NSMutableDictionary dictionary];
    if(rightNow()-[SAPJournalStateStorage.reconciliationTimes[uri] doubleValue]<10)return;
    if(SAPJournalStateStorage.reconciliationTimes.count>=maximumTracks)[SAPJournalStateStorage.reconciliationTimes removeAllObjects];
    SAPJournalStateStorage.reconciliationTimes[uri]=@(rightNow());
    send(@"GetItems",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),NO);
}
void SAPJournalCancelLifetimes(void) {
    SAPNativeErrorLogSetActive(NO);
    SAPPlayerTraceSetActive(NO);
    SAPJournalStateStorage.playerTraceSessionGeneration++;
    for (id lifetime in [SAPJournalStateStorage.lifetimes copy]) if ([lifetime respondsToSelector:@selector(cancel)]) [lifetime performSelector:@selector(cancel)];
    [SAPJournalStateStorage.lifetimes removeAllObjects]; SAPJournalStateStorage.subscribed = NO;SAPJournalStateStorage.subscriptionGeneration++;
    for(SAPJournalRead *operation in [SAPJournalStateStorage.outstanding.allValues copy]) {
        // A user-requested one-track verification works without diagnostics.
        if(operation.verificationURI)continue;
        releaseRead(operation,YES);
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);[SAPJournalStateStorage.outstanding removeObjectForKey:operation.identifier];os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    }
}
static NSData *uriListRequest(unsigned number, NSArray<NSString *> *uris) {
    NSMutableData *payload = [NSMutableData data];
    for (NSString *uri in uris) [payload appendData:SAPProtoBytes(number, [uri dataUsingEncoding:NSUTF8StringEncoding])];
    return payload;
}
// GetContextsRequest: policy.items(1.1) = true, uris(3).
static NSData *contextRequest(NSArray<NSString *> *uris) {
    NSMutableData *payload = [SAPProtoBytes(1, SAPProtoInteger(1, 1)) mutableCopy];
    [payload appendData:uriListRequest(3, uris)];
    return payload;
}
static NSArray<NSString *> *entityList(NSUInteger limit) {
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    NSArray *keys = [SAPJournalStateStorage.entities.allKeys sortedArrayUsingSelector:@selector(compare:)];
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    return keys.count > limit ? [keys subarrayWithRange:NSMakeRange(0, limit)] : keys;
}
// Only tracks still in progress. Every other known track used to be re-read
// every 5 s (an open artist catalog made that thousands of items per tick).
static NSArray<NSString *> *urisToQuery(void) {
    NSMutableArray *result = [NSMutableArray array];
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    for (SAPTrack *record in SAPJournalStateStorage.tracks.allValues)
        if (SAPJournalNeedsPoll(record->seen, record->state, record->addRequests)) [result addObject:record->uri];
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    NSUInteger limit = chunkSize * maximumChunks;
    return result.count > limit ? [result subarrayWithRange:NSMakeRange(0, limit)] : result;
}
static void refreshItems(void) {
    NSArray *uris = urisToQuery();
    for (NSUInteger start = 0; start < uris.count; start += chunkSize) {
        NSRange range = NSMakeRange(start, MIN(chunkSize, uris.count - start));
        send(@"GetItems", uriListRequest(1, [uris subarrayWithRange:range]), NO);
    }
}
static void refreshContexts(void) {
    NSArray *list = entityList(8);
    if (!list.count) return;
    for (NSString *entity in list) send(@"GetContexts", contextRequest(@[entity]), NO);
    send(@"GetContextsProgress", uriListRequest(1, list), NO);
}
static void refreshSnapshots(void) {
    send(@"GetTotalProgress", NSData.data, NO);
    send(@"LicenseStatus", NSData.data, NO);
    send(@"BulkRedownloadPreflight", NSData.data, NO);
    send(@"GetOfflinePlaybackStatus", NSData.data, NO);
}
static void startSubscriptions(void) {
    if (!SAPDiagnosticsEnabled() || SAPJournalStateStorage.subscribed || !SAPJournalStateStorage.caller) return;
    SAPJournalStateStorage.subscribed = YES;
    send(@"SubscribeError", NSData.data, YES);
    send(@"SubscribeTotalProgress", NSData.data, YES);
    send(@"SubscribeContextAdded", NSData.data, YES);
    NSArray *list = entityList(4);
    if (list.count) send(@"SubscribeContexts", contextRequest(list), YES);
}
void SAPJournalStopPolling(void) { if (SAPJournalStateStorage.pollTimer) { dispatch_source_cancel(SAPJournalStateStorage.pollTimer); SAPJournalStateStorage.pollTimer = nil; } }
void SAPJournalDiagnosticsChanged(void) {
    SAPJournalOnQueue(^{
        if(SAPDiagnosticsEnabled()) {SAPJournalRefresh(@"diagnostics enabled");return;}
        SAPJournalStopPolling();SAPJournalCancelLifetimes();
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        if(SAPJournalStateStorage.session) {
            SAPJournalStateStorage.session[@"stopped_reason"]=@"diagnostics disabled";SAPJournalStateStorage.session[@"finished_at"]=stamp(rightNow());
            [SAPJournalStateStorage.session removeObjectForKey:@"started_absolute"];
            [SAPJournalStateStorage.sessionHistory addObject:[SAPJournalStateStorage.session copy]];trimEvents(SAPJournalStateStorage.sessionHistory,4);SAPJournalStateStorage.session=nil;
        }
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalWriterClose(NO);
        SAPJournalStateStorage.lastRefresh=0;SAPJournalStateStorage.lastQuotaSample=0;
    });
}
static void poll(void);
static void startPolling(void) {
    if (!SAPDiagnosticsEnabled() || SAPJournalStateStorage.pollTimer) return;
    SAPJournalStateStorage.pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, SAPJournalStateStorage.journal);
    dispatch_source_set_timer(SAPJournalStateStorage.pollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pollInterval * NSEC_PER_SEC)),
        (uint64_t)(pollInterval * NSEC_PER_SEC), NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(SAPJournalStateStorage.pollTimer, ^{ poll(); });
    dispatch_resume(SAPJournalStateStorage.pollTimer);
}


static NSDictionary *stateCounts(NSUInteger *pendingOut) {
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    NSDictionary *counts = SAPJournalStateCountsLocked(pendingOut);
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    return counts;
}
void SAPJournalBeginSession(NSString *reason, NSString *entity) {
    if(!SAPDiagnosticsEnabled())return;
    if (SAPJournalStateStorage.session) {
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        if (entity.length) SAPJournalStateStorage.session[@"entity"] = entity;
        SAPJournalStateStorage.session[@"last_activity"] = stamp(rightNow());
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        startSubscriptions(); startPolling();
        return;
    }
    double moment = rightNow();
    NSMutableDictionary *started = [@{@"reason": reason ?: @"", @"started_at": stamp(moment) ?: @0,
        @"last_activity": stamp(moment) ?: @0, @"started_absolute": @(moment)} mutableCopy];
    if (entity.length) started[@"entity"] = entity;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock); SAPJournalStateStorage.session = started; os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    NSLog(@"[SpotifyAudioProbe] download session started (%@%@%@)", reason ?: @"", entity.length ? @", " : @"", entity ?: @"");
    SAPJournalWriterLog(@"session", @"started reason=%@ entity=%@ tracked=%lu", reason ?: @"", entity ?: @"-", (unsigned long)SAPJournalStateStorage.tracks.count);
    SAPNativeErrorLogSetActive(YES);
    NSUInteger traceSession=++SAPJournalStateStorage.playerTraceSessionGeneration;
    SAPPlayerTraceSetSink(^(NSDictionary *event){
        if(atomic_fetch_add(&SAPJournalStateStorage.playerTraceSinkPending,1)>=16){
            atomic_fetch_sub(&SAPJournalStateStorage.playerTraceSinkPending,1);atomic_fetch_add(&SAPJournalStateStorage.playerTraceSinkDropped,1);return;
        }
        SAPJournalOnQueue(^{
            @try {
                if(!SAPJournalStateStorage.session || SAPJournalStateStorage.playerTraceSessionGeneration!=traceSession)return;
                NSData *json=[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];
                if(json)SAPJournalWriterWrite(@"player",[[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding]);
            } @finally {atomic_fetch_sub(&SAPJournalStateStorage.playerTraceSinkPending,1);}
        });
    });
    SAPPlayerTraceSetActive(YES);
    startSubscriptions(); startPolling();
    refreshSnapshots(); refreshContexts(); refreshItems();sampleQuota();
}
void SAPJournalEndSessionIfIdle(void) {
    if (!SAPJournalStateStorage.session) return;
    NSUInteger pending = 0; NSDictionary *counts = stateCounts(&pending);
    double moment = rightNow();
    if (pending) {
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        SAPJournalStateStorage.session[@"last_activity"] = stamp(moment);
        SAPJournalStateStorage.session[@"peak_pending"] = @(MAX(pending, [SAPJournalStateStorage.session[@"peak_pending"] unsignedIntegerValue]));
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        return;
    }
    double last = [SAPJournalStateStorage.session[@"last_activity"] doubleValue] - kCFAbsoluteTimeIntervalSince1970;
    if (moment - last < sessionIdleTimeout) return;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    SAPJournalStateStorage.session[@"finished_at"] = stamp(moment);
    SAPJournalStateStorage.session[@"duration_seconds"] = @(round(moment - [SAPJournalStateStorage.session[@"started_absolute"] doubleValue]));
    SAPJournalStateStorage.session[@"final_counts"] = counts;
    [SAPJournalStateStorage.session removeObjectForKey:@"started_absolute"];
    [SAPJournalStateStorage.sessionHistory addObject:[SAPJournalStateStorage.session copy]]; trimEvents(SAPJournalStateStorage.sessionHistory, 4);
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    NSLog(@"[SpotifyAudioProbe] download session finished: %@", counts);
    SAPJournalWriterLog(@"session", @"finished after %@s counts=%@", SAPJournalStateStorage.session[@"duration_seconds"], counts);
    os_unfair_lock_lock(&SAPJournalStateStorage.lock); SAPJournalStateStorage.session = nil; os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    SAPJournalStopPolling(); SAPJournalCancelLifetimes();
}
static void poll(void) {
    if(!SAPDiagnosticsEnabled()){SAPJournalStopPolling();SAPJournalCancelLifetimes();return;}
    if (!SAPJournalStateStorage.session) { SAPJournalStopPolling(); return; }
    double started = [SAPJournalStateStorage.session[@"started_absolute"] doubleValue];
    if (started > 0 && rightNow() - started > maximumSessionSeconds) {
        SAPJournalWriterLog(@"session", @"stopped after %.0fs polling limit", rightNow() - started);
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        SAPJournalStateStorage.session[@"stopped_reason"] = @"polling limit reached";
        SAPJournalStateStorage.session[@"finished_at"] = stamp(rightNow());
        SAPJournalStateStorage.session[@"final_counts"] = SAPJournalStateCountsLocked(NULL);
        [SAPJournalStateStorage.session removeObjectForKey:@"started_absolute"];
        [SAPJournalStateStorage.sessionHistory addObject:[SAPJournalStateStorage.session copy]]; trimEvents(SAPJournalStateStorage.sessionHistory, 4);
        SAPJournalStateStorage.session = nil;
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalStopPolling(); SAPJournalCancelLifetimes();
        return;
    }
    SAPJournalStateStorage.pollTicks++;
    refreshItems();
    if (SAPJournalStateStorage.pollTicks % 2 == 0) { refreshContexts(); send(@"GetTotalProgress", NSData.data, NO); }
    if (SAPJournalStateStorage.pollTicks % 6 == 0) { refreshSnapshots(); if (SAPJournalStateStorage.quotaSampler) SAPJournalStateStorage.quotaSampler(); }
    SAPJournalEndSessionIfIdle();
}
void SAPJournalSetQuotaSampler(void (^sampler)(void)) {
    void (^copied)(void) = [sampler copy];
    SAPJournalOnQueue(^{ SAPJournalStateStorage.quotaSampler = copied; });
}
void SAPJournalSetCaller(SAPJournalCaller value) {
    SAPJournalCaller copied = [value copy];
    SAPJournalOnQueue(^{
        SAPJournalStateStorage.caller = copied; atomic_store(&SAPJournalStateStorage.callerAvailable, copied != nil);
        SAPJournalWriterLog(@"call", @"core channel %@", copied ? @"available" : @"cleared");
        if (SAPJournalStateStorage.session) { startSubscriptions(); startPolling(); }
    });
}
void SAPJournalRefresh(NSString *reason) {
    if(!SAPDiagnosticsEnabled())return;
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        double moment = rightNow();
        if (moment - SAPJournalStateStorage.lastRefresh < refreshThrottle) return;
        SAPJournalStateStorage.lastRefresh = moment;
        SAPJournalBeginSession(reason?:@"manual refresh",nil);
        refreshSnapshots(); refreshContexts(); refreshItems();sampleQuota();
        if (reason.length) { NSLog(@"[SpotifyAudioProbe] journal refresh (%@)", reason); SAPJournalWriterLog(@"refresh", @"%@", reason); }
    });
}

#ifdef SAP_TESTING
void SAPJournalTimeoutsForTesting(void) {
    SAPJournalSetup();dispatch_sync(SAPJournalStateStorage.journal,^{
        for(SAPJournalRead *operation in [SAPJournalStateStorage.outstanding.allValues copy])readTimedOut(operation,operation.attempt,@"test timeout");
    });
}
#endif
