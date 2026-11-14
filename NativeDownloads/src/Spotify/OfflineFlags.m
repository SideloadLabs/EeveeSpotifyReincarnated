#import "OfflineFlags.h"
#import "OfflineLimits.h"
#import "DiagnosticTrace.h"
#import <objc/runtime.h>
#include <stdatomic.h>

static NSDictionary<NSString *, NSString *> *flags;
static NSArray<NSString *> *installed;
static atomic_uint_fast64_t forcedReads, patchedDictionaries;
static __weak id coreState;
static id (*coreRead)(id, SEL, id);

static NSDictionary *rewrite(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return value;
    NSDictionary *dict = value;
    BOOL needsChange = NO;
    for (NSString *key in flags) {
        id old = dict[key];
        if (![old respondsToSelector:@selector(description)] || ![[old description] isEqual:flags[key]]) { needsChange = YES; break; }
    }
    if (!needsChange) return dict;
    NSMutableDictionary *copy = [dict mutableCopy];
    [copy addEntriesFromDictionary:flags];
    if(SAPTraceIsActive()) {
        NSMutableDictionary *before=[NSMutableDictionary dictionary];for(NSString *key in flags)before[key]=dict[key]?:NSNull.null;
        SAP_TRACE("flags","dictionary_input_rewritten",SAPTraceCurrentOperation(),@{@"before":before,@"passed_to_original":flags,@"native_storage_readback_confirmed":@NO,@"server_origin_proven":@NO});
    }
    atomic_fetch_add(&patchedDictionaries, 1);
    return copy;
}

static BOOL methodInfo(Class cls, SEL sel, unsigned arguments, const char *returns, Method *method) {
    *method = class_getInstanceMethod(cls, sel);
    if (!*method || method_getNumberOfArguments(*method) != arguments) return NO;
    char type[32]; method_getReturnType(*method, type, sizeof(type));
    return type[0] && strchr(returns, type[0]) != NULL;
}
static void replace(Class cls, SEL sel, Method method, id block, NSMutableArray *list) {
    IMP previous=method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    [list addObject:[NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)]];
    SAPTraceRegisterHook(cls,sel,replacement,previous);
}

