// The Audio effects page. It is not an SGModPage: its sliders store as they move, its cards open out
// into their controls as their switches go on, and its status line and the effects' errors come and go
// while it is open, none of which a page of fixed rows does. It keeps Settings/'s look all the same: the
// cards, the 13pt titles over 11pt subtitles, the tiles, the value and the chevron, the checkmark lists.
#import <CoreText/SFNTLayoutTypes.h>
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "AudioEffectsPage.h"
#import "SGDSPCurveView.h"

typedef NS_ENUM(NSInteger, SGDSPRowKind) {
    SGDSPRowSlider,   // a number, stored as the slider moves
    SGDSPRowChoice,   // one of a list of names, stored as its index
    SGDSPRowPage,     // a page of its own, its value beside the chevron
    SGDSPRowCurve,    // the equalizer's or the compressor's gains
};

@interface SGDSPRow : NSObject
@property (nonatomic) SGDSPRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *unit;
@property (nonatomic, copy) NSArray<NSString *> *names;   // a choice's, or what a slider's steps read as
@property (nonatomic) double scale;                        // what a slider's stored number is shown times
@property (nonatomic, copy) NSString *(^value)(void);
@property (nonatomic, copy) UIViewController *(^page)(void);
@end

@implementation SGDSPRow
@end

// An effect's card: the switch at its head and the rows it opens out into while the switch is on.
@interface SGDSPEffect : NSObject
@property (nonatomic, copy) NSString *key;   // the switch; nil for output control, which is always on
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSArray<SGDSPRow *> *rows;
@end

@implementation SGDSPEffect
@end

#pragma mark - the effects

static SGDSPRow *row(SGDSPRowKind kind, NSString *title, NSString *key) {
    SGDSPRow *row = [SGDSPRow new];
    row.kind = kind;
    row.title = title;
    row.key = key;
    row.scale = 1;
    return row;
}

static SGDSPRow *slider(NSString *title, NSString *key, NSString *unit) {
    SGDSPRow *r = row(SGDSPRowSlider, title, key);
    r.unit = unit;
    return r;
}

static SGDSPRow *choice(NSString *title, NSString *key, NSArray<NSString *> *names) {
    SGDSPRow *r = row(SGDSPRowChoice, title, key);
    r.names = names;
    return r;
}

static SGDSPRow *pageRow(NSString *title, NSString *(^value)(void), UIViewController *(^page)(void)) {
    SGDSPRow *r = row(SGDSPRowPage, title, nil);
    r.value = value;
    r.page = page;
    return r;
}

static SGDSPRow *fileRow(NSString *title, SGDSPFileKind kind) {
    return pageRow(title, ^NSString *{ return SGDSPChosenFile(kind); }, ^UIViewController *{ return SGDSPLibraryPage(kind); });
}

static SGDSPEffect *effect(NSString *key, NSString *title, NSString *subtitle, NSString *symbol, NSArray<SGDSPRow *> *rows) {
    SGDSPEffect *e = [SGDSPEffect new];
    e.key = key;
    e.title = title;
    e.subtitle = subtitle;
    e.symbol = symbol;
    e.rows = rows;
    return e;
}

// The response's points, or Flat when every gain is zero, the way the stored text reads before anything is pasted.
static NSString *graphicEqSummary(void) {
    NSString *text = SGDSPString(SGKeyDSPGraphicEqNodes);
    NSRange colon = [text rangeOfString:@":"];
    if (colon.location != NSNotFound) text = [text substringFromIndex:colon.location + 1];
    NSUInteger points = 0;
    BOOL flat = YES;
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *pair in [text componentsSeparatedByString:@";"]) {
        NSArray<NSString *> *parts = [[pair stringByTrimmingCharactersInSet:space] componentsSeparatedByCharactersInSet:space];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count != 2) continue;
        points++;
        flat &= parts[1].doubleValue == 0;
    }
    return flat ? @"Flat" : [NSString stringWithFormat:@"%lu points", (unsigned long)points];
}

