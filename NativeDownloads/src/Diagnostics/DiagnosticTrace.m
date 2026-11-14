#import "DiagnosticTrace.h"
#import "WireProto.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <time.h>
#include <errno.h>
#include <math.h>

static atomic_bool active;
static os_unfair_lock traceControlLock=OS_UNFAIR_LOCK_INIT;
static BOOL requestedActive,resetting;
#ifdef SAP_TESTING
static dispatch_block_t resetObserver;
#endif
static atomic_uint_fast64_t generation,identifiers,captured,written,dropped,writeFailures,rotations,evictedBytes,invalidRecords,oversized,redactedOrTruncated;
static atomic_uint pending,rpcPending;
static atomic_uint_fast64_t rpcCapacityDrops,hookCapacityDrops,lifetimeCapacityDrops;
// Traffic telemetry and byte-identical progress repeats carry no download evidence and filled ~65% of a
// real session, rotating the start of the log away. They are counted, never written.
static atomic_uint_fast64_t suppressedTraffic,suppressedRepeats;
static os_unfair_lock repeatLock=OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *,NSData *> *repeatPayloads;
static uint64_t repeatGeneration;
static atomic_int lastWriteErrno;
static dispatch_queue_t writer;
static void *writerKey=&writerKey;
static NSURL *directory;
static NSString *runID;
static FILE *stream;
static NSUInteger fileBytes;
static uint64_t closedThroughGeneration;
static atomic_uint_fast64_t discardedAfterClose;
static atomic_uint_fast64_t resetEpochMilliseconds;
static NSMutableSet *rpcCalls;
static NSUInteger maximumBytes=8*1024*1024,pendingLimit=512;
static const NSUInteger maximumRecordBytes=128*1024,maximumRPC=256;
static double rpcTimeout=4;
static _Thread_local SAPTraceID currentOperation;
static uint64_t startTicks;
static mach_timebase_info_data_t timebase;
static os_unfair_lock hookLock=OS_UNFAIR_LOCK_INIT;
static char lifetimeTraceKey;
static struct {Class cls;SEL selector;IMP installed,original;uint64_t calls,first,last;} hooks[192];
static unsigned hookCount;
static void closeRPCsThroughGeneration(uint64_t closing);

