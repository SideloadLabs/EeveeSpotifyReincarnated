#import <Foundation/Foundation.h>

// Pixie translates through Eevee's EeveeLocalizedString. Host fixtures run without Eevee,
// so they get Eevee's English: the key's text in en.lproj, or the key itself.
__attribute__((visibility("default"), used))
NSString *EeveeLocalizedString(NSString *key) {
    static NSBundle *english;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *tests = [[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent];
        NSString *path = [tests stringByAppendingPathComponent:
            @"../../layout/Library/Application Support/EeveeSpotify.bundle/en.lproj"];
        english = [NSBundle bundleWithPath:path.stringByStandardizingPath];
    });
    return [english localizedStringForKey:key value:key table:nil];
}