// The effects' cards. The engine runs them in an order of its own (SGDSPEngine.m).
static NSArray<SGDSPEffect *> *effects(void) {
    // Stored as 0 to 100 around 50, shown as the side's level, 100% leaving it as it is.
    SGDSPRow *width = slider(@"Width", SGKeyDSPStereoWideLevel, @"%");
    width.scale = 2;
    return @[
        effect(nil, @"Output control", @"Gain and limiter, always on", @"speaker.wave.2", @[
            slider(@"Post gain", SGKeyDSPPostGain, @" dB"),
            slider(@"Limiter threshold", SGKeyDSPLimiterThreshold, @" dB"),
            slider(@"Limiter release", SGKeyDSPLimiterRelease, @" ms"),
        ]),
        effect(SGKeyDSPCompander, @"Multiband compander", @"Evens out or livens up the dynamics", @"rectangle.compress.vertical", @[
            row(SGDSPRowCurve, nil, SGKeyDSPCompanderGains),
            slider(@"Release", SGKeyDSPCompanderTime, @" s"),
        ]),
        effect(SGKeyDSPBass, @"Bass boost", @"Lifts the low end", @"hifispeaker", @[
            slider(@"Maximum gain", SGKeyDSPBassGain, @" dB"),
        ]),
        effect(SGKeyDSPEqualizer, @"Equalizer", @"15 bands, with presets", @"slider.vertical.3", @[
            row(SGDSPRowCurve, nil, SGKeyDSPEqualizerGains),
        ]),
        effect(SGKeyDSPGraphicEq, @"Graphic EQ", @"Any curve, like AutoEq's corrections", @"chart.xyaxis.line", @[
            pageRow(@"Response", ^NSString *{ return graphicEqSummary(); }, ^UIViewController *{ return SGDSPGraphicEqPage(); }),
        ]),
        effect(SGKeyDSPConvolver, @"Convolver", @"Recorded rooms and speakers", @"waveform.path", @[
            fileRow(@"Impulse response", SGDSPFileImpulseResponse),
            choice(@"Optimization", SGKeyDSPConvolverMode, SGDSPConvolverModeNames()),
        ]),
        effect(SGKeyDSPDDC, @"ViPER DDC", @"Headphone correction files", @"headphones", @[
            fileRow(@"DDC file", SGDSPFileDDC),
        ]),
        effect(SGKeyDSPLiveprog, @"Liveprog", @"Effects written as EEL scripts", @"chevron.left.forwardslash.chevron.right", @[
            fileRow(@"Script", SGDSPFileLiveprog),
        ]),
        effect(SGKeyDSPReverb, @"Reverb", @"A room around the music", @"building.columns", @[
            choice(@"Room", SGKeyDSPReverbPreset, SGDSPReverbPresetNames()),
        ]),
        effect(SGKeyDSPStereoWide, @"Stereo widening", @"A wider or narrower stereo image", @"arrow.left.and.right", @[
            width,
        ]),
        effect(SGKeyDSPCrossfeed, @"Crossfeed", @"Softer stereo on headphones", @"ear", @[
            choice(@"Preset", SGKeyDSPCrossfeedMode, SGDSPCrossfeedModeNames()),
        ]),
        effect(SGKeyDSPTube, @"Analog modelling", @"Tube amplifier warmth", @"flame", @[
            slider(@"Drive", SGKeyDSPTubeDrive, @" dB"),
        ]),
    ];
}

// The effects whose last change can fail, each reporting why under its own switch key.
static NSSet<NSString *> *reportingEffects(void) {
    return [NSSet setWithArray:@[SGKeyDSPGraphicEq, SGKeyDSPConvolver, SGKeyDSPDDC, SGKeyDSPLiveprog]];
}

NSString *SGDSPSummary(void) {
    if (!SGDSPSwitch(SGKeyDSP)) return @"Off";
    NSUInteger on = 0;
    for (SGDSPEffect *e in effects()) on += e.key && SGDSPSwitch(e.key);
    if (!on) return @"On";
    return on == 1 ? @"1 effect" : [NSString stringWithFormat:@"%lu effects", (unsigned long)on];
}

