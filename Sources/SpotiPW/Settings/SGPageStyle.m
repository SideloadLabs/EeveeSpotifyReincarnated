#import "SGPageStyle.h"
#import "Core/SGCore.h"

static UIFont *sg_titleFont, *sg_subtitleFont;

UIColor *SGGrey(void) { return [UIColor colorWithWhite:0xB3 / 255.0 alpha:1]; }
UIFont *SGTitleFont(void) { return sg_titleFont ?: [UIFont systemFontOfSize:13 weight:UIFontWeightBold]; }
UIFont *SGSubtitleFont(void) { return sg_subtitleFont ?: [UIFont systemFontOfSize:11]; }

UIImageView *SGSymbolView(NSString *name, CGFloat size, UIImageSymbolWeight weight, CGFloat box) {
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
    UIImageView *view = [[UIImageView alloc] initWithImage:image];
    view.tintColor = UIColor.whiteColor;
    view.contentMode = UIViewContentModeCenter;
    view.frame = CGRectMake(0, 0, box, box);
    return view;
}

// A grey note in a wrapper view, for the table header and footer.
UIView *SGNote(NSString *text) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = SGSubtitleFont();
    label.textColor = SGGrey();
    label.numberOfLines = 0;
    UIView *wrapper = [UIView new];
    [wrapper addSubview:label];
    return wrapper;
}

// Header and footer views keep the height they are given, so size them to their text. Only the
// size is compared: the table moves the footer's origin itself, and reassigning on that would
// loop forever.
void SGFitNote(UITableView *table, UIView *wrapper, CGFloat top, CGFloat bottom) {
    UILabel *label = wrapper.subviews.firstObject;
    CGFloat inset = table.layoutMargins.left;
    CGFloat width = table.bounds.size.width - 2 * inset;
    CGFloat height = ceil([label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    label.frame = CGRectMake(inset, top, width, height);
    CGSize size = CGSizeMake(table.bounds.size.width, top + height + bottom);
    if (CGSizeEqualToSize(wrapper.bounds.size, size)) return;
    wrapper.frame = (CGRect){wrapper.frame.origin, size};
    if (wrapper == table.tableHeaderView) table.tableHeaderView = wrapper;
    else table.tableFooterView = wrapper;
}

static CGFloat barsHeight(UIView *view) {
    UIWindow *window = view.window;
    __block CGFloat top = window.bounds.size.height;
    SGForEachView(window, ^(UIView *v) {
        NSString *name = NSStringFromClass(v.class);
        BOOL bar = [name containsString:@"NowPlaying_BarPageImpl"] || [name isEqualToString:@"_TtC23NavigationUI_TabBarImpl10TabBarView"];
        if (!bar || v.hidden || v.alpha == 0 || v.bounds.size.height == 0) return;
        top = MIN(top, SGFrameIn(v, window).origin.y);
    });
    return window.bounds.size.height - top;
}

// The now playing bar and the tab bar float over the content, and the safe area does not cover
// them, so the pages inset themselves by however much of the window the bars take.
void SGInsetForBars(UITableView *table) {
    CGFloat bottom = MAX(0, barsHeight(table) - table.safeAreaInsets.bottom);
    if (table.contentInset.bottom == bottom) return;
    UIEdgeInsets inset = table.contentInset;
    inset.bottom = bottom;
    table.contentInset = inset;
    table.verticalScrollIndicatorInsets = inset;
}

// The pages follow the running look's black and accent colour, read here by their keys so the page
// framework depends on no layer: the native look's AMOLED switch and accent (Native/Appearance), or the
// redesign's accent (Redesigned/Kit/SGRAccent.h), which is always black.
static NSString *const kAmoledKey = @"spotifyglass.amoled";
static NSString *const kAccentKey = @"spotifyglass.accent";
static NSString *const kRedesignAccentKey = @"spotifyglass.redesign.accent";

static UIColor *lookAccent(void) {
    NSInteger rgb = SGInt(SGRedesignedUI() ? kRedesignAccentKey : kAccentKey, -1);
    if (rgb < 0 || rgb > 0xFFFFFF) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

static BOOL lookBlack(void) {
    return SGRedesignedUI() || SGFlag(kAmoledKey, NO);
}

UIColor *SGGreen(void) { return lookAccent() ?: [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1]; }
UIColor *SGRed(void) { return [UIColor colorWithRed:0xF1 / 255.0 green:0x5E / 255.0 blue:0x6B / 255.0 alpha:1]; }
UIColor *SGDiscordColor(void) { return [UIColor colorWithRed:0x58 / 255.0 green:0x65 / 255.0 blue:0xF2 / 255.0 alpha:1]; }
UIColor *SGPageBackground(void) { return lookBlack() ? UIColor.blackColor : [UIColor colorWithWhite:0x12 / 255.0 alpha:1]; }
// Spotify's own elevated grey on its dark grey; iOS's own card grey on the AMOLED black.
UIColor *SGCardBackground(void) { return [UIColor colorWithWhite:(lookBlack() ? 0x1C : 0x2A) / 255.0 alpha:1]; }

UIImage *SGTileImage(NSString *symbol) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGRect box = CGRectMake(0, 0, 28, 28);
    UIImage *tile = [[[UIGraphicsImageRenderer alloc] initWithSize:box.size] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithWhite:1 alpha:0.12] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:box cornerRadius:7] fill];
        CGSize size = glyph.size;
        [glyph drawInRect:CGRectMake((box.size.width - size.width) / 2, (box.size.height - size.height) / 2, size.width, size.height)];
    }];
    return [tile imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

const CGFloat SGSectionHeaderHeight = 38;
const CGFloat SGSectionGap = 20;

// Every page below draws Spotify's own list row: a 13pt white title over an 11pt grey subtitle,
// with an optional symbol in the leading slot.
void SGFillCell(UITableViewCell *cell, NSString *title, NSString *subtitle, UIColor *color, NSString *symbolName) {
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = title;
    content.secondaryText = subtitle;
    content.textProperties.font = SGTitleFont();
    content.textProperties.color = color ?: UIColor.whiteColor;
    content.secondaryTextProperties.font = SGSubtitleFont();
    content.secondaryTextProperties.color = SGGrey();
    content.textToSecondaryTextVerticalPadding = 0;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10, 16, 10, 16);
    if (symbolName) {
        content.image = [UIImage systemImageNamed:symbolName withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightRegular]];
        content.imageProperties.tintColor = color ?: UIColor.whiteColor;
        content.imageToTextPadding = 14;
    }
    cell.contentConfiguration = content;
    cell.backgroundColor = SGCardBackground();
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
}

