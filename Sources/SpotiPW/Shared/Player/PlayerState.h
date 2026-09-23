#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"
NSString *SGURIString(id uri);
@protocol SGPlayerStateObserver <NSObject>
- (void)playerStateDidChange:(SPTPlayerState *)state;
@end
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer);
SPTPlayerState *SGPlayerState(void);
