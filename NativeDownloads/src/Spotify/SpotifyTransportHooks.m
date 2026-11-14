#import "SpotifyTransport.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#include <stdatomic.h>

static atomic_uint nativeWatches,nativeWatchesDropped;
static _Thread_local unsigned offlineHookDepth,playerHookDepth,traceHookDepth;

// Observe unanswered application calls without retaining the app's lifetime or
// replaying its commands. Streams may legitimately stay quiet and are not watched.
@interface SAPNativeCallWatch : NSObject { atomic_bool _finished; }
@property(nonatomic,strong) dispatch_source_t deadline;
- (BOOL)finish;
@end
@implementation SAPNativeCallWatch
- (instancetype)init {if((self=[super init]))atomic_init(&_finished,false);return self;}
- (BOOL)finish {
    if(atomic_exchange(&_finished,true))return NO;
    if(_deadline)dispatch_source_cancel(_deadline);_deadline=nil;atomic_fetch_sub(&nativeWatches,1);
    return YES;
}
@end
static SAPNativeCallWatch *watchNativeCall(NSString *method,NSData *payload,id endpoint) {
    if(atomic_fetch_add(&nativeWatches,1)>=64) {atomic_fetch_sub(&nativeWatches,1);atomic_fetch_add(&nativeWatchesDropped,1);return nil;}
    SAPNativeCallWatch *watch=[SAPNativeCallWatch new];
    NSString *channel=NSStringFromClass(object_getClass(endpoint));
    NSArray *fields=payload.length<=1048576?SAPProtoFields(payload):nil;
    unsigned field=[method isEqual:@"AddDownload"] || [method isEqual:@"RemoveDownload"]?2:[method isEqual:@"GetContexts"]?3:1;
    NSString *uri=SAPProtoString(fields,field);
#ifdef SAP_TESTING
    int64_t watchDelay=(int64_t)(0.03*NSEC_PER_SEC);
#else
    int64_t watchDelay=4*NSEC_PER_SEC;
#endif
    watch.deadline=SAPScheduleDeadline(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),(double)watchDelay/NSEC_PER_SEC,^{
        BOOL unanswered=[watch finish];
        if(unanswered)SAPJournalNoteCallIssue(method,uri,channel,@"application single call has not replied after 4 seconds; not replayed");
    });
    return watch;
}
static void putHook(Class cls, SEL sel, Method method, id block, NSMutableArray *names) {
    IMP previous=method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    [names addObject:[NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)]];
    SAPTraceRegisterHook(cls,sel,replacement,previous);
}
NSArray *SAPInstallSpotifyTransportHooks(void) {
    NSMutableArray *names=[NSMutableArray array];Method method;
        Class cls = NSClassFromString(@"SPTEsperantoPlayer");
        SEL sel = NSSelectorFromString(@"addPlayerObserver:");
        if (SAPTransportSignature(cls, sel, 3, 'v', &method)) {
            IMP original = method_getImplementation(method);
            putHook(cls, sel, method, ^(id self, id observer) { SAPTransportSetPlayer(self); ((void (*)(id, SEL, id))original)(self, sel, observer); }, names);
        }
        for (NSString *name in @[@"fetchState:on:", @"globalPlayerSubscription:gotStateUpdate:"]) {
            SEL command = NSSelectorFromString(name);
            if (!SAPTransportSignature(cls, command, 4, 'v', &method)) continue;
            IMP original = method_getImplementation(method);
            putHook(cls, command, method, ^(id self, id first, id second) {
                SAPTransportSetPlayer(self); ((void (*)(id, SEL, id, id))original)(self, command, first, second);
                if (SAPDiagnosticsEnabled() && [name isEqual:@"globalPlayerSubscription:gotStateUpdate:"]) SAPObservePlayerState(second);
            }, names);
        }
        for (NSString *name in @[@"SPTEsperantoTransportBridgeImpl", @"SPTEsperantoCosmosTransport"]) {
            cls = NSClassFromString(name);
            for (NSString *commandName in @[@"callSingle:method:payload:onResponse:", @"callStream:method:payload:onResponse:"]) {
                SEL command = NSSelectorFromString(commandName);
                if (!SAPTransportSignature(cls, command, 6, '@', &method)) continue;
                IMP original = method_getImplementation(method);
                putHook(cls, command, method, ^id(id self, id serviceName, id methodName, id payload, id callback) {
                    SAPRememberTransport(self, NO, NO);
#ifdef SAP_RUNTIME_TESTING
                    SAPRememberNativeCall(self, serviceName, methodName);
#endif
                    BOOL offline=[serviceName isKindOfClass:NSString.class] && [serviceName isEqual:SAPOfflineService];
                    BOOL read=[methodName isKindOfClass:NSString.class] && ([methodName hasPrefix:@"Get"] || [methodName hasPrefix:@"Subscribe"]);
                    // Stock Offline responses prove this service's route even
                    // when logging is off. Pixie reads learn only after their
                    // own cancellation/attempt checks in SpotifyServiceCalls.
                    if(offline && read && !offlineHookDepth && !SAPOnTransportWorker() && callback) {
                        __weak id endpoint=self;
                        NSString *service=[serviceName copy],*method=[methodName copy];
                        // A subscription replies many times but proves its route
                        // once; later emissions skip the registry entirely.
                        __block _Atomic(BOOL) learned=NO;
                        BOOL (^prove)(NSData *)=^BOOL(NSData *data){
                            if(![data isKindOfClass:NSData.class] || atomic_exchange(&learned,YES))return NO;
                            SAPRememberReadOnlyTransport(endpoint,service,method);return YES;
                        };
                        if([commandName hasPrefix:@"callSingle:"]) {
                            void (^next)(NSData *)=callback;
                            callback=^(NSData *data){prove(data);next(data);};
                        } else {
                            BOOL (^next)(NSData *)=callback;
                            callback=^BOOL(NSData *data){prove(data);return next(data);};
                        }
                    }
                    if(!SAPDiagnosticsEnabled()) {
                        if(offline)offlineHookDepth++;
                        @try {return ((id (*)(id,SEL,id,id,id,id))original)(self,command,serviceName,methodName,payload,callback);}
                        @finally {if(offline)offlineHookDepth--;}
                    }
                    SAPTraceHookCalled(object_getClass(self),command);
                    SAPTraceRPC *trace=traceHookDepth==0?SAPTraceRPCBegin(serviceName,methodName,payload,
                        SAPJournalOnOwnQueue()?@"pixie_diagnostic_query":SAPOnTransportWorker()?@"pixie_service":@"spotify",self,[commandName hasPrefix:@"callStream:"]):nil;
                    BOOL playerCall=[serviceName isKindOfClass:NSString.class] && [serviceName isEqual:@"spotify.player.esperanto.proto.ContextPlayer"];
                    if(SAPDiagnosticsEnabled() && playerCall && playerHookDepth==0)SAPTraceWithOperation(trace?trace.identifier:SAPTraceCurrentOperation(),^{SAPObservePlayerRequest(serviceName,methodName,payload);});
                    BOOL outer=offlineHookDepth==0, own=SAPJournalOnOwnQueue();
                    BOOL menu=SAPOnTransportWorker();
                    if (SAPDiagnosticsEnabled() && offline && outer && !own && callback) {
                        __weak id endpoint = self;
                        // Observe Offline calls from Pixie and Spotify without changing replies.
                        NSString *observed = [methodName isKindOfClass:NSString.class] ? [methodName copy] : nil;
                        NSData *sent = [payload isKindOfClass:NSData.class] ? [payload copy] : nil;
                        NSString *origin = [NSString stringWithFormat:@"%@:%@", menu ? @"menu" : @"app",
                            NSStringFromClass(object_getClass(self))];
                        if ([commandName hasPrefix:@"callSingle:"]) {
                            void (^originalCallback)(NSData *) = callback;
                            SAPNativeCallWatch *watch=!menu && observed?watchNativeCall(observed,sent,self):nil;
                            callback = ^(NSData *data) {
                                [watch finish];
                                if ([data isKindOfClass:NSData.class]) SAPRememberTransport(endpoint, NO, YES);
                                if (observed) SAPJournalObserveCall(observed, sent, [data isKindOfClass:NSData.class] ? data : nil, origin);
                                originalCallback(data);
                            };
                        } else {
                            BOOL (^originalCallback)(NSData *) = callback;
                            callback = ^BOOL(NSData *data) {
                                if ([data isKindOfClass:NSData.class]) SAPRememberTransport(endpoint, NO, YES);
                                if (observed) SAPJournalObserveCall(observed, sent, [data isKindOfClass:NSData.class] ? data : nil, origin);
                                return originalCallback(data);
                            };
                        }
                    }
                    // Observe every service crossing this verified transport. The
                    // specialized journal above still decodes only Offline.
                    if(callback&&trace) {
                        if([commandName hasPrefix:@"callSingle:"]) {
                            void (^next)(id)=callback;
                            callback=^(id data){SAPTraceRPCReply(trace,data);SAPTraceWithOperation(trace.identifier,^{next(data);});};
                        }else {
                            BOOL (^next)(id)=callback;
                            callback=^BOOL(id data){SAPTraceRPCReply(trace,data);__block BOOL keep;
                                SAPTraceWithOperation(trace.identifier,^{keep=next(data);});if(!keep)SAPTraceRPCStreamEnd(trace,@"callback_returned_false");return keep;};
                        }
                    }
                    if(offline)offlineHookDepth++;
                    if(playerCall)playerHookDepth++;
                    traceHookDepth++;
                    @try {id result=((id (*)(id, SEL, id, id, id, id))original)(self, command, serviceName, methodName, payload, callback);SAPTraceRPCReturned(trace,result);return result;}
                    @catch(NSException *e){SAPTraceRPCException(trace,e);@throw;}
                    @finally {traceHookDepth--;if(offline)offlineHookDepth--;if(playerCall)playerHookDepth--;}
                }, names);
            }
        }
        cls = NSClassFromString(@"Esperanto_EsperantoImpl.EsperantoServiceImpl");
        sel = NSSelectorFromString(@"provideEsperantoTransport");
        if (SAPTransportSignature(cls, sel, 2, '@', &method)) {
            IMP original = method_getImplementation(method);
            putHook(cls, sel, method, ^id(id self) {
                id result = ((id (*)(id, SEL))original)(self, sel);
                if ([result respondsToSelector:NSSelectorFromString(@"callSingle:method:payload:onResponse:")]) SAPRememberTransport(result, YES, NO);
                return result;
            }, names);
        }
        // Journal queries use read-only requests on the observed transport.
        SAPJournalSetCaller(^id(NSString *method, NSData *payload, BOOL stream, NSUInteger attempt, void (^response)(NSData *)) {
            NSArray *available = SAPTransportCandidates();
            if (!available.count) return nil;
            id endpoint=available.firstObject;
            if(attempt) {
                endpoint=nil;
                NSUInteger index=0;
                for(id candidate in available)
                    if([NSStringFromClass(object_getClass(candidate)) isEqual:@"SPTEsperantoTransportBridgeImpl"] && index++==attempt-1) {endpoint=candidate;break;}
                if(!endpoint)return nil;
            }
            SEL command = NSSelectorFromString(stream ? @"callStream:method:payload:onResponse:" : @"callSingle:method:payload:onResponse:");
            Method found;
            if (!SAPTransportSignature(object_getClass(endpoint), command, 6, '@', &found)) return nil;
            id handler = stream ? (id)^BOOL(NSData *data) { if(response)response(data);return YES; } : (id)^(NSData *data) {if(response)response(data);};
            id lifetime = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(endpoint, command, SAPOfflineService, method, payload, handler);
            SAPAcquireTransportHandle(lifetime);
            return lifetime;
        });
    return [names copy];
}
NSDictionary *SAPTransportWatchReport(void) {
    return @{@"application_watches_pending":@(atomic_load(&nativeWatches)),@"application_watches_dropped":@(atomic_load(&nativeWatchesDropped))};
}
