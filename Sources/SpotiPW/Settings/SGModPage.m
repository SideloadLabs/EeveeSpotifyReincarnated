#import <CoreText/SFNTLayoutTypes.h>
#import "SGModPage.h"
#import "SGPageStyle.h"
#import "SGGlowSwitch.h"
#import "Core/SGCore.h"

NSString *const SGRestartNote = @"Changes apply after you restart Spotify.";

@implementation SGModRow
@end

@implementation SGModSection
@end

SGModRow *SGSwitchRow(NSString *title, NSString *subtitle, NSString *key) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.key = key;
    row.defaultOn = YES;
    return row;
}

SGModRow *SGHideRow(NSString *title, NSString *subtitle, NSString *key) {
    SGModRow *row = SGSwitchRow(title, subtitle, key);
    row.defaultOn = NO;
    return row;
}

// A switch for something the mod adds rather than takes away: off until it is asked for.
SGModRow *SGOptionRow(NSString *title, NSString *subtitle, NSString *key) {
    SGModRow *row = SGSwitchRow(title, subtitle, key);
    row.defaultOn = NO;
    return row;
}

// A switch whose work is not finished: turning it on says so first, and offers the repo to anyone
// who would rather fix it than live with it.
SGModRow *SGUnstableRow(NSString *title, NSString *subtitle, NSString *key, NSString *warning) {
    SGModRow *row = SGSwitchRow(title, subtitle, key);
    row.warning = warning;
    return row;
}

SGModRow *SGFlagRow(NSString *title, NSString *key) {
    SGModRow *row = SGHideRow(title, nil, key);
    row.flag = YES;
    return row;
}

// A flag Spotify ships on: the switch forces it off.
SGModRow *SGKillRow(NSString *title, NSString *key) {
    SGModRow *row = SGFlagRow(title, key);
    row.forceOff = YES;
    return row;
}

SGModRow *SGStatRow(NSString *title, NSString *(^value)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.value = value;
    return row;
}

SGModRow *SGActionRow(NSString *title, NSString *subtitle, void (^action)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.action = action;
    return row;
}

// Red, with a warning symbol. SGFillCell tints the title and the symbol; the cell below takes the
// colour down to the subtitle too, so the whole row reads as the warning it is.
SGModRow *SGWarningRow(NSString *title, NSString *subtitle, void (^action)(void)) {
    SGModRow *row = SGActionRow(title, subtitle, action);
    row.color = SGRed();
    row.symbol = @"exclamationmark.triangle.fill";
    return row;
}

// No subtitle: a list of pages reads as a list, not as a wall of explanations.
SGModRow *SGPageRow(NSString *title, UIViewController *(^page)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.page = page;
    return row;
}

// The list a choice row opens: the names it was given, each over its note where it has one, a green
// checkmark against the one set. Picking one writes the index, tells the row, and goes back, where the row
// it came from reads the new name out and the page it sits on rebuilds around it.
@interface SGChoicePage : SGPage
- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key choices:(NSArray<NSString *> *)choices notes:(NSArray<NSString *> *)notes
                       footer:(NSString *)footer fallback:(NSInteger)fallback chosen:(void (^)(NSInteger index))chosen;
@end

@implementation SGChoicePage {
    NSString *_key;
    NSArray<NSString *> *_choices, *_notes;
    NSInteger _fallback;
    void (^_chosen)(NSInteger index);
    UIView *_footer;
}

- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key choices:(NSArray<NSString *> *)choices notes:(NSArray<NSString *> *)notes
                       footer:(NSString *)footer fallback:(NSInteger)fallback chosen:(void (^)(NSInteger index))chosen {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = title;
    _key = key;
    _choices = choices;
    _notes = notes;
    _fallback = fallback;
    _chosen = chosen;
    _footer = footer ? SGNote(footer) : nil;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (_footer) SGFitNote(self.tableView, _footer, 16, 24);
}


- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_choices.count;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"choice");
    NSUInteger index = (NSUInteger)path.row;
    SGFillCell(cell, _choices[index], index < _notes.count ? _notes[index] : nil, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (path.row == SGInt(_key, _fallback)) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    SGSetInt(_key, path.row);
    if (_chosen) _chosen(path.row);
    [table reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// No key on the row: the key lives in the blocks, so the page draws the row as the link it is
// rather than as a switch. The notes and the callback are read off the row when its list opens, so they
// can be set after this returns.
SGModRow *SGChoiceRow(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.value = ^NSString *{
        NSInteger index = SGInt(key, fallback);
        return index >= 0 && index < (NSInteger)choices.count ? choices[(NSUInteger)index] : choices.firstObject;
    };
    __weak SGModRow *weakRow = row;
    row.page = ^UIViewController *{
        return [[SGChoicePage alloc] initWithTitle:title key:key choices:choices notes:weakRow.choiceNotes footer:weakRow.choiceFooter fallback:fallback chosen:weakRow.chosen];
    };
    return row;
}

SGModRow *SGSliderRow(NSString *title, NSString *subtitle, double minimum, double maximum, double step,
                      double (^get)(void), void (^set)(double value), NSString *(^format)(double value)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.minimum = minimum;
    row.maximum = maximum;
    row.step = step;
    row.number = get;
    row.setNumber = set;
    row.format = format;
    return row;
}

SGModRow *SGLinkRow(NSString *title, NSString *subtitle, NSString *url) {
    return SGActionRow(title, subtitle, ^{ SGOpenURL(url); });
}

// A value on the right and a tap: the Updates row reads its status out of About/Update.m every tick,
// and a tap asks the site again instead of waiting for the six hour cache to lapse.
SGModRow *SGStatActionRow(NSString *title, NSString *subtitle, NSString *(^value)(void), void (^action)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.value = value;
    row.action = action;
    return row;
}

SGModSection *SGSection(NSString *title, NSArray<SGModRow *> *rows) {
    SGModSection *s = [SGModSection new];
    s.title = title;
    s.rows = rows;
    return s;
}

SGModSection *SGNotedSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer) {
    SGModSection *s = SGSection(title, rows);
    s.footer = footer;
    return s;
}

SGModRow *SGWithSymbol(SGModRow *row, NSString *symbol) {
    row.symbol = symbol;
    return row;
}

// What a page row carrying a value shows on the right: the value, then the chevron, the same
// distance apart as Spotify's own rows keep them.
static UIView *valueAndChevron(NSString *text) {
    UILabel *label = [UILabel new];
    label.font = SGTitleFont();
    label.textColor = SGGrey();
    label.text = text;
    [label sizeToFit];
    UIImageView *chevron = SGSymbolView(@"chevron.right", 13, UIImageSymbolWeightSemibold, 16);
    CGFloat height = MAX(label.bounds.size.height, chevron.bounds.size.height);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, label.bounds.size.width + 6 + chevron.bounds.size.width, height)];
    label.center = CGPointMake(label.bounds.size.width / 2, height / 2);
    chevron.center = CGPointMake(box.bounds.size.width - chevron.bounds.size.width / 2, height / 2);
    [box addSubview:label];
    [box addSubview:chevron];
    return box;
}

// On means the row's own override is in place; anything else, including the opposite override
// somebody set from the All flags page, reads as off.
static BOOL flagRowOn(SGModRow *row) {
    id value = SGFlagOverride(row.key);
    return value && [value boolValue] != row.forceOff;
}

// A flag something of the mod's forces (Core/SGFlagForce.h: the redesign, the Search switches): its row
// shows what is forced and takes no touch, so the flag has one place to change.
static BOOL flagRowLocked(SGModRow *row) {
    return row.flag && SGLockedFlagValue(row.key, NULL) != nil;
}

// What a locked row shows: the forced value, read the row's way, so a Disable Canvas row reads on
// while Canvas is forced off.
static BOOL lockedRowOn(SGModRow *row) {
    id value = SGLockedFlagValue(row.key, NULL);
    return value ? [value boolValue] != row.forceOff : YES;
}

#pragma mark - the slider row

