// Spotify's own list look, for every page of the mod's: a 13pt white title over an 11pt grey
// subtitle on #121212, 38pt uppercase section headers, green switches.
#import <UIKit/UIKit.h>

UIColor *SGGrey(void);
UIColor *SGGreen(void);
UIColor *SGRed(void);
UIColor *SGDiscordColor(void);
UIColor *SGPageBackground(void);
UIColor *SGCardBackground(void);
UIFont *SGTitleFont(void);
UIFont *SGSubtitleFont(void);
// Takes the 13pt and 11pt fonts off Spotify's own settings list, once, so the pages match it.
void SGAdoptFonts(UIView *list, UIView *exclude);

UIImageView *SGSymbolView(NSString *name, CGFloat size, UIImageSymbolWeight weight, CGFloat box);
// A symbol on a rounded grey square, the leading icon of a row that opens a page.
UIImage *SGTileImage(NSString *symbol);
// A grey note in a wrapper view, for a table header or footer; SGFitNote sizes it to its text.
UIView *SGNote(NSString *text);
void SGFitNote(UITableView *table, UIView *wrapper, CGFloat top, CGFloat bottom);
// The now playing bar and the tab bar float over the content, so a page insets itself under them.
void SGInsetForBars(UITableView *table);

extern const CGFloat SGSectionHeaderHeight;
extern const CGFloat SGSectionGap;   // above a section with no header, so its card does not touch the one before
void SGFillCell(UITableViewCell *cell, NSString *title, NSString *subtitle, UIColor *color, NSString *symbolName);
UIView *SGSectionHeader(UITableView *table, NSString *title);
UIView *SGSectionFooter(UITableView *table, NSString *text);
CGFloat SGSectionFooterHeight(UITableView *table, NSString *text);
UITableViewCell *SGDequeueCell(UITableView *table, NSString *identifier);

void SGOpenURL(NSString *url);
extern NSString *const SGSiteURL;
extern NSString *const SGRepoURL;
extern NSString *const SGDiscordURL;
// The controller on top of the key window, through whatever is presented over it.
UIViewController *SGTopController(void);
