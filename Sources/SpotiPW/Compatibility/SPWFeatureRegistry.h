#import <Foundation/Foundation.h>
typedef BOOL (^SPWFeatureInitializer)(NSError *error);
@interface SPWFeatureRegistry : NSObject
+ (instancetype)sharedRegistry;
- (void)registerFeature:(NSString *)identifier initializer:(SPWFeatureInitializer)initializer;
- (BOOL)startFeature:(NSString *)identifier error:(NSError **)error;
- (BOOL)isStarted:(NSString *)identifier;
@end
