#pragma once
#import <UIKit/UIKit.h>

// Register the host's actual page protocols. Retrying is safe if Spotify's
// protocol metadata was not loaded when a page was first constructed.
BOOL SAPRegisterPixiePageProtocols(void);

@interface SAPPixiePageController : UITableViewController
- (NSString *)spt_pageIdentifier;
- (NSURL *)spt_pageURI;
@end
