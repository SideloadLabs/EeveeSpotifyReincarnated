#import "OfflineConfig.h"
#import "OfflineLimits.h"
#import "WireProto.h"
#import "DiagnosticTrace.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>

static atomic_uint_fast64_t requests, patched, unchanged, oversized, failedTasks, emptyTasks;
static atomic_uint_fast64_t cachedBodies, cachedChanges, responses304;
static atomic_uint_fast64_t reentrantBodies,reentrantChanges;
// Vitrine delivers a complete synthesized body synchronously from its response
// and completion handlers. Re-buffering that delivery would consume the body
// without ever passing it to Spotify. This marks only the current task/call.
static _Thread_local const void *forwardingTask;
static NSArray *installed;
static char bufferKey, bypassKey;
static char taskKindKey;
@interface SAPHTTPTaskKind : NSObject
@property(nonatomic,strong) NSURL *url;
@property(nonatomic) int kind;
@property(nonatomic) SAPTraceID traceID;
@property(nonatomic) uint64_t traceSegment;
@end
@implementation SAPHTTPTaskKind @end
static const NSUInteger maximumBody = 4 * 1024 * 1024;
static NSString *const cacheKey = @"eeveeCachedCustomizeData";

static NSDictionary *flags(void) {
    return @{@"offline": @1, @"can-use-offline": @1,
             @"max-offline-downloads-per-device": @(SAPMinimumTrackLimit), @"max-offline-tracks": @(SAPMinimumTrackLimit)};
}
static NSData *rewriteAttributes(NSData *data) {
    NSArray *fields = SAPProtoFields(data); if (!fields) return nil;
    NSMutableData *result = [NSMutableData data];
    NSMutableSet *seen = [NSMutableSet set];
    NSDictionary *forced = flags();
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] != 1 || [field[@"wire"] unsignedIntValue] != 2) {
            [result appendData:field[@"raw"]]; continue;
        }
        NSArray *entry = SAPProtoFields(field[@"value"]); if (!entry) return nil;
        NSString *key = SAPProtoString(entry, 1);
        NSNumber *value = key ? forced[key] : nil;
        if (!value) { [result appendData:field[@"raw"]]; continue; }
        [seen addObject:key];
        NSData *old = SAPProtoData(entry, 2);
        NSArray *attribute = old ? SAPProtoFields(old) : @[]; if (!attribute) return nil;
        unsigned type = value.unsignedIntValue == 1 ? 2 : 3;
        for (NSDictionary *part in attribute) {
            unsigned number = [part[@"number"] unsignedIntValue];
            if (number >= 2 && number <= 4) type = number;
        }
        NSMutableData *replacement = [NSMutableData data];
        for (NSDictionary *part in attribute) {
            unsigned number = [part[@"number"] unsignedIntValue];
            if (number < 2 || number > 4) [replacement appendData:part[@"raw"]];
        }
        [replacement appendData:type == 4 ? SAPProtoBytes(4, [value.stringValue dataUsingEncoding:NSUTF8StringEncoding]) : SAPProtoInteger(type, value.unsignedLongLongValue)];
        NSMutableData *newEntry = [NSMutableData data];
        for (NSDictionary *part in entry) if ([part[@"number"] unsignedIntValue] != 2) [newEntry appendData:part[@"raw"]];
        [newEntry appendData:SAPProtoBytes(2, replacement)];
        [result appendData:SAPProtoBytes(1, newEntry)];
    }
    for (NSString *key in [[forced allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([seen containsObject:key]) continue;
        NSNumber *value = forced[key];
        NSMutableData *entry = [SAPProtoBytes(1, [key dataUsingEncoding:NSUTF8StringEncoding]) mutableCopy];
        [entry appendData:SAPProtoBytes(2, SAPProtoInteger(value.unsignedIntValue == 1 ? 2 : 3, value.unsignedLongLongValue))];
        [result appendData:SAPProtoBytes(1, entry)];
    }
    return result;
}
static NSData *rewritePath(NSData *data, const unsigned *path, unsigned count, BOOL *found) {
    if (!count) { *found = YES; return rewriteAttributes(data); }
    NSArray *fields = SAPProtoFields(data); if (!fields) return nil;
    NSMutableData *result = [NSMutableData data];
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] == path[0] && [field[@"wire"] unsignedIntValue] == 2) {
            NSData *nested = rewritePath(field[@"value"], path + 1, count - 1, found);
            if (!nested) return nil;
            [result appendData:SAPProtoBytes(path[0], nested)];
        } else [result appendData:field[@"raw"]];
    }
    return result;
}
static NSDictionary *observedFlags(NSData *data,BOOL bootstrap) {
    const unsigned a[]={2,1,1,1,3},b[]={1,3};const unsigned *path=bootstrap?a:b;unsigned count=bootstrap?5:2;
    for(unsigned i=0;i<count;i++){data=SAPProtoData(SAPProtoFields(data),path[i]);if(!data)return @{@"recognized":@NO};}
    NSMutableDictionary *out=[NSMutableDictionary dictionary];
    for(NSDictionary *f in SAPProtoFields(data)) {
        if([f[@"number"]unsignedIntValue]!=1||[f[@"wire"]unsignedIntValue]!=2)continue;
        NSArray *entry=SAPProtoFields(f[@"value"]);NSString *key=SAPProtoString(entry,1);if(!key||!flags()[key])continue;
        NSArray *value=SAPProtoFields(SAPProtoData(entry,2));
        NSString *text=SAPProtoString(value,4);out[key]=text?:@(SAPProtoNumber(value,3,SAPProtoNumber(value,2,0)));
    }
    return @{@"recognized":@YES,@"attributes":out};
}
NSData *SAPRewriteOfflineConfig(NSData *data, BOOL bootstrap) {
    // Account.pb.swift: Bootstrap[2][1][1].Customize[1].Ucs[3].Attributes(map[1]).
    const unsigned bootstrapPath[] = {2, 1, 1, 1, 3}, customizePath[] = {1, 3};
    BOOL found = NO;
    NSData *result = rewritePath(data, bootstrap ? bootstrapPath : customizePath, bootstrap ? 5 : 2, &found);
    SAP_TRACE("config","transform_result",SAPTraceCurrentOperation(),@{@"schema":bootstrap?@"bootstrap":@"customize",@"path_found":@(found),
        @"before":observedFlags(data,bootstrap),@"after":observedFlags(found&&result?result:data,bootstrap),@"bytes_changed":@(found&&result&&![result isEqual:data]),
        @"origin":@"input_at_transform_boundary",@"server_origin_proven":@NO,@"native_consumption_confirmed":@NO});
    return found && result ? result : data;
}
BOOL SAPPrepareCachedOfflineConfig(NSUserDefaults *defaults) {
    // This is the exact cache key used by Eevee's 304 replay. No preference-wide
    // getter hook, cache deletion, account field change or periodic refresh.
    NSData *data = [defaults dataForKey:cacheKey];
    SAP_TRACE("config","cached_customize_observed",SAPTraceCurrentOperation(),@{@"cache_key":cacheKey,@"bytes":@(data.length),@"origin":@"local_cache",@"server_origin_proven":@NO});
    if (!data || data.length > maximumBody) return NO;
    atomic_fetch_add(&cachedBodies, 1);
    NSData *rewritten = SAPRewriteOfflineConfig(data, NO);
    if ([rewritten isEqual:data]) return NO;
    if (![defaults dataForKey:@"SAPOriginalCustomizeBeforeOfflineFlags"])
        [defaults setObject:data forKey:@"SAPOriginalCustomizeBeforeOfflineFlags"];
    [defaults setObject:rewritten forKey:cacheKey];
    SAP_TRACE("config","cache_write_returned",SAPTraceCurrentOperation(),@{@"cache_key":cacheKey,@"readback_matches":@([[defaults dataForKey:cacheKey]isEqual:rewritten]),@"origin":@"local_cache"});
    atomic_fetch_add(&cachedChanges, 1);
    return YES;
}
static int taskKind(NSURLSessionTask *task) {
    NSURL *url = task.currentRequest.URL ?: task.originalRequest.URL;
    SAPHTTPTaskKind *cached=objc_getAssociatedObject(task,&taskKindKey);
    if(cached && [cached.url isEqual:url]) {
        if(cached.kind&&SAPTraceIsActive())@synchronized(task){if(cached.traceSegment!=SAPTraceGeneration()){
            cached.traceSegment=SAPTraceGeneration();cached.traceID=SAPTraceBegin(@"configuration_http_task",@"spotify_delegate",@{@"host":url.host?:@"",@"path":url.path?:@"",@"request_start_observed":@NO});}}
        return cached.kind;
    }
    NSString *host = url.host.lowercaseString;
    int kind=0;
    if([host isEqual:@"spotify.com"] || [host hasSuffix:@".spotify.com"]) {
        if([url.path containsString:@"/v1/bootstrap"])kind=1;
        else if([url.path containsString:@"/v1/customize"])kind=2;
    }
    SAPHTTPTaskKind *value=[SAPHTTPTaskKind new];value.url=url;value.kind=kind;
    value.traceID=cached.traceSegment==SAPTraceGeneration()?cached.traceID:0;value.traceSegment=SAPTraceGeneration();
    if((kind||value.traceID)&&SAPTraceIsActive()) {
        if(!value.traceID)value.traceID=SAPTraceBegin(@"configuration_http_task",@"spotify_delegate",@{@"host":url.host?:@"",@"path":url.path?:@"",@"request_start_observed":@NO});
        else SAP_TRACE("http","task_url_changed",value.traceID,@{@"previous_host":cached.url.host?:@"",@"previous_path":cached.url.path?:@"",@"host":url.host?:@"",@"path":url.path?:@"",@"redirect_callback_observed":@NO});
    }
    objc_setAssociatedObject(task,&taskKindKey,value,OBJC_ASSOCIATION_RETAIN);
    return kind;
}
static BOOL signature(Class cls, SEL sel, unsigned arguments, Method *method) {
    *method = class_getInstanceMethod(cls, sel); if (!*method || method_getNumberOfArguments(*method) != arguments) return NO;
    char type[16]; method_getReturnType(*method, type, sizeof(type)); return type[0] == 'v';
}
void SAPInstallOfflineConfig(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SAPPrepareCachedOfflineConfig(NSUserDefaults.standardUserDefaults);
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *name in @[@"SPTDataLoaderService", @"Connectivity_HttpClientKit.HttpClientURLSession", @"SPTCoreURLSessionDataDelegate"]) {
            Class cls = NSClassFromString(name); Method dataMethod, completeMethod;
            SEL dataSel = NSSelectorFromString(@"URLSession:dataTask:didReceiveData:"), completeSel = NSSelectorFromString(@"URLSession:task:didCompleteWithError:");
            if (!signature(cls, dataSel, 5, &dataMethod) || !signature(cls, completeSel, 5, &completeMethod)) continue;
            IMP originalData = method_getImplementation(dataMethod), originalComplete = method_getImplementation(completeMethod);
            // Per-task storage has no timer and is released on completion or task destruction.
            IMP dataHook = imp_implementationWithBlock(^(id self, id session, NSURLSessionTask *task, NSData *data) {
                int kind=taskKind(task);
                if(kind){SAPTraceHookCalled(object_getClass(self),dataSel);SAP_TRACE("http","data_chunk",((SAPHTTPTaskKind *)objc_getAssociatedObject(task,&taskKindKey)).traceID,@{@"bytes":@(data.length),@"origin":@"delegate_input_may_already_be_rewritten_by_other_hooks"});}
                if (!kind || ![data isKindOfClass:NSData.class]) {
                    ((void (*)(id, SEL, id, id, id))originalData)(self, dataSel, session, task, data); return;
                }
                if(forwardingTask==(__bridge const void *)task) {
                    __block NSData *replacement=data;
                    SAPTraceWithOperation(((SAPHTTPTaskKind *)objc_getAssociatedObject(task,&taskKindKey)).traceID,^{if(data.length<=maximumBody)replacement=SAPRewriteOfflineConfig(data,kind==1);});
                    atomic_fetch_add(&reentrantBodies,1);
                    if(![replacement isEqual:data])atomic_fetch_add(&reentrantChanges,1);
                    ((void (*)(id, SEL, id, id, id))originalData)(self,dataSel,session,task,replacement);
                    return;
                }
                @synchronized(task) {
                    if (objc_getAssociatedObject(task, &bypassKey)) {
                        ((void (*)(id, SEL, id, id, id))originalData)(self, dataSel, session, task, data); return;
                    }
                    NSMutableData *body = objc_getAssociatedObject(task, &bufferKey);
                    if (!body) { body = [NSMutableData data]; objc_setAssociatedObject(task, &bufferKey, body, OBJC_ASSOCIATION_RETAIN_NONATOMIC); atomic_fetch_add(&requests, 1); }
                    if (data.length > maximumBody - body.length) {
                        atomic_fetch_add(&oversized, 1);
                        objc_setAssociatedObject(task, &bypassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        objc_setAssociatedObject(task, &bufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        if (body.length) ((void (*)(id, SEL, id, id, id))originalData)(self, dataSel, session, task, body);
                        ((void (*)(id, SEL, id, id, id))originalData)(self, dataSel, session, task, data);
                    } else [body appendData:data];
                }
            });
            IMP completeHook = imp_implementationWithBlock(^(id self, id session, NSURLSessionTask *task, NSError *error) {
                int kind = taskKind(task);
                SAPHTTPTaskKind *traceTask=objc_getAssociatedObject(task,&taskKindKey);
                if(kind){SAPTraceHookCalled(object_getClass(self),completeSel);SAP_TRACE("http","task_completed",traceTask.traceID,@{@"http_status":[task.response isKindOfClass:NSHTTPURLResponse.class]?@([(NSHTTPURLResponse *)task.response statusCode]):NSNull.null,@"error_domain":error.domain?:@"",@"error_code":@(error.code)});}
                if (kind) @synchronized(task) {
                    NSData *body = objc_getAssociatedObject(task, &bufferKey);
                    if (body) {
                        NSData *replacement = body;
                        if (!error && [task.response isKindOfClass:NSHTTPURLResponse.class] && [(NSHTTPURLResponse *)task.response statusCode] == 200) {
                            __block NSData *rewritten;
                            SAPTraceWithOperation(traceTask.traceID,^{rewritten=SAPRewriteOfflineConfig(body,kind==1);});replacement=rewritten;
                            atomic_fetch_add([replacement isEqual:body] ? &unchanged : &patched, 1);
                        } else atomic_fetch_add(&failedTasks, 1);
                        objc_setAssociatedObject(task, &bufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        ((void (*)(id, SEL, id, id, id))originalData)(self, dataSel, session, task, replacement);
                    } else if (!objc_getAssociatedObject(task, &bypassKey)) atomic_fetch_add(&emptyTasks, 1);
                    objc_setAssociatedObject(task, &bypassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                const void *previousTask=forwardingTask;forwardingTask=(__bridge const void *)task;
                @try {((void (*)(id, SEL, id, id, id))originalComplete)(self, completeSel, session, task, error);}
                @finally {forwardingTask=previousTask;}
            });
            class_replaceMethod(cls, dataSel, dataHook, method_getTypeEncoding(dataMethod));
            class_replaceMethod(cls, completeSel, completeHook, method_getTypeEncoding(completeMethod));
            SAPTraceRegisterHook(cls,dataSel,dataHook,originalData);SAPTraceRegisterHook(cls,completeSel,completeHook,originalComplete);
            SEL responseSel = NSSelectorFromString(@"URLSession:dataTask:didReceiveResponse:completionHandler:");
            Method responseMethod;
            if (signature(cls, responseSel, 6, &responseMethod)) {
                IMP originalResponse = method_getImplementation(responseMethod);
                IMP responseHook = imp_implementationWithBlock(^(id self, id session, NSURLSessionTask *task, NSURLResponse *response, id handler) {
                    int traceKind=taskKind(task);
                    if(traceKind){SAPTraceHookCalled(object_getClass(self),responseSel);SAP_TRACE("http","response_headers_observed",((SAPHTTPTaskKind *)objc_getAssociatedObject(task,&taskKindKey)).traceID,@{@"http_status":[response isKindOfClass:NSHTTPURLResponse.class]?@([(NSHTTPURLResponse *)response statusCode]):NSNull.null,@"headers_recorded":@NO,@"cached_body_expected":@([response isKindOfClass:NSHTTPURLResponse.class]&&[(NSHTTPURLResponse *)response statusCode]==304)});}
                    if (taskKind(task) == 2 && [response isKindOfClass:NSHTTPURLResponse.class]
                        && [(NSHTTPURLResponse *)response statusCode] == 304) {
                        atomic_fetch_add(&responses304, 1); SAPPrepareCachedOfflineConfig(NSUserDefaults.standardUserDefaults);
                    }
                    const void *previousTask=forwardingTask;forwardingTask=(__bridge const void *)task;
                    @try {((void (*)(id, SEL, id, id, id, id))originalResponse)(self, responseSel, session, task, response, handler);}
                    @finally {forwardingTask=previousTask;}
                });
                class_replaceMethod(cls, responseSel, responseHook, method_getTypeEncoding(responseMethod));
                SAPTraceRegisterHook(cls,responseSel,responseHook,originalResponse);
            }
            [names addObject:name];
        }
        installed = [names copy];
    });
}
NSDictionary *SAPOfflineConfigReport(void) {
    return @{@"delegates": installed ?: @[], @"requests": @(atomic_load(&requests)), @"patched": @(atomic_load(&patched)),
        @"unchanged_or_unrecognized": @(atomic_load(&unchanged)), @"oversized_passthrough": @(atomic_load(&oversized)),
        @"error_passthrough": @(atomic_load(&failedTasks)), @"no_body": @(atomic_load(&emptyTasks)),
        @"cached_bodies_seen": @(atomic_load(&cachedBodies)), @"cached_bodies_changed": @(atomic_load(&cachedChanges)),
        @"responses_304": @(atomic_load(&responses304)),
        @"reentrant_bodies":@(atomic_load(&reentrantBodies)),@"reentrant_changes":@(atomic_load(&reentrantChanges))};
}
