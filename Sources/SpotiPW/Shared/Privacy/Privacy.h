#import <UIKit/UIKit.h>
#define SGKeyBlockTelemetry @"spotifyglass.blockTelemetry"
#define SGKeyHideSearchVideos @"spotifyglass.adblock.searchVideos"
#define SGKeyHideSocialProof @"spotifyglass.adblock.socialProof"
NSArray<NSString*>*SGBlockedLabels(void);
NSUInteger SGBlockedCount(NSString*label);
void SGResetBlocked(void);
UIViewController*SGPrivacySettingsPage(void);
