// The base of every page of the mod's, pushable onto Spotify's own navigation stack.
#import <UIKit/UIKit.h>

@interface SGPage : UITableViewController
@end

// Registers SGPage as one of Spotify's pages; called once, from the settings hook's %ctor.
void SGRegisterPages(void);
// Pushes the page if it can go on Spotify's stack, presents it otherwise.
void SGShowPage(UIViewController *owner, UIViewController *page);
// Mod Settings, pushed onto the selected tab's stack; `source` is any view on the tab bar.
void SGOpenModSettings(UIView *source);
