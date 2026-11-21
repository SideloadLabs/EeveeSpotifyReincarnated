#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
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

// Tells the Pixie companion that this Eevee lists the download manager in its own settings.
__attribute__((visibility("default"))) BOOL EeveePixieDownloadsRowProvided(void) { return YES; }

static UIViewController *(*PixieDownloadsFactory(void))(void) {
    static UIViewController *(*make)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ make = dlsym(RTLD_DEFAULT, "SAPCreateDownloadsSettings"); });
    return make;
}

// Observe the already-loaded companion. Never dlopen/retry a module for logging.
NSString *EeveePixieStartupSummary(void) {
    void *factory=dlsym(RTLD_DEFAULT,"SAPCreateDownloadsSettings");
    NSDictionary *(*report)(void)=dlsym(RTLD_DEFAULT,"SAPStartupReport");
    if(report) {
        NSDictionary *status=report();
        NSString *state=status[@"state"]?:@"unknown",*version=status[@"version"]?:@"unknown";
        if(!factory)return [NSString stringWithFormat:@"[ERROR] Pixie %@: settings entry point missing",version];
        return [NSString stringWithFormat:@"%@Pixie %@: bootstrap=%@",[state isEqual:@"complete"]?@"":@"[ERROR] ",version,state];
    }
    if(factory)return @"Pixie loaded: bootstrap status unavailable (older companion)";
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char *name=_dyld_get_image_name(i);
        if(name && [[NSString stringWithUTF8String:name].lastPathComponent isEqual:@"SpotifyAudioProbe.dylib"])
            return @"[ERROR] Pixie library loaded but settings entry point missing";
    }
    NSString *frameworks=NSBundle.mainBundle.privateFrameworksPath;
    if(frameworks && [NSFileManager.defaultManager fileExistsAtPath:[frameworks stringByAppendingPathComponent:@"SpotifyAudioProbe.dylib"]])
        return @"[ERROR] Pixie library bundled but not loaded";
    return @"Pixie not bundled (optional module)";
}

BOOL EeveePixieDownloadsAvailable(void) { return PixieDownloadsFactory() != NULL; }

UIViewController *EeveePixieMakeDownloadsController(void) {
    UIViewController *(*make)(void) = PixieDownloadsFactory();
    return make ? make() : nil;
}

void EeveePixieFetchLyricsMetadata(NSString *trackURI, void (^completion)(NSDictionary *)) {
    // Resolve per call: Eevee may have initialized before the optional companion.
    void (*fetch)(NSString *,void (^)(NSDictionary *))=dlsym(RTLD_DEFAULT,"SAPFetchOfflineLyricsMetadata");
    // Without the companion nothing was asked, which is not a definite miss.
    if(fetch)fetch(trackURI,completion);else completion(@{@"unavailable":@YES});
}

dispatch_block_t EeveePixieReadDownloadedTrackURIs(void (^completion)(NSArray<NSString *> *)) {
    dispatch_block_t (*fetch)(void (^)(NSArray<NSString *> *, NSString *)) = dlsym(RTLD_DEFAULT, "SAPFetchDownloadedTrackURIs");
    if (!fetch) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return nil;
    }
    return fetch(^(NSArray<NSString *> *tracks, NSString *error) { completion(error ? nil : tracks); });
}

void EeveePixieObserveDownloadCompletion(BOOL enabled) {
    void (*observe)(BOOL) = dlsym(RTLD_DEFAULT, "SAPNativeDownloadCompletionSetActive");
    if (observe) observe(enabled);
}
