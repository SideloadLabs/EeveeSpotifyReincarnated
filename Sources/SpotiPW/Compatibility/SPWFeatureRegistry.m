#import "SPWFeatureRegistry.h"
@interface SPWFeatureRegistry ()
@property(nonatomic,strong) NSMutableDictionary *initializers;
@property(nonatomic,strong) NSMutableSet *started;
@property(nonatomic,strong) dispatch_queue_t queue;
@end
@implementation SPWFeatureRegistry
+ (instancetype)sharedRegistry {
    static SPWFeatureRegistry *r; static dispatch_once_t once;
    dispatch_once(&once, ^{ r=[SPWFeatureRegistry new]; });
    return r;
}
- (instancetype)init {
    if ((self=[super init])) {
        _initializers=[NSMutableDictionary dictionary];
        _started=[NSMutableSet set];
        _queue=dispatch_queue_create("pw.spoti.feature-registry", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)registerFeature:(NSString *)identifier initializer:(SPWFeatureInitializer)initializer {
    if (!identifier.length || !initializer) return;
    dispatch_sync(_queue, ^{ if (!_initializers[identifier] && ![_started containsObject:identifier]) _initializers[identifier]=[initializer copy]; });
}
- (BOOL)startFeature:(NSString *)identifier error:(NSError **)error {
    __block BOOL ok=NO;
    dispatch_sync(_queue, ^{
        if ([_started containsObject:identifier]) { ok=YES; return; }
        SPWFeatureInitializer initBlock=_initializers[identifier];
        if (!initBlock) return;
        NSError *e=nil;
        if (initBlock(e)) { [_started addObject:identifier]; ok=YES; }
        else if (error) *error=e ?: [NSError errorWithDomain:@"pw.spoti.feature" code:1 userInfo:nil];
    });
    return ok;
}
- (BOOL)isStarted:(NSString *)identifier {
    __block BOOL v=NO; dispatch_sync(_queue, ^{ v=[_started containsObject:identifier]; }); return v;
}
@end