#pragma mark - numbers

// On the step's grid (every range starts on it), without the float noise of getting there.
static double snapped(NSString *key, double value) {
    SGDSPRange range = SGDSPRangeFor(key);
    if (range.step > 0) value = round(round(value / range.step) * range.step * 1e6) / 1e6;
    return MAX(range.min, MIN(range.max, value));
}

// "−3.5 dB", "+2 dB", "60 ms", "0.22 s", "60%": the step's decimals unless the number is whole, a sign
// where the range runs both ways, and a real minus.
static NSString *numberText(SGDSPRow *row, double value) {
    if (row.names.count) {
        NSInteger index = (NSInteger)lround(value);
        return row.names[(NSUInteger)MAX(0, MIN((NSInteger)row.names.count - 1, index))];
    }
    SGDSPRange range = SGDSPRangeFor(row.key);
    double step = range.step * row.scale;
    value *= row.scale;
    int decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : 2;
    if (fabs(value - round(value)) < 1e-6) decimals = 0;
    NSString *number = [NSString stringWithFormat:@"%.*f", decimals, fabs(value)];
    NSString *sign = number.doubleValue == 0 ? @"" : value < 0 ? @"−" : range.min < 0 && range.max > 0 ? @"+" : @"";
    return [NSString stringWithFormat:@"%@%@%@", sign, number, row.unit ?: @""];
}

// Figures that do not shift sideways as they change, in whatever face the titles are in.
static UIFont *tabular(UIFont *font) {
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorByAddingAttributes:@{
        UIFontDescriptorFeatureSettingsAttribute: @[@{UIFontFeatureTypeIdentifierKey: @(kNumberSpacingType),
                                                     UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)}],
    }];
    return [UIFont fontWithDescriptor:descriptor size:font.pointSize];
}

#pragma mark - the slider row

// A step at a time for VoiceOver, or a twentieth of the range where the steps are too fine to swipe through.
@interface SGDSPSlider : UISlider
@property (nonatomic) float spokenStep;
@end

@implementation SGDSPSlider