UIView *SGSectionHeader(UITableView *table, NSString *title) {
    UILabel *label = [UILabel new];
    label.text = title.uppercaseString;
    label.font = SGSubtitleFont();
    label.textColor = SGGrey();
    label.frame = CGRectMake(16, 20, table.bounds.size.width - 32, 14);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, SGSectionHeaderHeight)];
    [header addSubview:label];
    return header;
}

static const CGFloat kFooterTop = 8, kFooterBottom = 4;

static CGFloat footerTextHeight(UITableView *table, NSString *text) {
    // An inset grouped table narrows its footers by its side margins, and the label wraps at that width.
    CGFloat inset = table.style == UITableViewStyleInsetGrouped ? table.layoutMargins.left + table.layoutMargins.right : 0;
    CGFloat width = MAX(table.bounds.size.width - inset - 32, 100);
    return ceil([text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                   options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:@{NSFontAttributeName: SGSubtitleFont()}
                                   context:nil].size.height);
}

UIView *SGSectionFooter(UITableView *table, NSString *text) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = SGSubtitleFont();
    label.textColor = SGGrey();
    label.numberOfLines = 0;
    label.frame = CGRectMake(16, kFooterTop, table.bounds.size.width - 32, footerTextHeight(table, text));
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, SGSectionFooterHeight(table, text))];
    [footer addSubview:label];
    return footer;
}

CGFloat SGSectionFooterHeight(UITableView *table, NSString *text) {
    return kFooterTop + footerTextHeight(table, text) + kFooterBottom;
}

UITableViewCell *SGDequeueCell(UITableView *table, NSString *identifier) {
    return [table dequeueReusableCellWithIdentifier:identifier]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
}

static CGFloat brightness(UIColor *color) {
    CGFloat white = 0;
    [color getWhite:&white alpha:NULL];
    return white;
}

// Spotify's list labels carry its typeface: 13pt titles and 11pt grey subtitles.
void SGAdoptFonts(UIView *list, UIView *row) {
    if (sg_titleFont && sg_subtitleFont) return;
    SGForEachView(list, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class] || SGIsInside(v, row)) return;
        UILabel *label = (UILabel *)v;
        if (label.text.length < 2) return;
        CGFloat size = label.font.pointSize, white = brightness(label.textColor);
        if (size == 13 && !sg_titleFont) sg_titleFont = label.font;
        if (size == 11 && !sg_subtitleFont && white > 0.3 && white < 0.95) sg_subtitleFont = label.font;
    });
}

UIViewController *SGTopController(void) {
    UIViewController *top = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden) continue;
            if (!top || window.isKeyWindow) top = window.rootViewController;
        }
    }
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

NSString *const SGSiteURL = @"https://spoti.pw";
NSString *const SGRepoURL = @"https://github.com/skopevoj/spoti.pw";
NSString *const SGDiscordURL = @"https://discord.gg/9e4GR8TKMj";

void SGOpenURL(NSString *url) {
    NSURL *target = url ? [NSURL URLWithString:url] : nil;
    if (!target) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:target options:@{} completionHandler:nil];
    });
}
