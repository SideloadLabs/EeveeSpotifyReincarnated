// The audio effects' settings: what each key holds until set, its bounds, and the lists the page's choices
// pick from, in the order the engine numbers them (SGDSPEffects.h).
#import "Core/SGCore.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h"

const double SGDSPEqualizerFrequencies[15] = {25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000};
const double SGDSPEqualizerGainLimit = 12;
const double SGDSPCompanderFrequencies[7] = {95, 200, 400, 800, 1600, 3400, 7500};
const double SGDSPCompanderGainLimit = 1;

#pragma mark - the keys

typedef struct {
    NSString *__unsafe_unretained key;
    SGDSPRange range;
} SGDSPNumberKey;

static const SGDSPNumberKey kNumbers[] = {
    {SGKeyDSPPostGain,          {-12, 12, 0, 0.5}},
    {SGKeyDSPLimiterThreshold,  {-24, 0, -0.3, 0.1}},
    {SGKeyDSPLimiterRelease,    {10, 500, 100, 5}},
    {SGKeyDSPCompanderTime,     {0.05, 0.5, 0.2, 0.01}},
    {SGKeyDSPBassGain,          {1, 15, 6, 0.5}},
    {SGKeyDSPConvolverMode,     {0, 2, 0, 1}},
    {SGKeyDSPReverbPreset,      {0, 8, 5, 1}},     // Plate
    {SGKeyDSPStereoWideLevel,   {0, 100, 60, 1}},
    {SGKeyDSPCrossfeedMode,     {0, 2, 2, 1}},     // libbs2b's own default
    {SGKeyDSPTubeDrive,         {0, 18, 4, 0.5}},
};

static NSDictionary<NSString *, NSString *> *stringDefaults(void) {
    static NSDictionary<NSString *, NSString *> *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = @{
            SGKeyDSPCompanderGains: @"0;0;0;0;0;0;0",
            SGKeyDSPEqualizerGains: @"0;0;0;0;0;0;0;0;0;0;0;0;0;0;0",
            SGKeyDSPGraphicEqNodes: @"GraphicEQ: 0.0 0.0;",
            SGKeyDSPConvolverFile: @"",
            SGKeyDSPDDCFile: @"",
            SGKeyDSPLiveprogFile: @"",
        };
    });
    return defaults;
}

// The switches of the effects, each the prefix of its own keys' names.
static NSArray<NSString *> *effectSwitches(void) {
    return @[SGKeyDSPCompander, SGKeyDSPBass, SGKeyDSPEqualizer, SGKeyDSPGraphicEq, SGKeyDSPConvolver, SGKeyDSPDDC,
             SGKeyDSPLiveprog, SGKeyDSPReverb, SGKeyDSPStereoWide, SGKeyDSPCrossfeed, SGKeyDSPTube];
}

NSString *SGDSPEffectOf(NSString *key) {
    for (NSString *effect in effectSwitches()) {
        if ([key isEqualToString:effect] || [key hasPrefix:[effect stringByAppendingString:@"."]]) return effect;
    }
    return SGKeyDSP;
}

SGDSPRange SGDSPRangeFor(NSString *key) {
    for (size_t i = 0; i < sizeof kNumbers / sizeof *kNumbers; i++) {
        if ([kNumbers[i].key isEqualToString:key]) return kNumbers[i].range;
    }
    return (SGDSPRange){0, 1, 0, 0};
}

#pragma mark - reading and writing

static NSUserDefaults *store(void) {
    return NSUserDefaults.standardUserDefaults;
}

BOOL SGDSPSwitch(NSString *key) {
    return SGHidden(key);
}

void SGDSPSetSwitch(NSString *key, BOOL on) {
    SGSetEnabled(key, on);
    SGDSPApply(SGDSPEffectOf(key));
}

double SGDSPNumber(NSString *key) {
    SGDSPRange range = SGDSPRangeFor(key);
    id value = [store() objectForKey:key];
    if (![value isKindOfClass:NSNumber.class]) return range.fallback;
    return MAX(range.min, MIN(range.max, [value doubleValue]));
}

void SGDSPSetNumber(NSString *key, double value) {
    SGDSPRange range = SGDSPRangeFor(key);
    [store() setDouble:MAX(range.min, MIN(range.max, value)) forKey:key];
    SGDSPApply(SGDSPEffectOf(key));
}