void SAPInstallOfflineFlags(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        flags = @{@"offline": @"1", @"can-use-offline": @"1",
                  @"max-offline-downloads-per-device": @(SAPMinimumTrackLimit).stringValue, @"max-offline-tracks": @(SAPMinimumTrackLimit).stringValue};
        NSMutableArray *list = [NSMutableArray array];
        // Product-state-specific selectors only; no NSObject/dictionary-wide hooks.
        Class cls = NSClassFromString(@"SPTCoreProductState");
        if (cls) {
            for (NSString *name in @[@"stringForKey:", @"objectForKey:", @"objectForKeyedSubscript:"]) {
                SEL sel = NSSelectorFromString(name); Method method;
                if (!methodInfo(cls, sel, 3, "@", &method)) continue;
                IMP original = method_getImplementation(method);
                if ([name isEqual:@"stringForKey:"]) coreRead = (void *)original;
                replace(cls, sel, method, ^id(id self, NSString *key) {
                    SAPTraceHookCalled(object_getClass(self),sel);
                    coreState = self;
                    NSString *forced = [key isKindOfClass:NSString.class] ? flags[key] : nil;
                    if (forced) { atomic_fetch_add(&forcedReads, 1);SAP_TRACE("flags","getter_override_returned",SAPTraceCurrentOperation(),@{@"key":key,@"returned":forced,@"original_getter_called":@NO,@"server_origin_proven":@NO});return forced; }
                    return ((id (*)(id, SEL, id))original)(self, sel, key);
                }, list);
            }
            SEL boolSel = NSSelectorFromString(@"boolForKey:"); Method method;
            if (methodInfo(cls, boolSel, 3, "Bc", &method)) {
                IMP original = method_getImplementation(method);
                replace(cls, boolSel, method, ^BOOL(id self, NSString *key) {
                    SAPTraceHookCalled(object_getClass(self),boolSel);
                    NSString *forced = [key isKindOfClass:NSString.class] ? flags[key] : nil;
                    if (forced) { atomic_fetch_add(&forcedReads, 1);SAP_TRACE("flags","getter_override_returned",SAPTraceCurrentOperation(),@{@"key":key,@"returned":@(forced.boolValue),@"original_getter_called":@NO,@"server_origin_proven":@NO});return forced.boolValue; }
                    return ((BOOL (*)(id, SEL, id))original)(self, boolSel, key);
                }, list);
            }
            SEL intSel = NSSelectorFromString(@"integerForKey:");
            if (methodInfo(cls, intSel, 3, "qQ", &method)) {
                IMP original = method_getImplementation(method);
                replace(cls, intSel, method, ^NSInteger(id self, NSString *key) {
                    SAPTraceHookCalled(object_getClass(self),intSel);
                    NSString *forced = [key isKindOfClass:NSString.class] ? flags[key] : nil;
                    if (forced) { atomic_fetch_add(&forcedReads, 1);SAP_TRACE("flags","getter_override_returned",SAPTraceCurrentOperation(),@{@"key":key,@"returned":@(forced.integerValue),@"original_getter_called":@NO,@"server_origin_proven":@NO});return forced.integerValue; }
                    return ((NSInteger (*)(id, SEL, id))original)(self, intSel, key);
                }, list);
            }
            for (NSString *name in @[@"setOriginalValues:", @"setOverrides:"]) {
                SEL sel = NSSelectorFromString(name);
                if (!methodInfo(cls, sel, 3, "v", &method)) continue;
                IMP original = method_getImplementation(method);
                replace(cls, sel, method, ^(id self, NSDictionary *dict) {
                    SAPTraceHookCalled(object_getClass(self),sel);
                    coreState = self;
                    ((void (*)(id, SEL, id))original)(self, sel, rewrite(dict));
                }, list);
            }
            for (NSString *name in @[@"values", @"originalValues"]) {
                SEL sel = NSSelectorFromString(name);
                if (!methodInfo(cls, sel, 2, "@", &method)) continue;
                IMP original = method_getImplementation(method);
                replace(cls, sel, method, ^id(id self) {
                    SAPTraceHookCalled(object_getClass(self),sel);
                    coreState = self;
                    return rewrite(((id (*)(id, SEL))original)(self, sel));
                }, list);
            }
            for (NSString *name in @[@"valuesDictFromMap:", @"valuesDictFromChangedKeys:"]) {
                SEL sel = NSSelectorFromString(name);
                if (!methodInfo(cls, sel, 3, "@", &method)) continue;
                IMP original = method_getImplementation(method);
                replace(cls, sel, method, ^id(id self, void *argument) {
                    SAPTraceHookCalled(object_getClass(self),sel);
                    coreState = self;
                    return rewrite(((id (*)(id, SEL, void *))original)(self, sel, argument));
                }, list);
            }
        }
        installed = [list copy];
    });
}
NSDictionary *SAPOfflineFlagsReport(void) {
    NSMutableDictionary *actual = [NSMutableDictionary dictionary];
    id state = coreState;
    if (state && coreRead) @try {
        for (NSString *key in flags) {
            id value = coreRead(state, NSSelectorFromString(@"stringForKey:"), key);
            actual[key] = [value isKindOfClass:NSString.class] ? value : NSNull.null;
        }
    } @catch (NSException *exception) {}
    return @{@"enabled": @YES, @"client_flags": flags ?: @{}, @"installed_hooks": installed ?: @[],
        @"core_values_unmodified_getter": actual,
        @"forced_reads": @(atomic_load(&forcedReads)), @"patched_dictionaries": @(atomic_load(&patchedDictionaries)),
        @"reminder_disabled_in_package": @NO, @"host_mod": @"Vitrine"};
}
