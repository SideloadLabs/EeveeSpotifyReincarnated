#import "SpotifyTransport.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#include <stdatomic.h>

#include <os/lock.h>
NSString *const SAPOfflineService = @"spotify.offline_esperanto.proto.Offline";
static __weak id player, transport;
static __weak id providedTransport, provenTransport, provenBridge, candidates[8];
static unsigned nextCandidateSlot;
static os_unfair_lock candidatesLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<NSArray<NSString *> *,id> *readRoutes;
static NSMutableArray<NSArray<NSString *> *> *readRouteKeys;
// Endpoint instances never survive a launch, but the class that answered a
// service/method does. It is persisted only to order the candidates of the next
// launch; it never admits an endpoint that the live registry does not hold.
static NSMutableDictionary<NSString *,NSString *> *routeClasses;
static NSMutableArray<NSString *> *routeClassOrder;
// What the previous launch left on disk; fixed for the whole process so that
// in-process evidence (and the death of an endpoint) keeps its existing meaning.
static NSDictionary<NSString *,NSString *> *inheritedRouteClasses;
static BOOL routeClassesLoaded;
static NSUInteger rememberCount;
#ifdef SAP_TESTING
static NSString *routeStoreDirectory;
#endif
static dispatch_queue_t worker;
static void *downloadWorkerKey=&downloadWorkerKey;
void SAPInitializeTransportRuntime(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        worker = dispatch_queue_create("SpotifyAudioProbe.native-download",
            dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        dispatch_queue_set_specific(worker,downloadWorkerKey,downloadWorkerKey,NULL);
    });
}
dispatch_queue_t SAPTransportWorker(void) {return worker;}
BOOL SAPOnTransportWorker(void) {return dispatch_get_specific(downloadWorkerKey)!=NULL;}
id SAPTransportPlayer(void) {return player;}
void SAPTransportSetPlayer(id value) {player=value;}
id SAPCurrentTransport(void) {return transport;}
id SAPProvenTransport(void) {os_unfair_lock_lock(&candidatesLock);id value=provenTransport;os_unfair_lock_unlock(&candidatesLock);return value;}
void SAPTransportVerifiedEndpoints(id __strong *proven,id __strong *bridge) {
    os_unfair_lock_lock(&candidatesLock);*proven=provenTransport;*bridge=provenBridge;os_unfair_lock_unlock(&candidatesLock);
}
#ifdef SAP_RUNTIME_TESTING
static NSMutableArray *seenNativeCalls;
void SAPRememberNativeCall(id endpoint, id serviceName, id methodName) {
    if (![serviceName isKindOfClass:NSString.class] || ![methodName isKindOfClass:NSString.class]) return;
    NSDictionary *entry = @{@"class": NSStringFromClass(object_getClass(endpoint)), @"service": serviceName, @"method": methodName};
    os_unfair_lock_lock(&candidatesLock);
    if (!seenNativeCalls) seenNativeCalls = [NSMutableArray array];
    if (![seenNativeCalls containsObject:entry]) { [seenNativeCalls addObject:entry]; if (seenNativeCalls.count > 64) [seenNativeCalls removeObjectAtIndex:0]; }
    os_unfair_lock_unlock(&candidatesLock);
}
#endif
void SAPRememberTransport(id value, BOOL provided, BOOL proven) {
    if (!value) return;
    os_unfair_lock_lock(&candidatesLock);
    if(!provided && !proven && transport==value) {os_unfair_lock_unlock(&candidatesLock);return;}
    if (provided) providedTransport = value;
    if (proven) {
        provenTransport = value;
        if([NSStringFromClass(object_getClass(value)) isEqual:@"SPTEsperantoTransportBridgeImpl"])provenBridge=value;
    }
    BOOL found = NO;
    for (unsigned i = 0; i < 8; i++) if (candidates[i] == value) { found = YES; break; }
    if (!found) candidates[(nextCandidateSlot++) % 8] = value;
    transport = value;
    os_unfair_lock_unlock(&candidatesLock);
}
NSArray *SAPTransportCandidates(void) {
    NSMutableArray *result = [NSMutableArray array];
    os_unfair_lock_lock(&candidatesLock);
    id proven = provenTransport, provided = providedTransport, bridge=provenBridge;
    if (proven) [result addObject:proven];
    if(bridge && ![result containsObject:bridge])[result addObject:bridge];
    if (provided && ![result containsObject:provided]) [result addObject:provided];
    // Prefer the C++ bridge to Cosmos, whose implementation silently drops
    // non-200 replies. Each fallback must answer a read-only GetItems probe.
    for (unsigned pass = 0; pass < 2; pass++) for (unsigned i = 0; i < 8; i++) {
        id value = candidates[i]; if (!value || [result containsObject:value]) continue;
        BOOL bridge = [NSStringFromClass(object_getClass(value)) isEqual:@"SPTEsperantoTransportBridgeImpl"];
        if (bridge == (pass == 0)) [result addObject:value];
    }
    os_unfair_lock_unlock(&candidatesLock);
    return result;
}

