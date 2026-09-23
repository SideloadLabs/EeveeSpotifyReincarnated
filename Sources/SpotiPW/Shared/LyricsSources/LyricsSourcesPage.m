#import "Settings/SGOrderPage.h"
#import "LyricsSources.h"

UIViewController *SGLyricsSourcesPage(void) {
    NSMutableArray<SGOrderItem *> *items = [NSMutableArray array];
    for (SGLyricsProvider *provider in SGLyricsAllProviders()) {
        [items addObject:SGOrderItemMake(provider.key, provider.name, provider.detail)];
    }
    return SGOrderPage(@"Lyrics sources", items, ^NSArray<NSString *> *{ return SGLyricsOrder(); },
                       ^(NSArray<NSString *> *order) { SGLyricsSetOrder(order); },
                       @"Asked top to bottom until one has word timing. Sources get only the track, never "
                        "your account.");
}
