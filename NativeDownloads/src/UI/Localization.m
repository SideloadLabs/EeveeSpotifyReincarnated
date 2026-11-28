#import "Localization.h"
#import <dlfcn.h>

NSString *SAPLocalized(NSString *key) {
    // Eevee may load after Pixie, so a missing lookup is asked for again.
    static NSString *(*lookup)(NSString *);
    if (!lookup) lookup = dlsym(RTLD_DEFAULT, "EeveeLocalizedString");
    return lookup && key.length ? lookup(key) : key;
}

