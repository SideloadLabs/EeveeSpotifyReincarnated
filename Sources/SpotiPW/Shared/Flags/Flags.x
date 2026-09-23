// Spotify reads every remote-config flag once at startup through the configuration provider,
// keyed "component.property". The value handed back is Core/SGFlagForce.h's: what the redesign forces
// (Redesigned/Kit/SGRedesign.h), which comes before an override so one left from Spotify's own screens
// cannot pull a redesigned one apart, then an override from the Flags page, then what the Search switches
// and the lyrics sources force.
#import "Core/SGCore.h"
#import "Flags.h"

static id forced(NSString *key) {
    return SGForcedFlagValue(key);
}

static BOOL boolFor(NSString *key, BOOL orig) {
    id value = forced(key);
    return value ? [value boolValue] : orig;
}

static long intFor(NSString *key, long lower, long upper, long orig) {
    id value = forced(key);
    return value ? MAX(lower, MIN(upper, (long)[value longLongValue])) : orig;
}

static id enumFor(NSString *key, id orig) {
    id value = forced(key);
    return [value isKindOfClass:NSString.class] ? value : orig;
}

%hook _TtC22RemoteConfigurationSDK25ConfigurationProviderImpl
- (BOOL)boolValueForId:(NSString *)key defaultValue:(BOOL)fallback {
    BOOL orig = %orig;
    return boolFor(key, orig);
}
- (long)intValueForId:(NSString *)key lower:(long)lower upper:(long)upper defaultValue:(long)fallback {
    long orig = %orig;
    return intFor(key, lower, upper, orig);
}
- (id)enumValueForId:(NSString *)key values:(NSArray *)values defaultValue:(id)fallback {
    id orig = %orig;
    return enumFor(key, orig);
}
%end

// The observable properties listed in Info.plist go through a second provider.
%hook _TtC22RemoteConfigurationSDK35ObservableConfigurationProviderImpl
- (BOOL)boolValueForId:(NSString *)key defaultValue:(BOOL)fallback {
    BOOL orig = %orig;
    return boolFor(key, orig);
}
- (long)intValueForId:(NSString *)key lower:(long)lower upper:(long)upper defaultValue:(long)fallback {
    long orig = %orig;
    return intFor(key, lower, upper, orig);
}
- (id)enumValueForId:(NSString *)key values:(NSArray *)values defaultValue:(id)fallback {
    id orig = %orig;
    return enumFor(key, orig);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[
        @"_TtC22RemoteConfigurationSDK25ConfigurationProviderImpl",
        @"_TtC22RemoteConfigurationSDK35ObservableConfigurationProviderImpl",
    ]);
}
