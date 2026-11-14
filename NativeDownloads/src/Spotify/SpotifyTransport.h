#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TrackDownload.h"

// Private transport boundary. Every service lifetime and the manual job retain
// the original serial worker; only the registry's weak references use its lock.
extern NSString *const SAPOfflineService;
void SAPInitializeTransportRuntime(void);
dispatch_queue_t SAPTransportWorker(void);
BOOL SAPOnTransportWorker(void);
void SAPRememberTransport(id value, BOOL provided, BOOL proven);
NSArray *SAPTransportCandidates(void);
// Read routes are learned from actual responses, independently of diagnostic
// logging. Exact RPC evidence wins over service evidence; endpoints stay weak.
void SAPRememberReadOnlyTransport(id endpoint,NSString *service,NSString *method);
NSArray *SAPTransportCandidatesForRead(NSString *service,NSString *method);
#ifdef SAP_TESTING
// Fixtures only: without a directory nothing is persisted. Reset forgets all
// in-memory routes, so the next read reloads from disk like a fresh launch.
void SAPReadRouteStoreResetForTesting(NSString *directory);
void SAPReadRouteStoreFlushForTesting(void);
NSUInteger SAPReadRouteRememberCountForTesting(void);
#endif
void SAPTransportVerifiedEndpoints(id __strong *proven,id __strong *bridge);
id SAPProvenTransport(void);
id SAPCurrentTransport(void);
id SAPTransportPlayer(void);
void SAPTransportSetPlayer(id player);
NSArray *SAPInstallSpotifyTransportHooks(void);
NSDictionary *SAPTransportWatchReport(void);
void SAPInvokeServiceOnce(NSString *serviceName,NSString *method,NSData *payload,
    void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition));

static inline id SAPTransportObject(id receiver, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![receiver respondsToSelector:sel]) return nil;
    Method method = class_getInstanceMethod(object_getClass(receiver), sel);
    char type[32]; method_getReturnType(method, type, sizeof(type));
    if (type[0] != '@' || method_getNumberOfArguments(method) != 2) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, sel);
}
static inline BOOL SAPTransportSignature(Class cls, SEL sel, unsigned args, char returnType, Method *out) {
    *out = class_getInstanceMethod(cls, sel);
    if (!*out || method_getNumberOfArguments(*out) != args) return NO;
    char type[32]; method_getReturnType(*out, type, sizeof(type));
    return type[0] == returnType;
}
static inline void SAPCancelTransportHandle(id handle) {
    SEL sel = NSSelectorFromString(@"cancel"); Method method;
    if (SAPTransportSignature(object_getClass(handle), sel, 2, 'v', &method)) ((void (*)(id, SEL))objc_msgSend)(handle, sel);
}
static inline void SAPAcquireTransportHandle(id handle) {
    // Retaining a native lifetime is insufficient; acquire transfers ownership.
    SEL sel = NSSelectorFromString(@"acquire"); Method method;
    if (SAPTransportSignature(object_getClass(handle), sel, 2, 'v', &method)) ((void (*)(id, SEL))objc_msgSend)(handle, sel);
}
#ifdef SAP_RUNTIME_TESTING
void SAPRememberNativeCall(id endpoint,id serviceName,id methodName);
NSDictionary *SAPTransportInventoryForTesting(void);
#endif
