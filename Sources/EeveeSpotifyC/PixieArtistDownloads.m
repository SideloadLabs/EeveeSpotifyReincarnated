#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "include/Tweak.h"

// The artist download button is implemented by the Pixie native-downloads companion. The glass
// artist header hosts it in Eevee's action row, so Eevee only forwards to the companion's exports.
void EeveePixieUpdateArtistDownloads(UIView *header, UIButton *externalButton) {
    static void (*update)(UIView *, UIButton *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ update = dlsym(RTLD_DEFAULT, "SAPUpdateArtistDownloadsExternal"); });
    if (update) update(header, externalButton);
    else if (externalButton && !externalButton.isHidden) externalButton.hidden = YES;
}

NSString *EeveePixieArtistURIForHeader(UIView *header) {
    static NSString *(*resolve)(UIView *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ resolve = dlsym(RTLD_DEFAULT, "SAPArtistURIForHeader"); });
    return resolve ? resolve(header) : nil;
}
