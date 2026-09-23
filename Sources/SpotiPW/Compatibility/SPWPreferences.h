#import <Foundation/Foundation.h>
@interface SPWPreferences : NSObject
+ (instancetype)shared;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)value;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
@end
