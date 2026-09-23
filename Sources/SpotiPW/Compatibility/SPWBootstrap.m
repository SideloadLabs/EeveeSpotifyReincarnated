#import <Foundation/Foundation.h>
#import "SPWFeatureRegistry.h"
__attribute__((constructor))
static void SPWBootstrap(void) {
    @autoreleasepool {
        [[SPWFeatureRegistry sharedRegistry] registerFeature:@"core" initializer:^BOOL(NSError *error) { return YES; }];
        [[SPWFeatureRegistry sharedRegistry] startFeature:@"core" error:NULL];
    }
}