NSString *SGDSPString(NSString *key) {
    id value = [store() objectForKey:key];
    return [value isKindOfClass:NSString.class] ? value : (stringDefaults()[key] ?: @"");
}

void SGDSPSetString(NSString *key, NSString *value) {
    [store() setObject:value ?: @"" forKey:key];
    SGDSPApply(SGDSPEffectOf(key));
}

static NSUInteger gainCount(NSString *key) {
    return [key isEqualToString:SGKeyDSPCompanderGains] ? 7 : 15;
}

static double gainLimit(NSString *key) {
    return [key isEqualToString:SGKeyDSPCompanderGains] ? SGDSPCompanderGainLimit : SGDSPEqualizerGainLimit;
}

NSArray<NSNumber *> *SGDSPGains(NSString *key) {
    NSArray<NSString *> *parts = [SGDSPString(key) componentsSeparatedByString:@";"];
    NSUInteger count = gainCount(key);
    double limit = gainLimit(key);
    NSMutableArray<NSNumber *> *gains = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        double gain = i < parts.count ? parts[i].doubleValue : 0;
        [gains addObject:@(MAX(-limit, MIN(limit, gain)))];
    }
    return gains;
}

void SGDSPSetGains(NSString *key, NSArray<NSNumber *> *gains) {
    NSUInteger count = gainCount(key);
    double limit = gainLimit(key);
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        double gain = i < gains.count ? gains[i].doubleValue : 0;
        [parts addObject:[NSString stringWithFormat:@"%.2f", MAX(-limit, MIN(limit, gain))]];
    }
    SGDSPSetString(key, [parts componentsJoinedByString:@";"]);
}

void SGDSPResetAll(void) {
    for (size_t i = 0; i < sizeof kNumbers / sizeof *kNumbers; i++) [store() removeObjectForKey:kNumbers[i].key];
    for (NSString *key in stringDefaults()) [store() removeObjectForKey:key];
    for (NSString *effect in effectSwitches()) [store() removeObjectForKey:effect];
    SGDSPApply(SGKeyDSP);
    for (NSString *effect in effectSwitches()) SGDSPApply(effect);
}

#pragma mark - lists

NSArray<NSString *> *SGDSPConvolverModeNames(void) {
    return @[@"Original", @"Trimmed", @"Minimum phase"];
}

NSArray<NSString *> *SGDSPCrossfeedModeNames(void) {
    return @[@"Jan Meier (650 Hz, 9.5 dB)", @"Chu Moy (700 Hz, 6 dB)", @"Default (700 Hz, 4.5 dB)"];
}

NSArray<NSString *> *SGDSPReverbPresetNames(void) {
    return @[@"Ambience", @"Small room", @"Medium room", @"Large room", @"Chamber", @"Plate", @"Small hall", @"Large hall", @"Cathedral"];
}

NSArray<NSString *> *SGDSPEqualizerPresetNames(void) {
    return @[@"Flat", @"Bass", @"Loudness", @"Treble", @"Vocal", @"Warm", @"Bright", @"Rock", @"Electronic", @"Acoustic",
             @"Classical", @"Podcast"];
}

NSArray<NSNumber *> *SGDSPEqualizerPreset(NSInteger index) {
    static const double presets[][15] = {
        {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        {6, 6, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        {5, 5, 4, 2, 1, 0, 0, 0, 0, 0, 1, 2, 3, 4, 4},
        {0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 5},
        {-2, -2, -2, -1, -1, 0, 1, 2, 3, 3, 2, 1, 0, -1, -1},
        {2, 2, 2, 2, 1, 1, 0, 0, 0, -1, -1, -2, -2, -2, -2},
        {-1, -1, -1, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3},
        {4, 4, 3, 1, -1, -2, -2, -1, 0, 1, 2, 3, 3, 3, 2},
        {5, 5, 4, 2, 0, -1, -2, -1, 0, 1, 1, 2, 3, 4, 4},
        {2, 2, 2, 1, 1, 0, 0, 1, 1, 2, 2, 2, 2, 1, 1},
        {3, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 2, 2, 3},
        {-6, -6, -4, -2, -1, 0, 1, 2, 2, 2, 1, 0, -1, -2, -3},
    };
    if (index < 0 || index >= (NSInteger)(sizeof presets / sizeof *presets)) return nil;
    NSMutableArray<NSNumber *> *gains = [NSMutableArray arrayWithCapacity:15];
    for (int i = 0; i < 15; i++) [gains addObject:@(presets[index][i])];
    return gains;
}