// On the row's step, counted from its minimum, without the float noise of getting there.
static double snapped(SGModRow *row, double value) {
    if (row.step > 0) value = row.minimum + round(round((value - row.minimum) / row.step) * row.step * 1e6) / 1e6;
    return MAX(row.minimum, MIN(row.maximum, value));
}

// Figures that do not shift sideways as they change, in whatever face the titles are in.
static UIFont *tabular(UIFont *font) {
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorByAddingAttributes:@{
        UIFontDescriptorFeatureSettingsAttribute: @[@{UIFontFeatureTypeIdentifierKey: @(kNumberSpacingType),
                                                     UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)}],
    }];
    return [UIFont fontWithDescriptor:descriptor size:font.pointSize];
}

// A step at a time for VoiceOver, or a twentieth of the range where the steps are too fine to swipe through.
@interface SGModSlider : UISlider
@property (nonatomic) float spokenStep;
@end

@implementation SGModSlider

- (void)accessibilityIncrement {
    self.value += self.spokenStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)accessibilityDecrement {
    self.value -= self.spokenStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

@end

// The Audio effects page's slider row (Shared/AudioEffects/AudioEffectsPage.m), for any page: the title and the
// value over a slider in the accent colour, a subtitle between them when there is one, each step stored
// as the thumb reaches it.
@interface SGModSliderCell : UITableViewCell
+ (CGFloat)heightFor:(SGModRow *)row;
- (void)showRow:(SGModRow *)row;
@end

@implementation SGModSliderCell {
    SGModRow *_row;
    UILabel *_title, *_subtitle, *_value;
    SGModSlider *_slider;
    double _shown;
    BOOL _detents;   // few enough steps that the thumb jumps between them as it is dragged
}

static const CGFloat kSliderTop = 12, kSliderLine = 18, kSliderSubtitle = 14, kSliderGap = 6, kSliderHeight = 28, kSliderBottom = 10;

+ (CGFloat)heightFor:(SGModRow *)row {
    return kSliderTop + kSliderLine + (row.subtitle ? kSliderSubtitle : 0) + kSliderGap + kSliderHeight + kSliderBottom;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:identifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _title = [UILabel new];
    _title.textColor = UIColor.whiteColor;
    _title.isAccessibilityElement = NO;
    _subtitle = [UILabel new];
    _subtitle.textColor = SGGrey();
    _subtitle.isAccessibilityElement = NO;
    _value = [UILabel new];
    _value.textColor = SGGrey();
    _value.textAlignment = NSTextAlignmentRight;
    _value.isAccessibilityElement = NO;
    _slider = [SGModSlider new];
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.16];
    [_slider addTarget:self action:@selector(moved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    for (UIView *view in @[_title, _subtitle, _value, _slider]) [self.contentView addSubview:view];
    return self;
}

- (void)showRow:(SGModRow *)row {
    _row = row;
    NSInteger count = row.step > 0 ? (NSInteger)lround((row.maximum - row.minimum) / row.step) : 0;
    _detents = count > 0 && count <= 24;
    _title.font = SGTitleFont();
    _subtitle.font = SGSubtitleFont();
    _value.font = tabular(SGTitleFont());
    _title.text = row.title;
    _subtitle.text = row.subtitle;
    _subtitle.hidden = !row.subtitle;
    _slider.minimumTrackTintColor = SGGreen();
    _slider.minimumValue = (float)row.minimum;
    _slider.maximumValue = (float)row.maximum;
    _slider.spokenStep = (float)(count > 0 && count <= 40 ? row.step : snapped(row, row.minimum + (row.maximum - row.minimum) / 20) - row.minimum);
    _shown = snapped(row, row.number());
    _slider.value = (float)_shown;
    _slider.accessibilityLabel = row.title;
    _slider.accessibilityHint = row.subtitle;
    [self showValue];
}

- (void)showValue {
    _value.text = _row.format ? _row.format(_shown) : [NSString stringWithFormat:@"%g", _shown];
    _slider.accessibilityValue = _value.text;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, side = 16, y = kSliderTop;
    [_value sizeToFit];
    CGFloat valueWidth = MAX(_value.bounds.size.width, 44);
    _value.frame = CGRectMake(width - side - valueWidth, y, valueWidth, kSliderLine);
    _title.frame = CGRectMake(side, y, CGRectGetMinX(_value.frame) - side - 8, kSliderLine);
    y += kSliderLine;
    if (_row.subtitle) {
        _subtitle.frame = CGRectMake(side, y, width - 2 * side, kSliderSubtitle);
        y += kSliderSubtitle;
    }
    _slider.frame = CGRectMake(side, y + kSliderGap, width - 2 * side, kSliderHeight);
}

- (void)moved {
    double value = snapped(_row, _slider.value);
    if (_detents) _slider.value = (float)value;
    if (value == _shown) return;
    _shown = value;
    if (_row.setNumber) _row.setNumber(value);
    [self showValue];
}

- (void)released {
    [_slider setValue:(float)_shown animated:YES];
}

@end

#pragma mark - the page

@implementation SGModPage {
    NSArray<SGModSection *> *_sections;
    NSArray<NSArray<SGModRow *> *> *_shown;   // each section's rows that show now (SGModRow.visible)
    UIView *_intro;
    UIView *_footer;
    NSTimer *_ticker;
    BOOL _live;
}

- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro sections:(NSArray<SGModSection *> *)sections footer:(NSString *)footer {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = title;
    _sections = sections;
    _shown = [self rowsToShow];
    _intro = intro ? SGNote(intro) : nil;
    _footer = footer ? SGNote(footer) : nil;
    // A page row reads its value out when the page appears rather than on the ticker, so only the
    // rows whose numbers climb on their own keep one running.
    for (SGModSection *s in sections) for (SGModRow *row in s.rows) _live |= row.value && !row.page;
    return self;
}

- (NSArray<NSArray<SGModRow *> *> *)rowsToShow {
    NSMutableArray<NSArray<SGModRow *> *> *shown = [NSMutableArray arrayWithCapacity:_sections.count];
    for (SGModSection *s in _sections) {
        NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithCapacity:s.rows.count];
        for (SGModRow *row in s.rows) if (!row.visible || row.visible()) [rows addObject:row];
        [shown addObject:rows];
    }
    return shown;
}

// The rows that are to show now fade in where they sit and the others fade out, and whatever came in is
// scrolled into view: it opens under the switch that brought it, which may be the page's last row. Answers
// whether anything moved; `done` runs once it has, and only then.
- (BOOL)showRowsThen:(void (^)(void))done {
    NSArray<NSArray<SGModRow *> *> *next = [self rowsToShow];
    if ([next isEqualToArray:_shown]) return NO;
    NSMutableArray<NSIndexPath *> *gone = [NSMutableArray array], *coming = [NSMutableArray array];
    [_sections enumerateObjectsUsingBlock:^(SGModSection *s, NSUInteger section, BOOL *stop) {
        NSArray<SGModRow *> *before = self->_shown[section], *after = next[section];
        [before enumerateObjectsUsingBlock:^(SGModRow *row, NSUInteger i, BOOL *stop) {
            if (![after containsObject:row]) [gone addObject:[NSIndexPath indexPathForRow:(NSInteger)i inSection:(NSInteger)section]];
        }];
        [after enumerateObjectsUsingBlock:^(SGModRow *row, NSUInteger i, BOOL *stop) {
            if (![before containsObject:row]) [coming addObject:[NSIndexPath indexPathForRow:(NSInteger)i inSection:(NSInteger)section]];
        }];
    }];
    UITableView *table = self.tableView;
    [table performBatchUpdates:^{
        self->_shown = next;
        [table deleteRowsAtIndexPaths:gone withRowAnimation:UITableViewRowAnimationFade];
        [table insertRowsAtIndexPaths:coming withRowAnimation:UITableViewRowAnimationFade];
    } completion:^(BOOL finished) {
        if (coming.count) {
            CGRect rows = CGRectNull;
            for (NSIndexPath *path in coming) rows = CGRectUnion(rows, [table rectForRowAtIndexPath:path]);
            CGFloat room = table.bounds.size.height - table.adjustedContentInset.top - table.adjustedContentInset.bottom;
            rows.size.height = MIN(rows.size.height, room);
            [table scrollRectToVisible:rows animated:YES];
        }
        if (done) done();
    }];
    return YES;
}

// The row a switch or an ⓘ belongs to, by the cell it sits in: rows coming and going move the rows under
// them, so a position remembered when the cell was made may be stale.
- (NSIndexPath *)pathOf:(UIView *)control {
    UIView *view = control;
    while (view && ![view isKindOfClass:UITableViewCell.class]) view = view.superview;
    return view ? [self.tableView indexPathForCell:(UITableViewCell *)view] : nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableHeaderView = _intro;
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (_intro) SGFitNote(self.tableView, _intro, 24, 0);
    if (_footer) SGFitNote(self.tableView, _footer, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Reloaded whether or not anything ticks: a choice row is showing whatever was picked on the
    // page it opened, which is gone by the time this one comes back, and may bring rows or take them.
    _shown = [self rowsToShow];
    [self.tableView reloadData];
    if (!_live) return;
    // The counters climb while the page is open; the labels are written straight into the cells so
    // that a reload never lands under a switch being dragged. A cancelled back swipe appears the
    // page again without it ever disappearing, so the old timer goes first.
    [_ticker invalidate];
    _ticker = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(readValues) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_ticker invalidate];
    _ticker = nil;
}

- (void)readValues {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        SGModRow *row = [self rowAt:[self.tableView indexPathForCell:cell]];
        UILabel *label = (UILabel *)cell.accessoryView;
        if (!row.value || row.page || ![label isKindOfClass:UILabel.class]) continue;
        label.text = row.value();
        [label sizeToFit];
        [cell setNeedsLayout];
    }
}

