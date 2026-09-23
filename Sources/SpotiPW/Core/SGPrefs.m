#import "SGPrefs.h"

BOOL SGFlag(NSString *key, BOOL fallback) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    id value = [store objectForKey:key];
    if (value) return [value boolValue];
    return fallback && ![store boolForKey:SGKeyStock];
}

BOOL SGEnabled(NSString *key) {
    return SGFlag(key, YES);
}

BOOL SGHidden(NSString *key) {
    return SGFlag(key, NO);
}

void SGSetEnabled(NSString *key, BOOL on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:key];
}

NSInteger SGInt(NSString *key, NSInteger fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value integerValue] : fallback;
}

void SGSetInt(NSString *key, NSInteger value) {
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
}

NSString *const SGFlagOverridePrefix = @"spotifyglass.flag.";

id SGFlagOverride(NSString *key) {
    return [NSUserDefaults.standardUserDefaults objectForKey:[SGFlagOverridePrefix stringByAppendingString:key]];
}

void SGSetFlagOverride(NSString *key, id value) {
    key = [SGFlagOverridePrefix stringByAppendingString:key];
    if (value) [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}

void SGMigrateKey(NSString *from, NSString *to) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    id value = [store objectForKey:from];
    if (!value || [store objectForKey:to]) return;
    [store setObject:value forKey:to];
    [store removeObjectForKey:from];
}

void SGRestartSpotify(void) {
    [NSUserDefaults.standardUserDefaults synchronize];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
}
