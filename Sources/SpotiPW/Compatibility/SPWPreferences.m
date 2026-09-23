#import "SPWPreferences.h"
static NSString * const SPWPreferencesDomain=@"pw.spoti.preferences";
@implementation SPWPreferences { NSUserDefaults *_defaults; }
+ (instancetype)shared { static SPWPreferences *p; static dispatch_once_t once; dispatch_once(&once, ^{p=[SPWPreferences new];}); return p; }
- (instancetype)init { if ((self=[super init])) _defaults=[[NSUserDefaults alloc] initWithSuiteName:SPWPreferencesDomain]; return self; }
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)value { NSNumber *n=[_defaults objectForKey:key]; return n ? n.boolValue : value; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { [_defaults setBool:value forKey:key]; }
- (id)objectForKey:(NSString *)key { return [_defaults objectForKey:key]; }
- (void)setObject:(id)value forKey:(NSString *)key { value ? [_defaults setObject:value forKey:key] : [_defaults removeObjectForKey:key]; }
@end