static const NSUInteger maximumReadRoutes=64;
static NSString *routeClassKey(NSString *service,NSString *method) {return [NSString stringWithFormat:@"%@\n%@",service,method];}
static NSString *routeStorePath(void) {
#ifdef SAP_TESTING
    // Host fixtures never touch a real profile unless they inject a directory.
    return routeStoreDirectory.length?[routeStoreDirectory stringByAppendingPathComponent:@"read-routes.plist"]:nil;
#else
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Pixie/read-routes.plist"];
#endif
}
static dispatch_queue_t routeStoreQueue(void) {
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("Pixie.read-route-store",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});
    return queue;
}
static void ensureRouteClasses(void) {
    os_unfair_lock_lock(&candidatesLock);BOOL loaded=routeClassesLoaded;os_unfair_lock_unlock(&candidatesLock);
    if(loaded)return;
    NSMutableDictionary *classes=NSMutableDictionary.dictionary;NSMutableArray *order=NSMutableArray.array;
    NSString *path=routeStorePath();NSDictionary *file=path?[NSDictionary dictionaryWithContentsOfFile:path]:nil;
    NSArray *entries=[file[@"version"]isEqual:@1]?file[@"routes"]:nil;
    if([entries isKindOfClass:NSArray.class])for(NSArray *entry in entries) {
        // Anything malformed or oversized is dropped; a bad file only costs the hint.
        if(order.count>=maximumReadRoutes)break;
        if(![entry isKindOfClass:NSArray.class] || entry.count!=2 || ![entry[0]isKindOfClass:NSString.class] || ![entry[1]isKindOfClass:NSString.class])continue;
        NSString *key=entry[0],*className=entry[1];
        if(!key.length || key.length>256 || !className.length || className.length>128 || classes[key])continue;
        classes[key]=className;[order addObject:key];
    }
    os_unfair_lock_lock(&candidatesLock);
    if(!routeClassesLoaded){routeClasses=classes;inheritedRouteClasses=[classes copy];routeClassOrder=order;routeClassesLoaded=YES;}
    os_unfair_lock_unlock(&candidatesLock);
}
static void persistRouteClasses(NSArray *entries) {
    NSString *path=routeStorePath();if(!path)return;
    dispatch_async(routeStoreQueue(),^{@autoreleasepool{
        NSFileManager *fm=NSFileManager.defaultManager;
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        // Atomic replace: a crash mid-write leaves the previous hint intact.
        [@{@"version":@1,@"routes":entries} writeToURL:[NSURL fileURLWithPath:path] error:nil];
    }});
}

void SAPRememberReadOnlyTransport(id endpoint,NSString *service,NSString *method) {
    if(!endpoint || ![service isKindOfClass:NSString.class] || !service.length ||
       ![method isKindOfClass:NSString.class] || !method.length)return;
    ensureRouteClasses();
    NSString *serviceKey=[service copy],*methodKey=[method copy],*className=NSStringFromClass(object_getClass(endpoint));
    NSArray *snapshot=nil;
    os_unfair_lock_lock(&candidatesLock);
    rememberCount++;
    if(!readRoutes){readRoutes=[NSMapTable strongToWeakObjectsMapTable];readRouteKeys=NSMutableArray.array;}
    for(NSArray *key in @[@[serviceKey,methodKey],@[serviceKey,@""]]) {
        if([readRoutes objectForKey:key]!=endpoint) {
            [readRouteKeys removeObject:key];[readRouteKeys addObject:key];
            [readRoutes setObject:endpoint forKey:key];
            if(readRouteKeys.count>maximumReadRoutes){[readRoutes removeObjectForKey:readRouteKeys.firstObject];[readRouteKeys removeObjectAtIndex:0];}
        }
        NSString *flat=routeClassKey(key[0],key[1]);
        if(![routeClasses[flat]isEqual:className]) {
            [routeClassOrder removeObject:flat];[routeClassOrder addObject:flat];routeClasses[flat]=className;
            if(routeClassOrder.count>maximumReadRoutes){[routeClasses removeObjectForKey:routeClassOrder.firstObject];[routeClassOrder removeObjectAtIndex:0];}
            NSMutableArray *entries=NSMutableArray.array;
            for(NSString *name in routeClassOrder)[entries addObject:@[name,routeClasses[name]]];
            snapshot=entries;
        }
    }
    os_unfair_lock_unlock(&candidatesLock);
    // Disk is touched only when the answering class actually changed.
    if(snapshot)persistRouteClasses(snapshot);
}