static double seconds(uint64_t ticks) {return (double)ticks*timebase.numer/timebase.denom/1e9;}
static double wallClock(void) {struct timespec t;clock_gettime(CLOCK_REALTIME,&t);return t.tv_sec+t.tv_nsec/1e9;}
bool SAPTraceIsActive(void) {return atomic_load_explicit(&active,memory_order_acquire);}
uint64_t SAPTraceGeneration(void) {return atomic_load_explicit(&generation,memory_order_relaxed);}
SAPTraceID SAPTraceCurrentOperation(void) {return currentOperation;}
void SAPTraceWithOperation(SAPTraceID operation,dispatch_block_t block) {
    SAPTraceID before=currentOperation;currentOperation=operation;
    @try {block();}@finally {currentOperation=before;}
}
static NSURL *fileURL(unsigned index) {
    return [directory URLByAppendingPathComponent:index?[NSString stringWithFormat:@"PixieTrace.%u.jsonl",index]:@"PixieTrace.jsonl"];
}
static void initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        mach_timebase_info(&timebase);startTicks=mach_continuous_time();runID=NSUUID.UUID.UUIDString;
        writer=dispatch_queue_create("Pixie.diagnostic-trace",dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        dispatch_queue_set_specific(writer,writerKey,writerKey,NULL);rpcCalls=[NSMutableSet set];
        if(!directory) {
#ifdef SAP_TESTING
            directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:[@"PixieTraceTests-"stringByAppendingString:NSUUID.UUID.UUIDString]]isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
#else
            directory=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
#endif
        }
    });
}
static void ioFailure(void) {atomic_fetch_add(&writeFailures,1);atomic_store(&lastWriteErrno,errno);}
static BOOL rotate(void) {
    if(stream){if(fclose(stream))ioFailure();stream=NULL;}
    NSDictionary *old=[NSFileManager.defaultManager attributesOfItemAtPath:fileURL(2).path error:nil];
    if(old){atomic_fetch_add(&evictedBytes,[old[NSFileSize]unsignedLongLongValue]);
        NSError *error=nil;if(![NSFileManager.defaultManager removeItemAtURL:fileURL(2) error:&error]){ioFailure();return NO;}}
    for(int i=1;i>=0;i--)if([NSFileManager.defaultManager fileExistsAtPath:fileURL(i).path]) {
        NSError *error=nil;if(![NSFileManager.defaultManager moveItemAtURL:fileURL(i) toURL:fileURL(i+1) error:&error]){ioFailure();return NO;}
    }
    fileBytes=0;atomic_fetch_add(&rotations,1);return YES;
}
static id sanitize(id value,NSUInteger depth) {
    if(depth>12){atomic_fetch_add(&redactedOrTruncated,1);return @"[depth limit]";}
    if([value isKindOfClass:NSNumber.class]||value==NSNull.null)return value;
    if([value isKindOfClass:NSString.class]) {
        NSString *s=value;
        if([s hasPrefix:@"Bearer "]){atomic_fetch_add(&redactedOrTruncated,1);return @"[redacted]";}
        if(s.length>8192){atomic_fetch_add(&redactedOrTruncated,1);return [[s substringToIndex:8192]stringByAppendingString:@"[truncated]"]; }return [s copy];
    }
    if([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out=[NSMutableDictionary dictionary];NSUInteger count=0;
        for(id key in value) {
            if(![key isKindOfClass:NSString.class])continue;
            NSString *lower=[key lowercaseString];
            if([lower isEqual:@"authorization"]||[lower isEqual:@"client-token"]||[lower isEqual:@"cookie"]||[lower isEqual:@"set-cookie"]||
               [lower isEqual:@"access_token"]||[lower isEqual:@"refresh_token"]||[lower isEqual:@"password"]||[lower isEqual:@"key_bytes"]||[lower isEqual:@"secret"]||[lower isEqual:@"client_token"]||[lower isEqual:@"api_key"]) {out[key]=@"[redacted]";atomic_fetch_add(&redactedOrTruncated,1);continue;}
            if(count++>=512){out[@"trace_fields_omitted"]=@YES;atomic_fetch_add(&redactedOrTruncated,1);break;}
            out[key]=sanitize(value[key],depth+1)?:NSNull.null;
        }return [out copy];
    }
    if([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out=[NSMutableArray array];NSUInteger i=0;
        for(id item in value){if(i++>=512){[out addObject:@{@"trace_items_omitted":@([value count]-512)}];atomic_fetch_add(&redactedOrTruncated,1);break;}[out addObject:sanitize(item,depth+1)?:NSNull.null];}return [out copy];
    }
    // NSData and arbitrary native objects are never serialized or described.
    return @"[unsupported value omitted]";
}
static void append(NSDictionary *event) {
    if([event[@"segment"]unsignedLongLongValue]<=closedThroughGeneration){atomic_fetch_add(&discardedAfterClose,1);return;}
    NSMutableDictionary *value=[event mutableCopy];uint64_t now=mach_continuous_time();
    value[@"written_epoch_seconds"]=@(wallClock());value[@"queue_delay_ms"]=@(MAX(0,seconds(now-[event[@"enqueue_ticks"]unsignedLongLongValue])*1000));
    value[@"capture_to_write_ms"]=@(MAX(0,seconds(now-[event[@"capture_ticks"]unsignedLongLongValue])*1000));
    [value removeObjectsForKeys:@[@"capture_ticks",@"enqueue_ticks"]];
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if(!data){atomic_fetch_add(&invalidRecords,1);return;}
    if(data.length>maximumRecordBytes){atomic_fetch_add(&oversized,1);
        value[@"facts"]=@{@"omitted":@YES,@"reason":@"record_size_limit",@"serialized_bytes":@(data.length)};
        data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    }
    if(fileBytes+data.length+1>maximumBytes&&!rotate())return;
    if(!stream){stream=fopen(fileURL(0).fileSystemRepresentation,"a");if(!stream){ioFailure();return;}
        fileBytes=(NSUInteger)ftello(stream);if(fileBytes>maximumBytes){if(!rotate())return;stream=fopen(fileURL(0).fileSystemRepresentation,"a");if(!stream){ioFailure();return;}}}
    if(fwrite(data.bytes,1,data.length,stream)!=data.length||fwrite("\n",1,1,stream)!=1){ioFailure();return;}
    fileBytes+=data.length+1;
    if(fflush(stream)){ioFailure();return;}atomic_fetch_add(&written,1);
}
void SAPTraceEventAtGeneration(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts,uint64_t epoch) {
    if(!SAPTraceIsActive()||epoch!=atomic_load(&generation))return;
    uint64_t ticks=mach_continuous_time();double utc=wallClock();
    if(atomic_fetch_add(&pending,1)>=pendingLimit){atomic_fetch_sub(&pending,1);atomic_fetch_add(&dropped,1);return;}
    uint64_t eventID=atomic_fetch_add(&identifiers,1)+1;
    NSDictionary *value=@{@"run_id":runID?:@"initializing",@"segment":@(epoch),@"event_id":@(eventID),
        @"operation_id":operation?@(operation):NSNull.null,@"parent_operation_id":currentOperation&&currentOperation!=operation?@(currentOperation):NSNull.null,
        @"category":category?@(category):@"unknown",@"stage":stage?@(stage):@"unknown",
        @"captured_epoch_seconds":@(utc),@"since_trace_start_ms":@(seconds(ticks-startTicks)*1000),@"capture_ticks":@(ticks),
        @"evidence":@"observed_at_instrumented_boundary",@"facts":sanitize(facts?:@{},0),@"enqueue_ticks":@(mach_continuous_time())};
    if(epoch!=atomic_load(&generation)||!SAPTraceIsActive()){atomic_fetch_sub(&pending,1);atomic_fetch_add(&discardedAfterClose,1);return;}
    atomic_fetch_add(&captured,1);dispatch_async(writer,^{append(value);atomic_fetch_sub(&pending,1);});
}
void SAPTraceEvent(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts) {
    SAPTraceEventAtGeneration(category,stage,operation,facts,atomic_load(&generation));
}
SAPTraceID SAPTraceBegin(NSString *kind,NSString *source,NSDictionary *facts) {
    if(!SAPTraceIsActive())return 0;
    SAPTraceID operation=atomic_fetch_add(&identifiers,1)+1;
    NSMutableDictionary *value=[facts mutableCopy]?:[NSMutableDictionary dictionary];value[@"kind"]=kind?:@"unknown";value[@"source"]=source?:@"unknown";
    SAPTraceEvent("operation","begin",operation,value);return operation;
}
void SAPTraceFlush(void) {
    if(!writer)return;
    dispatch_block_t block=^{if(stream&&fflush(stream))ioFailure();};
    if(dispatch_get_specific(writerKey))block();else dispatch_sync(writer,block);
}
BOOL SAPTraceReset(NSError **error) {
    os_unfair_lock_lock(&traceControlLock);
    if(resetting){os_unfair_lock_unlock(&traceControlLock);if(error)*error=[NSError errorWithDomain:@"PixieTrace" code:1 userInfo:@{NSLocalizedDescriptionKey:@"A log reset is already in progress."}];return NO;}
    resetting=YES;atomic_store(&active,false);uint64_t closing=atomic_fetch_add(&generation,1);
    os_unfair_lock_unlock(&traceControlLock);
#ifdef SAP_TESTING
    if(resetObserver)resetObserver();
#endif
    __block NSError *failure=nil;
    dispatch_block_t reset=^{
        if(writer){closeRPCsThroughGeneration(closing);closedThroughGeneration=MAX(closedThroughGeneration,closing);}
        if(stream){fclose(stream);stream=NULL;}fileBytes=0;
        NSURL *folder=directory?:[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        for(NSString *name in @[@"PixieTrace.jsonl",@"PixieTrace.1.jsonl",@"PixieTrace.2.jsonl"]) {
            NSURL *url=[folder URLByAppendingPathComponent:name];NSError *e=nil;
            if([NSFileManager.defaultManager fileExistsAtPath:url.path]&&![NSFileManager.defaultManager removeItemAtURL:url error:&e]&&!failure)failure=e;
        }
        if(!failure){
            atomic_store(&captured,0);atomic_store(&written,0);atomic_store(&dropped,0);atomic_store(&writeFailures,0);
            atomic_store(&rotations,0);atomic_store(&evictedBytes,0);atomic_store(&invalidRecords,0);atomic_store(&oversized,0);
            atomic_store(&redactedOrTruncated,0);atomic_store(&suppressedTraffic,0);atomic_store(&suppressedRepeats,0);atomic_store(&lastWriteErrno,0);atomic_store(&discardedAfterClose,0);atomic_store(&rpcCapacityDrops,0);
            atomic_store(&resetEpochMilliseconds,(uint64_t)(wallClock()*1000));
        }
    };
    if(!writer||dispatch_get_specific(writerKey))reset();else dispatch_sync(writer,reset);
    extern void SAPNativeKeyTraceResetSegment(void) __attribute__((weak_import));
    if(SAPNativeKeyTraceResetSegment)SAPNativeKeyTraceResetSegment();
    os_unfair_lock_lock(&traceControlLock);
    BOOL resume=requestedActive;if(resume&&!writer)initialize();
    atomic_fetch_add(&generation,1);atomic_store(&active,resume);resetting=NO;
    os_unfair_lock_unlock(&traceControlLock);
    if(!failure)SAP_TRACE("session","log_reset",0,@{@"previous_history_removed":@YES,@"diagnostics_enabled":@(resume),@"runtime_counters_scope":@"Other module counters retain their explicitly reported process scope"});
    if(error)*error=failure;return failure==nil;
}
void SAPTraceSetEnabled(bool enabled,const char *reason) {
    os_unfair_lock_lock(&traceControlLock);requestedActive=enabled;
    if(resetting||enabled==SAPTraceIsActive()){os_unfair_lock_unlock(&traceControlLock);return;}
    extern void SAPNativeKeyTraceResetSegment(void) __attribute__((weak_import));
    if(enabled){initialize();atomic_fetch_add(&generation,1);if(SAPNativeKeyTraceResetSegment)SAPNativeKeyTraceResetSegment();atomic_store(&active,true);
        SAP_TRACE("session","diagnostics_enabled",0,@{@"reason":reason?@(reason):@"unknown",@"coverage_begins_here":@YES,@"pre_library_events_available":@NO,
            @"captured_from_process_start":@([@(reason?:"")isEqual:@"persisted_on_library_load"]),@"rotation_files":@3,@"max_bytes_per_file":@(maximumBytes)});
    }else {
        SAP_TRACE("session","diagnostics_disabled",0,@{@"reason":reason?@(reason):@"unknown"});
        uint64_t closing=atomic_load(&generation);atomic_store(&active,false);atomic_fetch_add(&generation,1);
        if(SAPNativeKeyTraceResetSegment)SAPNativeKeyTraceResetSegment();
        if(writer)dispatch_async(writer,^{
            closeRPCsThroughGeneration(closing);
            if(stream){if(fclose(stream))ioFailure();stream=NULL;}closedThroughGeneration=MAX(closedThroughGeneration,closing);
        });
    }
    os_unfair_lock_unlock(&traceControlLock);
}
void SAPTraceRegisterHook(Class cls,SEL selector,IMP installed,IMP original) {
    if(!cls||!selector||!installed)return;
    os_unfair_lock_lock(&hookLock);unsigned index=hookCount;
    for(unsigned i=0;i<hookCount;i++)if(hooks[i].cls==cls&&hooks[i].selector==selector){index=i;break;}
    if(index<192){if(index==hookCount)hookCount++;hooks[index].cls=cls;hooks[index].selector=selector;hooks[index].installed=installed;hooks[index].original=original;}
    else atomic_fetch_add(&hookCapacityDrops,1);
    os_unfair_lock_unlock(&hookLock);
    SAP_TRACE("hook",index<192?"installed":"registration_capacity_reached",0,@{@"class":NSStringFromClass(cls),@"selector":NSStringFromSelector(selector)});
}
void SAPTraceHookCalled(Class cls,SEL selector) {
    if(!SAPTraceIsActive())return;BOOL first=NO;uint64_t tick=mach_continuous_time();
    os_unfair_lock_lock(&hookLock);
    for(unsigned i=0;i<hookCount;i++)if(hooks[i].selector==selector&&(hooks[i].cls==cls||[cls isSubclassOfClass:hooks[i].cls])){
        first=hooks[i].calls++==0;if(first)hooks[i].first=tick;hooks[i].last=tick;break;}
    os_unfair_lock_unlock(&hookLock);
    if(first)SAP_TRACE("hook","first_invocation",0,@{@"class":NSStringFromClass(cls),@"selector":NSStringFromSelector(selector)});
}
NSDictionary *SAPTraceHookManifest(void) {
    NSMutableArray *list=[NSMutableArray array],*expected=[NSMutableArray array];os_unfair_lock_lock(&hookLock);
    for(unsigned i=0;i<hookCount;i++){
        Method method=class_getInstanceMethod(hooks[i].cls,hooks[i].selector);IMP current=method?method_getImplementation(method):NULL;
        Dl_info original={0};dladdr(hooks[i].original,&original);
        [list addObject:@{@"class":NSStringFromClass(hooks[i].cls),@"selector":NSStringFromSelector(hooks[i].selector),
            @"current_implementation_matches_installed":@(current==hooks[i].installed),@"invocations_observed":@(hooks[i].calls),
            @"first_since_trace_start_ms":hooks[i].first?@(seconds(hooks[i].first-startTicks)*1000):NSNull.null,
            @"last_since_trace_start_ms":hooks[i].last?@(seconds(hooks[i].last-startTicks)*1000):NSNull.null,
            @"original_image":original.dli_fname?@(original.dli_fname):@"unresolved"}];
    }
    static const struct {const char *cls,*selector,*returns;unsigned arguments;} required[]={
        {"SPTOfflineManagerImplementation","initWithScheduler:offlineManager:syncManager:metadataModel:","@",6},
        {"SPTOfflineManagerImplementation","stateForTrackWithURL:","Q",3},
        {"SPTOfflineManagerImplementation","makeEntityAvailableOfflineWithURL:trackURLs:","v",4},
        {"SPTOfflineManagerImplementation","makeEntityAvailableOfflineWithURL:","v",3},
        {"SPTOfflineManagerImplementation","resetEntityOfflineAvailabilityWithURL:","v",3},
        {"SPTFreeTierOfflineStatusUpdatingContentOperation","offlineSyncStatusForURL:","q",3},
        {"SPTEsperantoTransportBridgeImpl","callSingle:method:payload:onResponse:","@",6},
        {"SPTEsperantoTransportBridgeImpl","callStream:method:payload:onResponse:","@",6},
        {"SPTEsperantoCosmosTransport","callSingle:method:payload:onResponse:","@",6},
        {"SPTEsperantoCosmosTransport","callStream:method:payload:onResponse:","@",6},
        {"SPTCoreProductState","stringForKey:","@",3},
        {"SPTCoreProductState","setOriginalValues:","v",3},
        {"SPTDataLoaderService","URLSession:task:didCompleteWithError:","v",5},
        {"Connectivity_HttpClientKit.HttpClientURLSession","URLSession:task:didCompleteWithError:","v",5},
        {"SPTCoreURLSessionDataDelegate","URLSession:task:didCompleteWithError:","v",5}
    };
    for(unsigned n=0;n<sizeof(required)/sizeof(required[0]);n++) {
        Class cls=objc_getClass(required[n].cls);SEL sel=sel_registerName(required[n].selector);Method m=cls?class_getInstanceMethod(cls,sel):NULL;
        const char *status=!cls?"class_unavailable":!m?"method_unavailable":"not_registered";
        char returns[32]={0};if(m)method_getReturnType(m,returns,sizeof(returns));
        if(m&&(method_getNumberOfArguments(m)!=required[n].arguments||!strchr(required[n].returns,returns[0])))status="signature_mismatch";
        for(unsigned i=0;i<hookCount;i++)if(hooks[i].cls==cls&&hooks[i].selector==sel){status=m&&method_getImplementation(m)==hooks[i].installed?"installed_current_matches":"implementation_changed_after_installation";break;}
        [expected addObject:@{@"class":@(required[n].cls),@"selector":@(required[n].selector),@"status":@(status),@"observed_arguments":m?@(method_getNumberOfArguments(m)):NSNull.null,@"observed_return_type":@(returns)}];
    }
    os_unfair_lock_unlock(&hookLock);return @{@"hooks":list,@"registered_count":@(list.count),@"expected_points":expected,@"unregistered_hooks_covered":@NO};
}
NSDictionary *SAPTraceReport(void) {
    return @{@"schema":@1,@"active":@(SAPTraceIsActive()),@"initialized":@(writer!=nil),@"run_id":runID?:NSNull.null,
        @"captured_events":@(atomic_load(&captured)),@"written_events":@(atomic_load(&written)),@"pending_events":@(atomic_load(&pending)),
        @"last_manual_reset_epoch_seconds":atomic_load(&resetEpochMilliseconds)?@(atomic_load(&resetEpochMilliseconds)/1000.0):NSNull.null,
        @"dropped_before_enqueue":@(atomic_load(&dropped)),@"write_failures":@(atomic_load(&writeFailures)),@"last_write_errno":@(atomic_load(&lastWriteErrno)),
        @"invalid_records":@(atomic_load(&invalidRecords)),@"oversized_records":@(atomic_load(&oversized)),@"rotations":@(atomic_load(&rotations)),
        @"redacted_or_truncated_values":@(atomic_load(&redactedOrTruncated)),
        @"inflight_events_discarded_after_diagnostics_closed":@(atomic_load(&discardedAfterClose)),
        @"suppressed_traffic_adapter_calls":@(atomic_load(&suppressedTraffic)),@"suppressed_identical_progress_callbacks":@(atomic_load(&suppressedRepeats)),
        @"evicted_bytes":@(atomic_load(&evictedBytes)),@"rpc_slots_in_use":@(atomic_load(&rpcPending)),
        @"rpc_observations_dropped_at_capacity":@(atomic_load(&rpcCapacityDrops)),@"hook_registrations_dropped_at_capacity":@(atomic_load(&hookCapacityDrops)),@"lifetime_classes_unobserved_at_capacity":@(atomic_load(&lifetimeCapacityDrops)),
        @"scope":@"Pixie and calls crossing instrumented Spotify transports; not every internal Spotify call",
        @"durability":@"fflush per record; abrupt process/power loss may omit the final events; no crash cause inferred"};
}
NSDictionary *SAPTraceExport(void) {
    if(!writer)return @{@"status":@"not_started",@"coverage":SAPTraceReport(),@"events":@[]};
    __block NSDictionary *result;dispatch_block_t block=^{
        if(stream&&fflush(stream))ioFailure();NSMutableArray *events=[NSMutableArray array],*files=[NSMutableArray array];
        NSUInteger incomplete=0;
        for(int i=2;i>=0;i--){NSError *error=nil;NSData *data=[NSData dataWithContentsOfURL:fileURL(i) options:0 error:&error];
            if(!data){[files addObject:@{@"name":fileURL(i).lastPathComponent,@"status":@"unavailable",@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];continue;}
            NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
            [files addObject:@{@"name":fileURL(i).lastPathComponent,@"status":text?@"included":@"invalid_utf8",@"bytes":@(data.length)}];
            for(NSString *line in [text componentsSeparatedByString:@"\n"]){if(!line.length)continue;
                id event=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if([event isKindOfClass:NSDictionary.class])[events addObject:event];else incomplete++;}
        }
        result=@{@"status":@"captured",@"coverage":SAPTraceReport(),@"hooks":SAPTraceHookManifest(),@"files":files,@"unreadable_lines":@(incomplete),
            @"events":events,@"ordering":@"file write order; captured timestamps/event IDs are assigned at the observed boundary, not on the writer queue"};
    };if(dispatch_get_specific(writerKey))block();else dispatch_sync(writer,block);return result;
}

static NSString *uri(NSArray *fields,unsigned field) {NSString *s=SAPProtoString(fields,field);return [s hasPrefix:@"spotify:"]&&s.length<=256?s:nil;}
static double floatValue(NSArray *fields,unsigned number) {
    for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==number&&[field[@"wire"]unsignedIntValue]==5) {
        NSData *bytes=field[@"value"];float value=0;if(bytes.length==4)memcpy(&value,bytes.bytes,4);
        return isfinite(value)?value:0;
    }
    return 0;
}
static NSDictionary *progressSummary(NSArray *fields) {
    if(!fields)return @{@"valid_protobuf":@NO};
    return @{@"queued_tracks":@(SAPProtoNumber(fields,1,0)),@"queued_bytes":@(SAPProtoNumber(fields,2,0)),
        @"downloaded_tracks":@(SAPProtoNumber(fields,3,0)),@"downloaded_bytes":@(SAPProtoNumber(fields,4,0)),
        @"total_tracks":@(SAPProtoNumber(fields,5,0)),@"total_bytes":@(SAPProtoNumber(fields,6,0)),
        @"downloading":@(SAPProtoNumber(fields,7,0)!=0),@"bytes_per_second":@(SAPProtoNumber(fields,8,0)),
        @"percent":@(floatValue(fields,9)),@"seconds_left":@(SAPProtoNumber(fields,10,0)),@"track_totals_state":@(SAPProtoNumber(fields,11,0))};
}
static NSArray *itemSummary(NSArray *fields,unsigned number,NSUInteger limit) {
    NSMutableArray *items=[NSMutableArray array];
    for(NSDictionary *f in fields) {
        if([f[@"number"]unsignedIntValue]!=number||[f[@"wire"]unsignedIntValue]!=2)continue;
        if(items.count==limit){[items addObject:@{@"items_truncated":@YES}];break;}
        NSArray *item=SAPProtoFields(f[@"value"]);NSString *s=uri(item,1);
        if(s)[items addObject:@{@"uri":s,@"state":@(SAPProtoNumber(item,2,0)),@"video_state":@(SAPProtoNumber(item,3,0)),@"percent":@(SAPProtoNumber(item,4,0))}];
    }
    return items;
}
NSDictionary *SAPTraceWireSummary(NSString *service,NSString *method,NSData *data,BOOL response) {
    if(![data isKindOfClass:NSData.class])return @{@"body_present":@NO};
    if(data.length>1024*1024)return @{@"body_present":@YES,@"bytes":@(data.length),@"decoded":@NO,@"reason":@"size_limit"};
    NSArray *fields=SAPProtoFields(data);NSMutableDictionary *out=[@{@"body_present":@YES,@"bytes":@(data.length),@"valid_protobuf":@(fields!=nil)}mutableCopy];
    NSMutableArray *shape=[NSMutableArray array];for(NSDictionary *f in fields){if(shape.count==256){out[@"shape_truncated"]=@YES;break;}
        [shape addObject:@{@"field":f[@"number"],@"wire":f[@"wire"],@"bytes":[f[@"value"]isKindOfClass:NSData.class]?@([f[@"value"]length]):@0}];}out[@"field_shape"]=shape;
    if(!fields||![service isEqual:@"spotify.offline_esperanto.proto.Offline"]){out[@"values_decoded"]=@NO;return out;}
    out[@"scalar_defaults"]=@"absent protobuf scalars use their schema default (0/false)";
    if(!response){NSMutableArray *uris=[NSMutableArray array];unsigned n=[method isEqual:@"AddDownload"]||[method isEqual:@"RemoveDownload"]?2:[method isEqual:@"GetContexts"]?3:1;
        for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==n&&[f[@"wire"]unsignedIntValue]==2){NSString *s=[[NSString alloc]initWithData:f[@"value"] encoding:NSUTF8StringEncoding];if([s hasPrefix:@"spotify:"]&&s.length<=256)[uris addObject:s];if(uris.count==512)break;}
        out[@"uris"]=uris;return out;
    }
    if([method isEqual:@"AddDownload"]||[method isEqual:@"RemoveDownload"]||[method isEqual:@"SubscribeError"])out[@"error_code"]=@(SAPProtoNumber(fields,1,0));
    else if([method isEqual:@"LicenseStatus"]){out[@"max_licenses"]=@(SAPProtoNumber(fields,1,0));out[@"free_licenses"]=@(SAPProtoNumber(fields,2,0));out[@"error_code"]=@(SAPProtoNumber(fields,3,0));}
    else if([method isEqual:@"GetOfflinePlaybackStatus"]||[method isEqual:@"SubscribeOfflinePlaybackStatus"]){
        out[@"allowed"]=@(SAPProtoNumber(fields,1,0)!=0);out[@"explicitly_enabled"]=@(SAPProtoNumber(fields,2,0)!=0);out[@"implicitly_enabled"]=@(SAPProtoNumber(fields,3,0)!=0);
    }else if([method isEqual:@"GetItems"]||[method isEqual:@"SubscribeItems"])out[@"items"]=itemSummary(fields,1,256);
    else if([method isEqual:@"GetTotalProgress"]||[method isEqual:@"SubscribeTotalProgress"])out[@"progress"]=progressSummary(SAPProtoFields(SAPProtoData(fields,1)));
    else if([method isEqual:@"GetContexts"]||[method isEqual:@"SubscribeContexts"]||[method isEqual:@"GetContextsProgress"]||[method isEqual:@"SubscribeContextsProgress"]){
        NSMutableArray *contexts=[NSMutableArray array];BOOL progress=[method hasSuffix:@"Progress"];
        for(NSDictionary *f in fields) {
            if([f[@"number"]unsignedIntValue]!=1||[f[@"wire"]unsignedIntValue]!=2)continue;
            if(contexts.count==32){out[@"contexts_truncated"]=@YES;break;}
            NSArray *info=SAPProtoFields(f[@"value"]),*context=progress?info:SAPProtoFields(SAPProtoData(info,1));NSString *s=uri(context,1);
            if(!s)continue;
            [contexts addObject:progress?@{@"uri":s,@"progress":progressSummary(SAPProtoFields(SAPProtoData(info,2)))}:
                @{@"uri":s,@"state":@(SAPProtoNumber(context,2,0)),@"percent":@(floatValue(context,3)),@"items":itemSummary(info,2,16)}];
        }
        out[@"contexts"]=contexts;
    }else if([method isEqual:@"BulkRedownloadPreflight"]){
        out[@"preflight"]=@{@"total_download_bytes":@(SAPProtoNumber(fields,1,0)),@"total_tracks":@(SAPProtoNumber(fields,2,0)),
            @"is_on_cellular":@(SAPProtoNumber(fields,3,0)!=0),@"sync_over_cellular_allowed":@(SAPProtoNumber(fields,4,0)!=0),
            @"has_sufficient_storage":@(SAPProtoNumber(fields,5,0)!=0),@"downloads_in_progress":@(SAPProtoNumber(fields,6,0)),@"current_downloaded_bytes":@(SAPProtoNumber(fields,7,0))};
    }else if([method isEqual:@"SubscribeContextAdded"]){out[@"uri"]=uri(fields,1)?:NSNull.null;out[@"reason"]=@(SAPProtoNumber(fields,2,0));}
    else out[@"values_decoded"]=@NO;
    return out;
}

@interface SAPTraceRPC () { @public atomic_bool _finished,_timedOut;atomic_uint _messages; }
@property(nonatomic) SAPTraceID identifier,parent;
@property(nonatomic) uint64_t generation,started;
@property(nonatomic) BOOL stream;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,copy) NSString *method,*service;
@property(nonatomic,copy) NSString *requestURI;
@property(nonatomic,weak) id lifetime;
@end
@implementation SAPTraceRPC
- (instancetype)init {if((self=[super init])){atomic_init(&_finished,false);atomic_init(&_timedOut,false);atomic_init(&_messages,0);}return self;}
@end
static void closeRPCsThroughGeneration(uint64_t closing) {
    for(SAPTraceRPC *call in [rpcCalls copy])if(call.generation<=closing)SAPTraceRPCStreamEnd(call,@"diagnostics_disabled");
}
static void rpcEvent(SAPTraceRPC *call,const char *stage,NSDictionary *facts) {
    if(!call||call.generation!=atomic_load(&generation)||!SAPTraceIsActive())return;
    NSMutableDictionary *value=[facts mutableCopy];value[@"service"]=call.service;value[@"method"]=call.method;value[@"request_parent_operation_id"]=call.parent?@(call.parent):NSNull.null;
    value[@"elapsed_ms"]=@(seconds(mach_continuous_time()-call.started)*1000);SAPTraceEvent("rpc",stage,call.identifier,value);
}
static void releaseRPC(SAPTraceRPC *call) {
    if(!atomic_exchange(&call->_finished,true)){
        @synchronized(call){if(call.deadline){dispatch_source_cancel(call.deadline);call.deadline=nil;}}
        id lifetime=call.lifetime;if(lifetime&&objc_getAssociatedObject(lifetime,&lifetimeTraceKey)==call)objc_setAssociatedObject(lifetime,&lifetimeTraceKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);call.lifetime=nil;
        atomic_fetch_sub(&rpcPending,1);
        dispatch_async(writer,^{[rpcCalls removeObject:call];});
    }
}
static os_unfair_lock lifetimeLock=OS_UNFAIR_LOCK_INIT;
static _Thread_local void *lifetimeReceiver;
static _Thread_local SEL lifetimeSelector;
static Class lifetimeClasses[32];
static unsigned lifetimeClassCount;
static void bindLifetime(SAPTraceRPC *call,id lifetime) {
    if(!lifetime||!SAPTraceIsActive()||atomic_load(&call->_finished))return;
    call.lifetime=lifetime;objc_setAssociatedObject(lifetime,&lifetimeTraceKey,call,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(atomic_load(&call->_finished)){if(objc_getAssociatedObject(lifetime,&lifetimeTraceKey)==call)objc_setAssociatedObject(lifetime,&lifetimeTraceKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);call.lifetime=nil;return;}
    Class cls=object_getClass(lifetime);os_unfair_lock_lock(&lifetimeLock);
    for(unsigned i=0;i<lifetimeClassCount;i++)if(lifetimeClasses[i]==cls){os_unfair_lock_unlock(&lifetimeLock);return;}
    if(lifetimeClassCount==32){os_unfair_lock_unlock(&lifetimeLock);atomic_fetch_add(&lifetimeCapacityDrops,1);SAP_TRACE("rpc","lifetime_hook_capacity_reached",call.identifier,@{});return;}
    lifetimeClasses[lifetimeClassCount++]=cls;
    for(NSString *name in @[@"acquire",@"cancel"]){SEL selector=NSSelectorFromString(name);Method method=class_getInstanceMethod(cls,selector);char type[16]={0};
        if(!method||method_getNumberOfArguments(method)!=2)continue;method_getReturnType(method,type,sizeof(type));if(type[0]!='v')continue;
        IMP original=method_getImplementation(method);BOOL cancels=[name isEqual:@"cancel"];
        IMP replacement=imp_implementationWithBlock(^(id receiver){
            void *previousReceiver=lifetimeReceiver;SEL previousSelector=lifetimeSelector;
            BOOL nested=previousReceiver==(__bridge void *)receiver&&previousSelector==selector;
            lifetimeReceiver=(__bridge void *)receiver;lifetimeSelector=selector;
            @try {
                SAPTraceRPC *bound=!nested&&SAPTraceIsActive()?objc_getAssociatedObject(receiver,&lifetimeTraceKey):nil;
                if(bound){SAPTraceHookCalled(object_getClass(receiver),selector);rpcEvent(bound,cancels?"lifetime_cancel_invoked":"lifetime_acquire_invoked",@{});if(cancels)SAPTraceRPCStreamEnd(bound,@"native_lifetime_cancel_invoked");}
                ((void(*)(id,SEL))original)(receiver,selector);
            }@finally {lifetimeReceiver=previousReceiver;lifetimeSelector=previousSelector;}
        });
        if(!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method)))class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));
        SAPTraceRegisterHook(cls,selector,replacement,original);
    }
    os_unfair_lock_unlock(&lifetimeLock);
}
static BOOL noisyService(NSString *service) {
    return [service isKindOfClass:NSString.class]&&[service isEqual:@"spotify.connectivity.traffic.esperanto.proto.TrafficAdapter"];
}
BOOL SAPTraceRepeatedProgressPayload(NSString *scope,NSString *method,SAPTraceID operation,id payload) {
    if(!SAPTraceIsActive()||![payload isKindOfClass:NSData.class]||![method isKindOfClass:NSString.class])return NO;
    if(![method isEqual:@"SubscribeContextsProgress"]&&![method isEqual:@"SubscribeTotalProgress"]&&![method isEqual:@"SubscribeBulkRedownloadProgress"])return NO;
    NSString *key=[NSString stringWithFormat:@"%@:%@:%llu",scope,method,(unsigned long long)operation];BOOL same=NO;
    os_unfair_lock_lock(&repeatLock);
    uint64_t current=SAPTraceGeneration();
    if(!repeatPayloads||repeatGeneration!=current){repeatPayloads=[NSMutableDictionary dictionary];repeatGeneration=current;}
    NSData *previous=repeatPayloads[key];same=previous&&[previous isEqualToData:payload];
    if(!same){if(repeatPayloads.count>=128)[repeatPayloads removeAllObjects];repeatPayloads[key]=[payload copy];}
    os_unfair_lock_unlock(&repeatLock);
    if(same)atomic_fetch_add(&suppressedRepeats,1);
    return same;
}
SAPTraceRPC *SAPTraceRPCBegin(NSString *service,NSString *method,NSData *payload,NSString *source,id endpoint,BOOL isStream) {
    if(!SAPTraceIsActive())return nil;
    if(noisyService(service)){atomic_fetch_add(&suppressedTraffic,1);return nil;}
    if(atomic_fetch_add(&rpcPending,1)>=maximumRPC){atomic_fetch_sub(&rpcPending,1);atomic_fetch_add(&rpcCapacityDrops,1);return nil;}
    SAPTraceRPC *call=[SAPTraceRPC new];call.identifier=atomic_fetch_add(&identifiers,1)+1;call.parent=currentOperation;
    call.generation=atomic_load(&generation);call.started=mach_continuous_time();call.stream=isStream;call.service=[service isKindOfClass:NSString.class]?service:@"unknown";call.method=[method isKindOfClass:NSString.class]?method:@"unknown";
    if([call.service isEqual:@"spotify.metadata_esperanto.proto.ClassicMetadataService"]&&[payload isKindOfClass:NSData.class]&&payload.length<4096)call.requestURI=uri(SAPProtoFields(payload),1);
    rpcEvent(call,"invocation",@{@"source":source?:@"unknown",@"transport":NSStringFromClass(object_getClass(endpoint))?:@"unknown",@"stream":@(isStream),@"request":SAPTraceWireSummary(call.service,call.method,payload,NO)});
    dispatch_async(writer,^{
        if(call.generation!=atomic_load(&generation)||!SAPTraceIsActive()){releaseRPC(call);return;}
        [rpcCalls addObject:call];if(isStream||atomic_load(&call->_finished))return;
        dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,writer);
        dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(rpcTimeout*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,0);
        __weak SAPTraceRPC *weak=call;
        dispatch_source_set_event_handler(timer,^{SAPTraceRPC *c=weak;if(!c||atomic_load(&c->_finished))return;
            @synchronized(c){
                if(atomic_load(&c->_finished)||atomic_load(&c->_messages)>0)return;
                atomic_store(&c->_timedOut,true);rpcEvent(c,"reply_not_observed",@{@"threshold_seconds":@(rpcTimeout),@"command_replayed":@NO,@"request_rejected":NSNull.null});releaseRPC(c);
            }});
        @synchronized(call){if(atomic_load(&call->_finished)){dispatch_source_cancel(timer);dispatch_resume(timer);return;}call.deadline=timer;dispatch_resume(timer);}
    });return call;
}
void SAPTraceRPCReturned(SAPTraceRPC *call,id lifetime) {if(!call||!SAPTraceIsActive()||call.generation!=SAPTraceGeneration())return;rpcEvent(call,"invocation_returned",@{@"lifetime_returned":@(lifetime!=nil),@"lifetime_class":lifetime?NSStringFromClass(object_getClass(lifetime)):@"none"});bindLifetime(call,lifetime);}
void SAPTraceRPCReply(SAPTraceRPC *call,id response) {
    if(!call||!SAPTraceIsActive()||call.generation!=SAPTraceGeneration())return;
    @synchronized(call){
    unsigned message=atomic_fetch_add(&call->_messages,1)+1;
    if(!(call.stream&&!atomic_load(&call->_timedOut)&&SAPTraceRepeatedProgressPayload(@"rpc",call.method,call.identifier,response)))
    rpcEvent(call,atomic_load(&call->_timedOut)?"late_callback":(!call.stream&&message>1?"duplicate_callback":atomic_load(&call->_finished)?"callback_after_observation_end":"callback"),
        @{@"message":@(message),@"response":SAPTraceWireSummary(call.service,call.method,response,YES),@"body_is_data":@([response isKindOfClass:NSData.class]),@"server_origin_proven":@NO});
    extern void SAPNativeKeyTraceObserveMetadata(NSString *,NSString *,NSString *,NSData *) __attribute__((weak_import));
    if(SAPTraceIsActive()&&call.generation==SAPTraceGeneration()&&SAPNativeKeyTraceObserveMetadata)
        SAPTraceWithOperation(call.identifier,^{SAPNativeKeyTraceObserveMetadata(call.service,call.method,call.requestURI,response);});
    if(!call.stream)releaseRPC(call);
    }
}
void SAPTraceRPCException(SAPTraceRPC *call,NSException *exception) {if(call){rpcEvent(call,"exception",@{@"name":exception.name?:@"unknown"});releaseRPC(call);}}
void SAPTraceRPCStreamEnd(SAPTraceRPC *call,NSString *reason) {if(call){rpcEvent(call,"observation_ended",@{@"reason":reason?:@"unknown",@"messages":@(atomic_load(&call->_messages))});releaseRPC(call);}}
#ifdef SAP_TESTING
void SAPTraceTestConfigure(NSURL *url,NSUInteger bytes,NSUInteger limit,double timeout) {directory=url;maximumBytes=bytes;pendingLimit=limit;rpcTimeout=timeout;}
void SAPTraceTestDrain(void) {SAPTraceFlush();}
void SAPTraceTestSetResetObserver(dispatch_block_t observer) {resetObserver=[observer copy];}
#endif
