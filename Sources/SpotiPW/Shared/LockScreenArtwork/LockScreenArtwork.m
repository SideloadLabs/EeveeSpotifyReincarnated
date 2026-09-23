// What the hook, the harness and the settings share: the order of the sources, which key this iOS
// takes a clip under, and putting one there.
#import <MediaPlayer/MediaPlayer.h>
#import "LockScreenArtwork.h"

NSString *const SGArtworkSourceSpotify = @"spotify";
NSString *const SGArtworkSourceApple = @"applemusic";

NSArray<NSString *> *SGArtworkOrder(void) {
    id stored = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyLockScreenArtworkSources];
    NSArray *keys = [stored isKindOfClass:NSArray.class] ? stored : @[SGArtworkSourceSpotify, SGArtworkSourceApple];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id key in keys) {
        BOOL known = [key isEqual:SGArtworkSourceSpotify] || [key isEqual:SGArtworkSourceApple];
        if (known && ![order containsObject:key]) [order addObject:key];
    }
    return order;
}

void SGArtworkSetOrder(NSArray<NSString *> *order) {
    [NSUserDefaults.standardUserDefaults setObject:order ?: @[] forKey:SGKeyLockScreenArtworkSources];
}

BOOL SGAnimatedArtworkAvailable(void) {
    if (@available(iOS 26.0, *)) return MPMediaItemAnimatedArtwork.class != nil;
    return NO;
}

NSArray<NSString *> *SGAnimatedArtworkKeys(void) {
    if (@available(iOS 26.0, *)) return MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys;
    return nil;
}

NSString *SGAnimatedArtworkKey(CGFloat *aspect) {
    if (@available(iOS 26.0, *)) {
        NSArray<NSString *> *supported = SGAnimatedArtworkKeys();
        // A Canvas is taller than either shape, so the tall key loses the least of it.
        if ([supported containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork]) {
            if (aspect) *aspect = 3.0 / 4.0;
            return MPNowPlayingInfoProperty3x4AnimatedArtwork;
        }
        if ([supported containsObject:MPNowPlayingInfoProperty1x1AnimatedArtwork]) {
            if (aspect) *aspect = 1;
            return MPNowPlayingInfoProperty1x1AnimatedArtwork;
        }
    }
    return nil;
}

NSDictionary *SGArtworkInInfo(NSDictionary *info, id artwork, NSString *key) {
    if (!info.count || !artwork || !key.length) return info;
    if (info[key] == artwork) return info;
    NSMutableDictionary *shown = [info mutableCopy];
    shown[key] = artwork;
    return shown;
}
