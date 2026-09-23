// The Animated lock screen rows, put on the Lock screen widget page by Shared/Player/PlayerSettings.m.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGOrderPage.h"
#import "Settings/SGPageStyle.h"
#import "LockScreenArtwork.h"

static void sayWhatIsMissing(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Animated lock screen"
        message:[NSString stringWithFormat:@"Animated artwork is the lock screen's own, and iOS takes one only from 26 on. This phone runs iOS %@, where the cover stays still.", UIDevice.currentDevice.systemVersion]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static NSArray<SGOrderItem *> *sources(void) {
    return @[
        SGOrderItemMake(SGArtworkSourceSpotify, @"Spotify Canvas", @"The track's own clip"),
        SGOrderItemMake(SGArtworkSourceApple, @"Apple Music", @"The album's animated cover"),
    ];
}

NSArray<SGModRow *> *SGAnimatedArtworkRows(void) {
    if (!SGAnimatedArtworkAvailable())
        return @[SGStatActionRow(@"Animated lock screen", nil, ^NSString *{ return @"Needs iOS 26"; }, ^{ sayWhatIsMissing(); })];
    SGModRow *order = SGPageRow(@"Sources", ^UIViewController *{
        return SGOrderPage(@"Artwork sources", sources(), ^NSArray<NSString *> *{ return SGArtworkOrder(); },
                           ^(NSArray<NSString *> *keys) { SGArtworkSetOrder(keys); },
                           @"Asked top to bottom until one has a clip. Apple Music gets only the artist and album name.");
    });
    order.value = ^NSString *{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *key in SGArtworkOrder()) {
            for (SGOrderItem *item in sources()) {
                if ([item.key isEqualToString:key]) [names addObject:item.name];
            }
        }
        return names.count ? [names componentsJoinedByString:@", "] : @"None";
    };
    order.visible = ^BOOL { return SGFlag(SGKeyLockScreenArtwork, YES); };
    return @[
        SGSwitchRow(@"Animated lock screen", @"A moving cover behind the lock screen's controls", SGKeyLockScreenArtwork),
        order,
    ];
}