- (SGModRow *)rowAt:(NSIndexPath *)path {
    return _shown[(NSUInteger)path.section][(NSUInteger)path.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_shown[(NSUInteger)section].count;
}

// A slider row is laid out by hand; every other row sizes itself.
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    SGModRow *row = [self rowAt:path];
    return row.number ? [SGModSliderCell heightFor:row] : UITableViewAutomaticDimension;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    NSString *title = _sections[(NSUInteger)section].title;
    return title ? SGSectionHeader(table, title) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return _sections[(NSUInteger)section].title ? SGSectionHeaderHeight : SGSectionGap;
}

- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    NSString *footer = _sections[(NSUInteger)section].footer;
    return footer ? SGSectionFooter(table, footer) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    NSString *footer = _sections[(NSUInteger)section].footer;
    return footer ? SGSectionFooterHeight(table, footer) : CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    SGModRow *row = [self rowAt:path];
    if (row.number) {
        SGModSliderCell *cell = [table dequeueReusableCellWithIdentifier:@"slider"] ?: [[SGModSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"slider"];
        cell.backgroundColor = SGCardBackground();
        [cell showRow:row];
        return cell;
    }
    UITableViewCell *cell = SGDequeueCell(table, @"row");
    SGFillCell(cell, row.title, row.subtitle, row.color, row.symbol);
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    if (row.color) content.secondaryTextProperties.color = row.color;
    BOOL tile = row.symbol && !row.color;
    if (tile) content.image = SGTileImage(row.symbol);
    cell.contentConfiguration = content;
    cell.separatorInset = UIEdgeInsetsMake(0, row.symbol ? (tile ? 58 : 48) : 16, 0, 0);

    if (row.key) {
        BOOL locked = flagRowLocked(row);
        // A lock that beats an override shows over one; the others give way to it.
        BOOL beats = NO;
        if (locked) SGLockedFlagValue(row.key, &beats);
        BOOL showsLock = locked && (beats || !SGFlagOverride(row.key));
        BOOL on = row.flag ? (showsLock ? lockedRowOn(row) : flagRowOn(row)) : SGFlag(row.key, row.defaultOn);
        UIControl *toggle;
        if (row.glows) {
            SGGlowSwitch *glow = [SGGlowSwitch new];
            glow.on = on;
            glow.accessibilityLabel = row.title;
            toggle = glow;
        } else {
            UISwitch *plain = [UISwitch new];
            plain.onTintColor = SGGreen();
            plain.on = on;
            toggle = plain;
        }
        toggle.enabled = !locked;
        // A disabled switch would swallow the tap; letting it through is what gets the row asked.
        toggle.userInteractionEnabled = !locked;
        [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = row.info ? [self infoButtonBeside:toggle] : toggle;
        cell.selectionStyle = locked ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (row.page) {
        cell.accessoryView = row.value ? valueAndChevron(row.value()) : SGSymbolView(@"chevron.right", 13, UIImageSymbolWeightSemibold, 16);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (row.value) {
        UILabel *label = [UILabel new];
        label.font = SGTitleFont();
        label.textColor = SGGrey();
        label.text = row.value();
        [label sizeToFit];
        cell.accessoryView = label;
        cell.selectionStyle = row.action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (row.action) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    SGModRow *row = [self rowAt:path];
    if (flagRowLocked(row)) {
        [table deselectRowAtIndexPath:path animated:YES];
        [self explainLock];
        return;
    }
    if (row.page) [self.navigationController pushViewController:row.page() animated:YES];
    if (!row.action) return;
    row.action();
    [table deselectRowAtIndexPath:path animated:YES];
    [self readValues];
}

// The ⓘ to the left of the switch, the grey of a subtitle, 30pt across so it is easy to hit next to it.
- (UIView *)infoButtonBeside:(UIControl *)toggle {
    UIButton *info = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
    [info setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:symbol] forState:UIControlStateNormal];
    info.tintColor = SGGrey();
    info.accessibilityLabel = @"About this switch";
    [info addTarget:self action:@selector(infoTapped:) forControlEvents:UIControlEventTouchUpInside];
    [toggle sizeToFit];
    CGFloat side = 30, gap = 8, height = MAX(side, toggle.bounds.size.height);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side + gap + toggle.bounds.size.width, height)];
    info.frame = CGRectMake(0, (height - side) / 2, side, side);
    toggle.frame = CGRectMake(side + gap, (height - toggle.bounds.size.height) / 2, toggle.bounds.size.width, toggle.bounds.size.height);
    [box addSubview:info];
    [box addSubview:toggle];
    return box;
}

- (void)infoTapped:(UIButton *)button {
    NSIndexPath *path = [self pathOf:button];
    if (!path) return;
    SGModRow *row = [self rowAt:path];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:row.title message:row.info preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// A UISwitch or an SGGlowSwitch, both answering isOn.
- (void)toggled:(UIControl *)toggle {
    BOOL on = [(UISwitch *)toggle isOn];
    NSIndexPath *path = [self pathOf:toggle];
    if (!path) return;
    SGModRow *row = [self rowAt:path];
    if (row.flag) SGSetFlagOverride(row.key, on ? @(!row.forceOff) : nil);
    else SGSetEnabled(row.key, on);
    if (row.changed) row.changed(on);
    // A glowing switch is let finish its slide before the reload puts a new one in its place; rows coming
    // or going are let finish first too.
    NSTimeInterval wait = [toggle isKindOfClass:SGGlowSwitch.class] ? 0.45 : 0;
    void (^reload)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
    };
    BOOL moved = [self showRowsThen:row.changed ? reload : nil];
    if (row.changed && !moved) reload();
    if (on && row.warning) [self warn:row];
}

// A locked row will not move, and nothing on it says why.
- (void)explainLock {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Overridden by another setting"
                         message:@"Another switch is forcing this flag, so the row shows what it forces instead of taking a value of its own."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)warn:(SGModRow *)row {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[row.title stringByAppendingString:@" is unstable"]
                                                                  message:row.warning
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SGOpenURL(SGRepoURL);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
