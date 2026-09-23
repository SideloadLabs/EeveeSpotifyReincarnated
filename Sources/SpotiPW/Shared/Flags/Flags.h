// Flags: Spotify's remote-config flags. Flags.x forces an override into the configuration
// provider; SGFlagList.m is the table of every flag, generated from the IPA by
// scripts/extract-flags.py; FlagsPage.m is the searchable All flags page and FlagPages.m the Labs
// page. Flags that change a part of the app sit on that part's own page.
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, SGFlagType) { SGFlagUnknown, SGFlagBool, SGFlagInt, SGFlagEnum };
typedef struct { const char *key; SGFlagType type; long value, lower, upper; } SGFlagDef;
extern const SGFlagDef SGFlagTable[];
extern const NSUInteger SGFlagCount;

UIViewController *SGAllFlagsPage(void);
UIViewController *SGLabsPage(void);