NSArray *SAPTransportCandidatesForRead(NSString *service,NSString *method) {
    NSArray *available=SAPTransportCandidates();
    if(!service.length || !method.length)return available;
    ensureRouteClasses();
    NSMutableArray *result=NSMutableArray.array;
    os_unfair_lock_lock(&candidatesLock);
    id exact=[readRoutes objectForKey:@[service,method]],fallback=[readRoutes objectForKey:@[service,@""]];
    NSString *exactClass=inheritedRouteClasses[routeClassKey(service,method)],*serviceClass=inheritedRouteClasses[routeClassKey(service,@"")];
    // Learned routes are an independent weak registry. The discovery ring may
    // evict a still-live endpoint when unrelated services discover new ones.
    // A disappeared endpoint already loads as nil; membership in that small
    // ring must not invalidate actual service/method response evidence.
    if(exact)[result addObject:exact];
    if(fallback && fallback!=exact)[result addObject:fallback];
    os_unfair_lock_unlock(&candidatesLock);
    // Prefer the class that answered in the previous launch, so the first read of
    // this one does not wait on an endpoint that stays silent. Live evidence above wins.
    for(NSString *className in @[exactClass?:@"",serviceClass?:@""])if(className.length)
        for(id endpoint in available)
            if([result indexOfObjectIdenticalTo:endpoint]==NSNotFound && [NSStringFromClass(object_getClass(endpoint))isEqual:className])[result addObject:endpoint];
    // Without a learned route, Offline reads try every non-bridge endpoint before the native C++ bridge.
    // Device logs (two sessions, 41 attempts) show the bridge never answers Pixie's Offline Get* reads,
    // while Cosmos answered ~99% of ~100; leading with the bridge cost a full 8 s deadline before the
    // Cosmos fallback. The bridge stays a last resort; commands and other services are unaffected.
    BOOL offline=[service isEqual:SAPOfflineService];NSMutableArray *bridges=NSMutableArray.array;
    for(id endpoint in available) {
        if([result indexOfObjectIdenticalTo:endpoint]!=NSNotFound)continue;
        if(offline&&[NSStringFromClass(object_getClass(endpoint)) isEqual:@"SPTEsperantoTransportBridgeImpl"])[bridges addObject:endpoint];
        else [result addObject:endpoint];
    }
    [result addObjectsFromArray:bridges];
    return result;
}


#ifdef SAP_TESTING
void SAPReadRouteStoreResetForTesting(NSString *directory) {
    os_unfair_lock_lock(&candidatesLock);
    readRoutes=nil;readRouteKeys=nil;routeClasses=nil;inheritedRouteClasses=nil;routeClassOrder=nil;routeClassesLoaded=NO;rememberCount=0;
    routeStoreDirectory=[directory copy];
    os_unfair_lock_unlock(&candidatesLock);
}
void SAPReadRouteStoreFlushForTesting(void) {dispatch_sync(routeStoreQueue(),^{});}
NSUInteger SAPReadRouteRememberCountForTesting(void) {
    os_unfair_lock_lock(&candidatesLock);NSUInteger count=rememberCount;os_unfair_lock_unlock(&candidatesLock);return count;
}
#endif

#ifdef SAP_RUNTIME_TESTING
NSDictionary *SAPTransportInventoryForTesting(void) {
    NSArray *pool=SAPTransportCandidates();NSMutableArray *classes=[NSMutableArray array];
    for(id value in pool)[classes addObject:NSStringFromClass(object_getClass(value))];
    os_unfair_lock_lock(&candidatesLock);NSArray *seen=[seenNativeCalls copy]?:@[];os_unfair_lock_unlock(&candidatesLock);
    return @{@"candidates":classes,@"native_calls":seen};
}
#endif