- (void)accessibilityIncrement {
    self.value += self.spokenStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)accessibilityDecrement {
    self.value -= self.spokenStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

@end

// The title and the value over a slider in the accent colour, storing each step as the thumb reaches it.
@interface SGDSPSliderCell : UITableViewCell
- (void)showRow:(SGDSPRow *)row;
@end

@implementation SGDSPSliderCell {
    SGDSPRow *_row;
    UILabel *_title, *_value;
    SGDSPSlider *_slider;
    double _shown;
    BOOL _detents;   // few enough steps that the thumb jumps between them as it is dragged
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:identifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _title = [UILabel new];
    _title.textColor = UIColor.whiteColor;
    _title.isAccessibilityElement = NO;
    _value = [UILabel new];
    _value.textColor = SGGrey();
    _value.textAlignment = NSTextAlignmentRight;
    _value.isAccessibilityElement = NO;
    _slider = [SGDSPSlider new];
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.16];
    [_slider addTarget:self action:@selector(moved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    for (UIView *view in @[_title, _value, _slider]) [self.contentView addSubview:view];
    return self;
}

- (void)showRow:(SGDSPRow *)row {
    _row = row;
    SGDSPRange range = SGDSPRangeFor(row.key);
    NSInteger count = range.step > 0 ? (NSInteger)lround((range.max - range.min) / range.step) : 0;
    _detents = count > 0 && count <= 24;
    _title.font = SGTitleFont();
    _value.font = tabular(SGTitleFont());
    _title.text = row.title;
    _slider.minimumTrackTintColor = SGGreen();
    _slider.minimumValue = (float)range.min;
    _slider.maximumValue = (float)range.max;
    _slider.spokenStep = (float)(count > 0 && count <= 40 ? range.step : snapped(row.key, range.min + (range.max - range.min) / 20) - range.min);
    _shown = SGDSPNumber(row.key);
    _slider.value = (float)_shown;
    _slider.accessibilityLabel = row.title;
    [self showValue];
}

- (void)showValue {
    _value.text = numberText(_row, _shown);
    _slider.accessibilityValue = _value.text;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, side = 16;
    [_value sizeToFit];
    CGFloat valueWidth = MAX(_value.bounds.size.width, 44);
    _value.frame = CGRectMake(width - side - valueWidth, 12, valueWidth, 18);
    _title.frame = CGRectMake(side, 12, CGRectGetMinX(_value.frame) - side - 8, 18);
    _slider.frame = CGRectMake(side, 36, width - 2 * side, 28);
}

- (void)moved {
    double value = snapped(_row.key, _slider.value);
    if (_detents) _slider.value = (float)value;
    if (value == _shown) return;
    _shown = value;
    SGDSPSetNumber(_row.key, value);
    [self showValue];
}

- (void)released {
    [_slider setValue:(float)_shown animated:YES];
}

@end

#pragma mark - the curve row

@interface SGDSPCurveCell : UITableViewCell
@property (nonatomic, strong) SGDSPCurveView *curve;
@end

@implementation SGDSPCurveCell
- (void)layoutSubviews {
    [super layoutSubviews];
    self.curve.frame = self.contentView.bounds;
}
@end

#pragma mark - a choice's list

// The names a choice picks from, a checkmark against the one set. Unlike Settings' own list it stays
// open after a pick, so one reverb room after another can be heard before going back.
@interface SGDSPChoicePage : SGPage
- (instancetype)initWithRow:(SGDSPRow *)row;
@end

@implementation SGDSPChoicePage {
    SGDSPRow *_row;
}

- (instancetype)initWithRow:(SGDSPRow *)row {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = row.title;
    _row = row;
    return self;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_row.names.count;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return SGSectionGap;
}

- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"choice");
    SGFillCell(cell, _row.names[(NSUInteger)path.row], nil, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    BOOL chosen = path.row == (NSInteger)lround(SGDSPNumber(_row.key));
    if (chosen) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    cell.accessibilityTraits = chosen ? UIAccessibilityTraitButton | UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGDSPSetNumber(_row.key, path.row);
    [table reloadRowsAtIndexPaths:table.indexPathsForVisibleRows withRowAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - the page

// The value and the chevron of a row opening a page, as Settings' own rows draw them.
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

@interface SGDSPPage : SGPage
@end

@implementation SGDSPPage {
    NSArray<SGDSPEffect *> *_effects;
    NSMutableSet<NSString *> *_open;                          // the effects showing their rows
    NSMutableDictionary<NSString *, NSString *> *_errors;     // the errors showing, by switch key
    UIView *_intro;
    UIView *_credits;
    UITextView *_creditsText;
    NSTimer *_ticker;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Audio effects";
    _effects = effects();
    _open = [NSMutableSet set];
    _errors = [NSMutableDictionary dictionary];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _intro = SGNote(@"Changes apply straight away.");
    self.tableView.tableHeaderView = _intro;
    [self buildCredits];
    self.tableView.tableFooterView = _credits;
}

// The libraries two of the effects run on, in the grey of a note with the names as links.
- (void)buildCredits {
    NSDictionary *grey = @{NSFontAttributeName: SGSubtitleFont(), NSForegroundColorAttributeName: SGGrey()};
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:@"Crossfeed is " attributes:grey];
    NSArray<NSArray<NSString *> *> *parts = @[
        @[@"libbs2b", @"https://github.com/alexmarsev/libbs2b"], @[@" by Boris Mikhaylov. Liveprog runs on ", @""],
        @[@"EEL2", @"https://github.com/justinfrankel/WDL"], @[@", from Cockos' WDL.", @""],
    ];
    for (NSArray<NSString *> *part in parts) {
        NSMutableDictionary *attributes = [grey mutableCopy];
        if (part[1].length) attributes[NSLinkAttributeName] = [NSURL URLWithString:part[1]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:part[0] attributes:attributes]];
    }
    _creditsText = [UITextView new];
    _creditsText.attributedText = text;
    _creditsText.editable = NO;
    _creditsText.scrollEnabled = NO;
    _creditsText.backgroundColor = UIColor.clearColor;
    _creditsText.textContainerInset = UIEdgeInsetsZero;
    _creditsText.textContainer.lineFragmentPadding = 0;
    _creditsText.linkTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    _credits = [UIView new];
    [_credits addSubview:_creditsText];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _intro, 24, 0);
    // SGFitNote's way, for a text view rather than a label.
    UITableView *table = self.tableView;
    CGFloat inset = table.layoutMargins.left, width = table.bounds.size.width - 2 * inset;
    CGFloat height = ceil([_creditsText sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    _creditsText.frame = CGRectMake(inset, 16, width, height);
    CGSize size = CGSizeMake(table.bounds.size.width, 16 + height + 24);
    if (CGSizeEqualToSize(_credits.bounds.size, size)) return;
    _credits.frame = (CGRect){_credits.frame.origin, size};
    table.tableFooterView = _credits;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // A choice, a file or the GraphicEQ text may have changed on the page this one opened.
    [self readState];
    [self.tableView reloadData];
    // A cancelled back swipe appears the page again without it ever disappearing, so the old timer goes first.
    [_ticker invalidate];
    _ticker = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_ticker invalidate];
    _ticker = nil;
}

- (void)readState {
    [_open removeAllObjects];
    [_errors removeAllObjects];
    for (SGDSPEffect *e in _effects) {
        if (!e.key || SGDSPSwitch(e.key)) [_open addObject:e.key ?: @""];
        if (e.key && SGDSPSwitch(e.key) && [reportingEffects() containsObject:e.key]) _errors[e.key] = SGDSPError(e.key);
    }
}

#pragma mark - rows

// Section 0 is the effects' switch, then a card per effect, then the reset.
- (SGDSPEffect *)effectIn:(NSInteger)section {
    return section >= 1 && section <= (NSInteger)_effects.count ? _effects[(NSUInteger)section - 1] : nil;
}

- (BOOL)isOpen:(SGDSPEffect *)e {
    return [_open containsObject:e.key ?: @""];
}

- (NSInteger)rowCountOf:(SGDSPEffect *)e {
    if (![self isOpen:e]) return 1;
    return 1 + (NSInteger)e.rows.count + (e.key && _errors[e.key] ? 1 : 0);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return (NSInteger)_effects.count + 2;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    SGDSPEffect *e = [self effectIn:section];
    return e ? [self rowCountOf:e] : 1;
}

// No views, but asked for all the same: without them the table keeps its own spacing, not the heights below.
- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return SGSectionGap;
}

- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (SGDSPRow *)rowAt:(NSIndexPath *)path {
    SGDSPEffect *e = [self effectIn:path.section];
    if (!e || path.row == 0 || path.row > (NSInteger)e.rows.count) return nil;
    return e.rows[(NSUInteger)path.row - 1];
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    // The heads, the values and the errors size themselves; a nil row would read as a slider.
    SGDSPRow *row = [self rowAt:path];
    if (!row) return UITableViewAutomaticDimension;
    if (row.kind == SGDSPRowSlider) return 74;
    if (row.kind == SGDSPRowCurve) return [SGDSPCurveView heightForKey:row.key];
    return UITableViewAutomaticDimension;
}

- (UISwitch *)switchOn:(BOOL)on action:(SEL)action tag:(NSInteger)tag {
    UISwitch *toggle = [UISwitch new];
    toggle.onTintColor = SGGreen();
    toggle.on = on;
    toggle.tag = tag;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return toggle;
}

- (void)fillHead:(UITableViewCell *)cell title:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol {
    SGFillCell(cell, title, subtitle, nil, nil);
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    content.image = SGTileImage(symbol);
    content.imageToTextPadding = 14;
    content.secondaryTextProperties.numberOfLines = 1;
    cell.contentConfiguration = content;
    cell.separatorInset = UIEdgeInsetsMake(0, 58, 0, 0);
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) {
        UITableViewCell *cell = SGDequeueCell(table, @"master");
        [self fillHead:cell title:@"Effects" subtitle:SGDSPStatus() symbol:@"waveform"];
        cell.accessoryView = [self switchOn:SGDSPSwitch(SGKeyDSP) action:@selector(masterToggled:) tag:0];
        return cell;
    }
    SGDSPEffect *e = [self effectIn:path.section];
    if (!e) {
        UITableViewCell *cell = SGDequeueCell(table, @"reset");
        SGFillCell(cell, @"Reset all effects", nil, SGRed(), @"arrow.counterclockwise");
        UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
        content.secondaryTextProperties.color = SGRed();
        cell.contentConfiguration = content;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.separatorInset = UIEdgeInsetsMake(0, 48, 0, 0);
        return cell;
    }
    if (path.row == 0) {
        UITableViewCell *cell = SGDequeueCell(table, @"effect");
        [self fillHead:cell title:e.title subtitle:e.subtitle symbol:e.symbol];
        if (e.key) cell.accessoryView = [self switchOn:SGDSPSwitch(e.key) action:@selector(effectToggled:) tag:path.section];
        return cell;
    }
    SGDSPRow *row = [self rowAt:path];
    if (!row) return [self errorCell:table text:_errors[e.key]];
    switch (row.kind) {
        case SGDSPRowSlider: {
            SGDSPSliderCell *cell = [table dequeueReusableCellWithIdentifier:@"slider"] ?: [[SGDSPSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"slider"];
            cell.backgroundColor = SGCardBackground();
            [cell showRow:row];
            return cell;
        }
        case SGDSPRowCurve: {
            SGDSPCurveCell *cell = [table dequeueReusableCellWithIdentifier:row.key];
            if (!cell) {
                cell = [[SGDSPCurveCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:row.key];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.curve = [[SGDSPCurveView alloc] initWithKey:row.key];
                [cell.contentView addSubview:cell.curve];
            }
            cell.backgroundColor = SGCardBackground();
            [cell.curve reload];
            return cell;
        }
        case SGDSPRowChoice: {
            NSInteger index = (NSInteger)lround(SGDSPNumber(row.key));
            NSString *name = index >= 0 && index < (NSInteger)row.names.count ? row.names[(NSUInteger)index] : row.names.firstObject;
            return [self valueCell:table title:row.title value:name];
        }
        case SGDSPRowPage:
            return [self valueCell:table title:row.title value:row.value()];
    }
    return SGDequeueCell(table, @"row");
}

// The value on the right beside the chevron where it fits next to the title, and under the title
// where it does not: the compressor's transforms are longer than a narrow phone has room for.
- (UITableViewCell *)valueCell:(UITableView *)table title:(NSString *)title value:(NSString *)value {
    UITableViewCell *cell = SGDequeueCell(table, @"value");
    CGFloat card = table.bounds.size.width - table.layoutMargins.left - table.layoutMargins.right;
    UIView *accessory = valueAndChevron(value);
    CGFloat titleWidth = ceil([title sizeWithAttributes:@{NSFontAttributeName: SGTitleFont()}].width);
    BOOL fits = 16 + titleWidth + 16 + accessory.bounds.size.width + 16 <= card;
    SGFillCell(cell, title, fits ? nil : value, nil, nil);
    cell.accessoryView = fits ? accessory : SGSymbolView(@"chevron.right", 13, UIImageSymbolWeightSemibold, 16);
    cell.accessibilityValue = value;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    return cell;
}

// Red, the way Settings' warning rows are: the effect's last change did not take, and why.
- (UITableViewCell *)errorCell:(UITableView *)table text:(NSString *)text {
    UITableViewCell *cell = SGDequeueCell(table, @"error");
    SGFillCell(cell, @"Not applied", text, SGRed(), @"exclamationmark.triangle.fill");
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    content.secondaryTextProperties.color = SGRed();
    cell.contentConfiguration = content;
    cell.separatorInset = UIEdgeInsetsMake(0, 48, 0, 0);
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == (NSInteger)_effects.count + 1) {
        [self confirmReset];
        return;
    }
    SGDSPRow *row = [self rowAt:path];
    if (!row) return;
    if (row.kind == SGDSPRowChoice) [self.navigationController pushViewController:[[SGDSPChoicePage alloc] initWithRow:row] animated:YES];
    else if (row.kind == SGDSPRowPage) [self.navigationController pushViewController:row.page() animated:YES];
}

