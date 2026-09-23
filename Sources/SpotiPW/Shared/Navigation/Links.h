#import <Foundation/Foundation.h>
BOOL SGOpenSpotifyURI(NSURL *uri);
id SGLinkDispatcher(void);
typedef NS_ENUM(NSInteger, SGLinkRoute){SGLinkRouteUnknown=-1,SGLinkRouteNone=0,SGLinkRouteOpens=1};
SGLinkRoute SGSpotifyURIRoute(NSURL *uri, NSString **via);
NSURL *SGSpotifyURIFromText(NSString *text);
