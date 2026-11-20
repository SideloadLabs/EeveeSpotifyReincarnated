#import "Localization.h"
#import <dlfcn.h>

NSString *SAPLocalized(NSString *english) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"EeveeSpotify" withExtension:@"bundle"];
        if (!url) {
            NSString *(*rootPath)(NSString *) = dlsym(RTLD_DEFAULT, "EeveeJBRootPath");
            if (rootPath) {
                url = [NSURL fileURLWithPath:rootPath(@"/Library/Application Support/EeveeSpotify.bundle")];
            }
        }
        if (url) bundle = [NSBundle bundleWithURL:url];
    });
    if (!bundle || !english.length) return english;
    return [bundle localizedStringForKey:english value:english table:nil];
}