- (BOOL)tableView:(UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == (NSInteger)_effects.count + 1) return YES;
    SGDSPRow *row = [self rowAt:path];
    return row && (row.kind == SGDSPRowChoice || row.kind == SGDSPRowPage);
}

#pragma mark - changes

- (void)masterToggled:(UISwitch *)toggle {
    SGDSPSetSwitch(SGKeyDSP, toggle.on);
    [self showStatus];
}

// The effect's rows come in under its switch, or go, rather than the page reloading around them; then the
// card is scrolled into view, as much of it as the screen holds.
- (void)effectToggled:(UISwitch *)toggle {
    NSInteger section = toggle.tag;
    SGDSPEffect *e = [self effectIn:section];
    if (!e.key) return;
    SGDSPSetSwitch(e.key, toggle.on);
    UITableView *table = self.tableView;
    NSInteger before = [self rowCountOf:e];
    [table performBatchUpdates:^{
        if (toggle.on) [self->_open addObject:e.key];
        else [self->_open removeObject:e.key];
        self->_errors[e.key] = toggle.on && [reportingEffects() containsObject:e.key] ? SGDSPError(e.key) : nil;
        NSInteger after = [self rowCountOf:e];
        NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
        for (NSInteger i = 1; i < MAX(before, after); i++) [paths addObject:[NSIndexPath indexPathForRow:i inSection:section]];
        if (after > before) [table insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
        else if (after < before) [table deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    } completion:^(BOOL finished) {
        if (!toggle.on) return;
        CGRect card = [table rectForSection:section];
        CGFloat room = table.bounds.size.height - table.adjustedContentInset.top - table.adjustedContentInset.bottom;
        card.size.height = MIN(card.size.height, room);
        [table scrollRectToVisible:card animated:YES];
    }];
}

// Once a second while the page shows: what the engine is doing, and whether an effect's change failed.
- (void)tick {
    [self showStatus];
    UITableView *table = self.tableView;
    [_effects enumerateObjectsUsingBlock:^(SGDSPEffect *e, NSUInteger i, BOOL *stop) {
        if (![reportingEffects() containsObject:e.key] || ![self isOpen:e]) return;
        NSString *shown = self->_errors[e.key], *now = SGDSPError(e.key);
        if (shown == now || [shown isEqualToString:now]) return;
        NSIndexPath *path = [NSIndexPath indexPathForRow:1 + (NSInteger)e.rows.count inSection:(NSInteger)i + 1];
        [table performBatchUpdates:^{
            self->_errors[e.key] = now;
            if (shown && now) [table reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationFade];
            else if (now) [table insertRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationFade];
            else [table deleteRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationFade];
        } completion:nil];
    }];
}

// Written into the cell rather than reloaded, so the switch beside it is never swapped under a finger.
- (void)showStatus {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    NSString *status = SGDSPStatus();
    if (!content || [content.secondaryText isEqualToString:status]) return;
    content.secondaryText = status;
    cell.contentConfiguration = content;
}

- (void)confirmReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset all effects?"
        message:@"Every effect goes off, and every value, curve and file choice back to its default. The Effects switch and your imported files stay."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGDSPResetAll();
        [self readState];
        [UIView transitionWithView:self.tableView duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            [self.tableView reloadData];
        } completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *SGDSPSettingsPage(void) {
    return [SGDSPPage new];
}
