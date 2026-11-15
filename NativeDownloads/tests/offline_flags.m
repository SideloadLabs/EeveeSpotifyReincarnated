#include "Diagnostics.h"
#import <Foundation/Foundation.h>
#import "OfflineFlags.h"
#include <assert.h>

@interface SPTCoreProductState : NSObject
@property(nonatomic, strong) NSDictionary *storage;
@property(nonatomic, strong) NSDictionary *overrides;
- (NSString *)stringForKey:(NSString *)key;
- (id)objectForKey:(NSString *)key;
- (id)objectForKeyedSubscript:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (void)setOriginalValues:(NSDictionary *)dict;
- (void)setOverrides:(NSDictionary *)dict;
- (NSDictionary *)values;
- (NSDictionary *)originalValues;
- (NSDictionary *)valuesDictFromMap:(void *)pointer;
- (NSDictionary *)valuesDictFromChangedKeys:(void *)pointer;
@end
@implementation SPTCoreProductState
- (NSString *)stringForKey:(NSString *)key { return self.storage[key]; }
- (id)objectForKey:(NSString *)key { return self.storage[key]; }
- (id)objectForKeyedSubscript:(NSString *)key { return self.storage[key]; }
- (BOOL)boolForKey:(NSString *)key { return [self.storage[key] boolValue]; }
- (NSInteger)integerForKey:(NSString *)key { return [self.storage[key] integerValue]; }
- (void)setOriginalValues:(NSDictionary *)dict { self.storage = dict; }
- (void)setOverrides:(NSDictionary *)dict { _overrides = dict; }
- (NSDictionary *)values { return self.storage; }
- (NSDictionary *)originalValues { return self.storage; }
- (NSDictionary *)valuesDictFromMap:(void *)pointer { assert(pointer == (void *)7); return self.storage; }
- (NSDictionary *)valuesDictFromChangedKeys:(void *)pointer { assert(pointer == (void *)9); return self.storage; }
@end

int main(void) { @autoreleasepool {
    SAPDiagnosticsSetEnabled(true);

    SPTCoreProductState *state = [SPTCoreProductState new];
    NSDictionary *freeState = @{@"offline": @"0", @"can-use-offline": @"0", @"type": @"free", @"unrelated": @"unchanged", @"has-offline-state": @"0"};
    [state setOriginalValues:freeState];
    assert(![state boolForKey:@"can-use-offline"]);
    SAPInstallOfflineFlags(); SAPInstallOfflineFlags();
    assert([[state stringForKey:@"offline"] isEqual:@"1"]);
    assert([[state objectForKey:@"can-use-offline"] isEqual:@"1"]);
    assert([state[@"offline"] isEqual:@"1"] && [state boolForKey:@"can-use-offline"]);
    assert([state integerForKey:@"max-offline-tracks"] == 1000000);
    assert([[state stringForKey:@"unrelated"] isEqual:@"unchanged"]);
    assert([[state objectForKey:@"type"] isEqual:@"free"] && ![state boolForKey:@"has-offline-state"]);
    assert([state objectForKey:@"missing"] == nil);
    // Setter forwarding updates the native state, not just the getter's UI result.
    [state setOriginalValues:freeState];
    assert([state.storage[@"offline"] isEqual:@"1"] && [freeState[@"offline"] isEqual:@"0"]);
    [state setOverrides:freeState]; assert([state.overrides[@"can-use-offline"] isEqual:@"1"]);
    for (NSDictionary *values in @[[state values], [state originalValues], [state valuesDictFromMap:(void *)7], [state valuesDictFromChangedKeys:(void *)9]]) {
        assert([values[@"offline"] isEqual:@"1"] && [values[@"type"] isEqual:@"free"]);
    }
    NSDictionary *report = SAPOfflineFlagsReport();
    assert([report[@"installed_hooks"] count] == 11 && [report[@"forced_reads"] unsignedLongLongValue] >= 5);
    assert([report[@"patched_dictionaries"] unsignedLongLongValue] == 2);
    puts("PASS: native product-state selectors; offline getters/dictionaries and setter propagation; quota; originals preserved; idempotent installation");
} }
