#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "SGDSPCurveView.h"
#import "AudioEffects.h"

enum { kPoints = 128 };                     // along the curve, log spaced from 20 Hz to 20 kHz
static const CGFloat kBarHeight = 36;       // the presets and Reset, over the plot
static const CGFloat kInset = 9;            // above the top line and under the bottom one, where a handle at the limit sits
static const CGFloat kLabelsHeight = 26;    // the bands' frequencies under the plot
static const CGFloat kSide = 16;            // the row's margins, the same as the text rows'
static const CGFloat kGutter = 22;          // the scale's numbers, right of the plot
static const CGFloat kGrab = 28;            // how far above or below a handle a finger still takes it
static const CGFloat kHandle = 11;          // a handle's diameter; the one being dragged grows

// "25", "630", "1.6k", "16k".
static NSString *bandName(double hz) {
    return hz < 1000 ? [NSString stringWithFormat:@"%g", hz] : [NSString stringWithFormat:@"%gk", hz / 1000];
}

static NSString *spokenBand(double hz) {
    return hz < 1000 ? [NSString stringWithFormat:@"%g hertz", hz] : [NSString stringWithFormat:@"%g kilohertz", hz / 1000];
}

// A real minus, and no sign on zero.
static NSString *signedNumber(double value, int decimals) {
    NSString *text = [NSString stringWithFormat:@"%.*f", decimals, fabs(value)];
    if (text.doubleValue == 0) return text;
    return [(value < 0 ? @"−" : @"+") stringByAppendingString:text];
}

@class SGDSPCurveView;

// A band as VoiceOver has it: adjustable, a step at a time, reading its gain out.
@interface SGDSPBandElement : UIAccessibilityElement
@property (nonatomic) NSInteger band;
@end

@interface SGDSPCurveView () <UIGestureRecognizerDelegate>
- (void)nudgeBand:(NSInteger)band by:(NSInteger)steps;
- (NSString *)spokenGainOf:(NSInteger)band;
@end

@implementation SGDSPBandElement

- (NSString *)accessibilityValue {
    return [(SGDSPCurveView *)self.accessibilityContainer spokenGainOf:self.band];
}

- (void)accessibilityIncrement {
    [(SGDSPCurveView *)self.accessibilityContainer nudgeBand:self.band by:1];
}

- (void)accessibilityDecrement {
    [(SGDSPCurveView *)self.accessibilityContainer nudgeBand:self.band by:-1];
}

@end

@implementation SGDSPCurveView {
    NSString *_key;
    BOOL _equalizer;
    const double *_bands;
    NSInteger _count;
    double _limit;       // the gains run from -_limit to _limit
    double _step;        // what a drag moves a gain by
    double _spokenStep;  // what VoiceOver's swipe does
    int _decimals;
    NSString *_unit;
    NSMutableArray<NSNumber *> *_gains;

    CALayer *_plot;      // the curve and its fill, cut off at the plot's edges
    CAShapeLayer *_grid, *_zero, *_fill, *_curve;
    NSMutableArray<CAShapeLayer *> *_handles;
    NSMutableArray<UILabel *> *_bandLabels;
    NSMutableArray<UILabel *> *_scale;
    UIButton *_presets, *_reset;
    UILabel *_name;      // the compander's, where the equalizer has its presets
    UILabel *_bubble;
    NSMutableArray<SGDSPBandElement *> *_elements;

    NSInteger _touched;   // the band under the finger that went down, -1 for none
    NSInteger _dragging;  // the band being dragged, -1 for none
    CGFloat _offset;      // from the finger to the handle's centre, kept through the drag
    UISelectionFeedbackGenerator *_detent;
}

+ (CGFloat)heightForKey:(NSString *)key {
    CGFloat plot = [key isEqualToString:SGKeyDSPCompanderGains] ? 112 : 144;
    return kBarHeight + kInset + plot + kInset + kLabelsHeight;
}

- (instancetype)initWithKey:(NSString *)key {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _key = key;
    _equalizer = ![key isEqualToString:SGKeyDSPCompanderGains];
    _bands = _equalizer ? SGDSPEqualizerFrequencies : SGDSPCompanderFrequencies;
    _count = _equalizer ? 15 : 7;
    _limit = _equalizer ? SGDSPEqualizerGainLimit : SGDSPCompanderGainLimit;
    _step = _equalizer ? 0.1 : 0.01;
    _spokenStep = _equalizer ? 0.5 : 0.1;
    _decimals = _equalizer ? 1 : 2;
    _unit = _equalizer ? @" dB" : @"";
    _touched = _dragging = -1;
    _detent = [UISelectionFeedbackGenerator new];

    _grid = [self lineLayer:[UIColor colorWithWhite:1 alpha:0.08]];
    _zero = [self lineLayer:[UIColor colorWithWhite:1 alpha:0.24]];
    _plot = [CALayer layer];
    _plot.mask = [CALayer layer];
    _plot.mask.backgroundColor = UIColor.blackColor.CGColor;
    [self.layer addSublayer:_plot];
    _fill = [CAShapeLayer layer];
    _curve = [CAShapeLayer layer];
    _curve.fillColor = nil;
    _curve.lineWidth = 2;
    _curve.lineJoin = kCALineJoinRound;
    _curve.lineCap = kCALineCapRound;
    [_plot addSublayer:_fill];
    [_plot addSublayer:_curve];

    _scale = [NSMutableArray array];
    for (NSNumber *value in @[@(_limit), @0, @(-_limit)]) {
        UILabel *label = [self smallLabel];
        label.text = signedNumber(value.doubleValue, value.doubleValue == 0 || _equalizer ? 0 : 1);
        label.textAlignment = NSTextAlignmentRight;
        [_scale addObject:label];
    }

    _handles = [NSMutableArray array];
    _bandLabels = [NSMutableArray array];
    _elements = [NSMutableArray array];
    for (NSInteger i = 0; i < _count; i++) {
        CAShapeLayer *handle = [CAShapeLayer layer];
        handle.bounds = CGRectMake(0, 0, kHandle, kHandle);
        handle.path = [UIBezierPath bezierPathWithOvalInRect:handle.bounds].CGPath;
        handle.fillColor = UIColor.whiteColor.CGColor;
        handle.shadowColor = UIColor.blackColor.CGColor;
        handle.shadowOpacity = 0.35;
        handle.shadowRadius = 2;
        handle.shadowOffset = CGSizeMake(0, 1);
        [self.layer addSublayer:handle];
        [_handles addObject:handle];

        UILabel *label = [self smallLabel];
        label.text = bandName(_bands[i]);
        label.textAlignment = NSTextAlignmentCenter;
        [_bandLabels addObject:label];

        SGDSPBandElement *element = [[SGDSPBandElement alloc] initWithAccessibilityContainer:self];
        element.band = i;
        element.accessibilityLabel = spokenBand(_bands[i]);
        element.accessibilityTraits = UIAccessibilityTraitAdjustable;
        element.accessibilityHint = @"Double tap and hold, then drag up or down, or swipe up or down to adjust.";
        [_elements addObject:element];
    }

    _bubble = [UILabel new];
    _bubble.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _bubble.textColor = UIColor.whiteColor;
    _bubble.textAlignment = NSTextAlignmentCenter;
    _bubble.backgroundColor = [UIColor colorWithWhite:0.32 alpha:1];
    _bubble.layer.cornerRadius = 7;
    _bubble.layer.cornerCurve = kCACornerCurveContinuous;
    _bubble.clipsToBounds = YES;
    _bubble.alpha = 0;
    _bubble.isAccessibilityElement = NO;
    [self addSubview:_bubble];

    _reset = [self barButton:@"Reset" color:SGGrey()];
    [_reset addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    _reset.accessibilityHint = _equalizer ? @"Every band back to zero." : @"Every point back to zero.";
    if (_equalizer) {
        _presets = [self barButton:@"Custom" color:UIColor.whiteColor];
        UIButtonConfiguration *config = _presets.configuration;
        config.image = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold]];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 5;
        _presets.configuration = config;
        _presets.showsMenuAsPrimaryAction = YES;
        _presets.accessibilityLabel = @"Preset";
    } else {
        _name = [UILabel new];
        _name.text = @"Amount";
        _name.textColor = UIColor.whiteColor;
        _name.accessibilityTraits = UIAccessibilityTraitHeader;
        [self addSubview:_name];
    }

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    pan.delegate = self;
    [self addGestureRecognizer:pan];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.delegate = self;
    [self addGestureRecognizer:doubleTap];

    [self reload];
    return self;
}

- (CAShapeLayer *)lineLayer:(UIColor *)color {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.strokeColor = color.CGColor;
    layer.fillColor = nil;
    layer.lineWidth = 1 / UIScreen.mainScreen.scale;
    [self.layer addSublayer:layer];
    return layer;
}

// Condensed, so fifteen of them fit under the bands of a 375pt phone with room between them.
- (UILabel *)smallLabel {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightMedium width:UIFontWidthCondensed];
    label.textColor = SGGrey();
    label.isAccessibilityElement = NO;
    [self addSubview:label];
    return label;
}

- (UIButton *)barButton:(NSString *)title color:(UIColor *)color {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    config.baseForegroundColor = color;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *styled = [attributes mutableCopy];
        styled[NSFontAttributeName] = SGTitleFont();
        return styled;
    };
    config.title = title;
    config.titleLineBreakMode = NSLineBreakByTruncatingTail;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self addSubview:button];
    return button;
}

#pragma mark - geometry

// Where the grid's top and bottom lines run: the limits.
- (CGRect)plotRect {
    CGSize size = self.bounds.size;
    CGFloat top = kBarHeight + kInset, bottom = size.height - kLabelsHeight - kInset;
    return CGRectMake(kSide, top, MAX(size.width - kSide - kGutter - kSide, 1), MAX(bottom - top, 1));
}

- (CGFloat)xFor:(double)hz {
    CGRect plot = [self plotRect];
    return CGRectGetMinX(plot) + log(hz / 20) / log(1000) * plot.size.width;
}

- (CGFloat)yFor:(double)value {
    CGRect plot = [self plotRect];
    return CGRectGetMidY(plot) - value / _limit * plot.size.height / 2;
}

- (double)valueFor:(CGFloat)y {
    CGRect plot = [self plotRect];
    double value = -(y - CGRectGetMidY(plot)) / (plot.size.height / 2) * _limit;
    value = round(value / _step) * _step;
    return MAX(-_limit, MIN(_limit, value));
}

// Half the distance between two bands, but never so thin that a finger misses.
- (CGFloat)reach {
    return MAX(([self xFor:_bands[1]] - [self xFor:_bands[0]]) / 2, 12);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect plot = [self plotRect];
    CGFloat width = self.bounds.size.width;

    [_reset sizeToFit];
    _reset.frame = CGRectMake(width - kSide - _reset.bounds.size.width, 0, _reset.bounds.size.width, kBarHeight);
    // Measured here: a button's configuration catches up with a new title only on its next pass, so
    // sizeToFit would still be fitting the old name.
    if (_presets) {
        NSString *title = _presets.configuration.title ?: @"";
        CGFloat needed = ceil([title sizeWithAttributes:@{NSFontAttributeName: SGTitleFont()}].width) + 5 + 12;
        _presets.frame = CGRectMake(kSide, 0, MIN(needed, width / 2), kBarHeight);
    }
    _name.font = SGTitleFont();
    _name.frame = CGRectMake(kSide, 0, width / 2, kBarHeight);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIBezierPath *grid = [UIBezierPath bezierPath];
    for (NSNumber *value in @[@(_limit), @(_limit / 2), @(-_limit / 2), @(-_limit)]) {
        CGFloat y = [self yFor:value.doubleValue];
        [grid moveToPoint:CGPointMake(CGRectGetMinX(plot), y)];
        [grid addLineToPoint:CGPointMake(CGRectGetMaxX(plot), y)];
    }
    _grid.path = grid.CGPath;
    UIBezierPath *zero = [UIBezierPath bezierPath];
    [zero moveToPoint:CGPointMake(CGRectGetMinX(plot), [self yFor:0])];
    [zero addLineToPoint:CGPointMake(CGRectGetMaxX(plot), [self yFor:0])];
    _zero.path = zero.CGPath;
    _plot.frame = self.bounds;
    _plot.mask.frame = CGRectInset(plot, 0, -kInset);
    [CATransaction commit];

    NSArray<NSNumber *> *levels = @[@(_limit), @0, @(-_limit)];
    [_scale enumerateObjectsUsingBlock:^(UILabel *label, NSUInteger i, BOOL *stop) {
        label.frame = CGRectMake(CGRectGetMaxX(plot), [self yFor:levels[i].doubleValue] - 6, kGutter, 12);
    }];
    CGFloat reach = [self reach];
    [_bandLabels enumerateObjectsUsingBlock:^(UILabel *label, NSUInteger i, BOOL *stop) {
        CGFloat x = [self xFor:self->_bands[i]];
        label.frame = CGRectMake(x - 16, CGRectGetMaxY(plot) + kInset + 5, 32, 12);
        self->_elements[i].accessibilityFrameInContainerSpace = CGRectMake(x - reach, CGRectGetMinY(plot) - kInset, reach * 2, plot.size.height + 2 * kInset);
    }];
    [self redrawAnimated:NO];
}

#pragma mark - drawing

- (void)reload {
    _gains = [SGDSPGains(_key) mutableCopy];
    [self redrawAnimated:NO];
    [self refreshBar];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self paint];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self paint];
}

// The accent colour is read each time the row shows, so a colour picked since shows here too.
- (void)paint {
    UIColor *accent = SGGreen();
    _curve.strokeColor = accent.CGColor;
    _fill.fillColor = [accent colorWithAlphaComponent:0.16].CGColor;
}

- (void)redrawAnimated:(BOOL)animated {
    if (CGRectIsEmpty(self.bounds)) return;
    double frequencies[kPoints], values[kPoints];
    if (_equalizer) SGDSPEqualizerResponse(_gains, kPoints, frequencies, values);
    else SGDSPCompanderResponse(_gains, kPoints, frequencies, values);

    // Past the plot's edges the mask cuts the curve off; points kept near them keep a runaway value
    // from stretching the path.
    CGRect plot = [self plotRect];
    CGFloat low = CGRectGetMinY(plot) - 40, high = CGRectGetMaxY(plot) + 40, zero = [self yFor:0];
    UIBezierPath *line = [UIBezierPath bezierPath], *area = [UIBezierPath bezierPath];
    for (NSInteger i = 0; i < kPoints; i++) {
        double hz = isfinite(frequencies[i]) && frequencies[i] > 0 ? frequencies[i] : 20 * pow(1000, (double)i / (kPoints - 1));
        double value = isfinite(values[i]) ? values[i] : 0;
        CGPoint point = CGPointMake([self xFor:hz], MAX(low, MIN(high, [self yFor:value])));
        if (i == 0) {
            [line moveToPoint:point];
            [area moveToPoint:CGPointMake(point.x, zero)];
        } else {
            [line addLineToPoint:point];
        }
        [area addLineToPoint:point];
        if (i == kPoints - 1) [area addLineToPoint:CGPointMake(point.x, zero)];
    }
    [area closePath];

    // A shape layer's path has no implicit animation, so the curve morphs by hand, from wherever it is
    // now; the handles are plain layers and slide on their own.
    CAMediaTimingFunction *easing = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (animated) {
        [self morph:_curve to:line timing:easing];
        [self morph:_fill to:area timing:easing];
    }
    [CATransaction begin];
    if (animated) {
        [CATransaction setAnimationDuration:0.35];
        [CATransaction setAnimationTimingFunction:easing];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _curve.path = line.CGPath;
    _fill.path = area.CGPath;
    [_handles enumerateObjectsUsingBlock:^(CAShapeLayer *handle, NSUInteger i, BOOL *stop) {
        handle.position = CGPointMake([self xFor:self->_bands[i]], [self yFor:self->_gains[i].doubleValue]);
    }];
    [CATransaction commit];
}

- (void)morph:(CAShapeLayer *)layer to:(UIBezierPath *)path timing:(CAMediaTimingFunction *)timing {
    CABasicAnimation *morph = [CABasicAnimation animationWithKeyPath:@"path"];
    morph.fromValue = (__bridge id)(((CAShapeLayer *)layer.presentationLayer).path ?: layer.path);
    morph.toValue = (__bridge id)path.CGPath;
    morph.duration = 0.35;
    morph.timingFunction = timing;
    [layer addAnimation:morph forKey:@"morph"];
}

// The presets' name and menu and whether there is anything to reset, once a change is done.
- (void)refreshBar {
    BOOL flat = YES;
    for (NSNumber *gain in _gains) flat &= gain.doubleValue == 0;
    _reset.enabled = !flat;
    if (!_presets) return;
    NSArray<NSString *> *names = SGDSPEqualizerPresetNames();
    NSInteger match = [self matchingPreset];
    UIButtonConfiguration *config = _presets.configuration;
    config.title = match >= 0 ? names[(NSUInteger)match] : @"Custom";
    _presets.configuration = config;
    _presets.accessibilityValue = config.title;
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    [names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        UIAction *action = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(UIAction *a) {
            [weakSelf setGains:SGDSPEqualizerPreset((NSInteger)i) animated:YES];
        }];
        action.state = (NSInteger)i == match ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }];
    _presets.menu = [UIMenu menuWithTitle:@"Presets" children:actions];
    [self setNeedsLayout];
}

// Stored to two decimals, so a preset matches to within that.
- (NSInteger)matchingPreset {
    NSArray<NSString *> *names = SGDSPEqualizerPresetNames();
    for (NSUInteger p = 0; p < names.count; p++) {
        NSArray<NSNumber *> *preset = SGDSPEqualizerPreset((NSInteger)p);
        BOOL same = preset.count == _gains.count;
        for (NSUInteger i = 0; same && i < preset.count; i++) same = fabs(preset[i].doubleValue - _gains[i].doubleValue) < 0.006;
        if (same) return (NSInteger)p;
    }
    return -1;
}

- (void)setGains:(NSArray<NSNumber *> *)gains animated:(BOOL)animated {
    if (gains.count != (NSUInteger)_count) return;
    _gains = [gains mutableCopy];
    SGDSPSetGains(_key, _gains);
    [self redrawAnimated:animated];
    [self refreshBar];
}

- (void)resetTapped {
    NSMutableArray<NSNumber *> *flat = [NSMutableArray array];
    for (NSInteger i = 0; i < _count; i++) [flat addObject:@0];
    [self setGains:flat animated:YES];
}

#pragma mark - dragging

- (NSString *)gainText:(double)gain {
    return [signedNumber(gain, _decimals) stringByAppendingString:_unit];
}

- (NSString *)spokenGainOf:(NSInteger)band {
    double gain = _gains[(NSUInteger)band].doubleValue;
    NSString *number = [NSString stringWithFormat:@"%.*f", _decimals, gain];
    return _equalizer ? [number stringByAppendingString:@" decibels"] : number;
}

// The band whose handle is under `point`: the nearest by frequency, if the finger is close enough to its
// handle. Anywhere else on the plot a drag scrolls the page instead.
- (NSInteger)bandAt:(CGPoint)point {
    NSInteger nearest = -1;
    CGFloat distance = CGFLOAT_MAX;
    for (NSInteger i = 0; i < _count; i++) {
        CGFloat dx = fabs(point.x - [self xFor:_bands[i]]);
        if (dx < distance) {
            distance = dx;
            nearest = i;
        }
    }
    if (nearest < 0 || distance > [self reach]) return -1;
    return fabs(point.y - [self yFor:_gains[(NSUInteger)nearest].doubleValue]) <= kGrab ? nearest : -1;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    _touched = [self bandAt:[touch locationInView:self]];
    return _touched >= 0;
}

- (void)setBand:(NSInteger)band to:(double)value {
    double old = _gains[(NSUInteger)band].doubleValue;
    if (value == old) return;
    // A tick as a band crosses zero, where it does nothing, and at either end.
    if ((old < 0) != (value < 0) || (old > 0) != (value > 0) || fabs(value) == _limit) [_detent selectionChanged];
    _gains[(NSUInteger)band] = @(value);
    SGDSPSetGains(_key, _gains);
    [self redrawAnimated:NO];
}

- (void)showBubbleFor:(NSInteger)band {
    _bubble.text = [self gainText:_gains[(NSUInteger)band].doubleValue];
    CGSize size = [_bubble sizeThatFits:CGSizeZero];
    size = CGSizeMake(ceil(size.width) + 14, 22);
    CGPoint handle = _handles[(NSUInteger)band].position;
    CGFloat x = MAX(4, MIN(self.bounds.size.width - size.width - 4, handle.x - size.width / 2));
    // Above the handle, where the finger dragging it is not; under it when the handle is at the top.
    CGFloat y = handle.y - 20 - size.height;
    if (y < 2) y = handle.y + 20;
    _bubble.frame = (CGRect){{x, y}, size};
}

- (void)highlight:(NSInteger)band on:(BOOL)on {
    CAShapeLayer *handle = _handles[(NSUInteger)band];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    handle.transform = on ? CATransform3DMakeScale(1.6, 1.6, 1) : CATransform3DIdentity;
    [CATransaction commit];
    _bandLabels[(NSUInteger)band].textColor = on ? UIColor.whiteColor : SGGrey();
    [UIView animateWithDuration:0.18 animations:^{ self->_bubble.alpha = on ? 1 : 0; }];
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    CGPoint point = [pan locationInView:self];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            if (_touched < 0) return;
            _dragging = _touched;
            _offset = _handles[(NSUInteger)_dragging].position.y - point.y;
            [_detent prepare];
            [self showBubbleFor:_dragging];
            [self highlight:_dragging on:YES];
            break;
        case UIGestureRecognizerStateChanged:
            if (_dragging < 0) return;
            [self setBand:_dragging to:[self valueFor:point.y + _offset]];
            [self showBubbleFor:_dragging];
            break;
        default:
            if (_dragging < 0) return;
            [self highlight:_dragging on:NO];
            _dragging = -1;
            [self refreshBar];
            break;
    }
}

- (void)doubleTapped:(UITapGestureRecognizer *)tap {
    NSInteger band = [self bandAt:[tap locationInView:self]];
    if (band < 0 || _gains[(NSUInteger)band].doubleValue == 0) return;
    _gains[(NSUInteger)band] = @0;
    [self setGains:_gains animated:YES];
}

- (void)nudgeBand:(NSInteger)band by:(NSInteger)steps {
    double value = _gains[(NSUInteger)band].doubleValue + steps * _spokenStep;
    value = MAX(-_limit, MIN(_limit, round(value / _step) * _step));
    [self setBand:band to:value];
    [self refreshBar];
}

#pragma mark - accessibility

- (BOOL)isAccessibilityElement {
    return NO;
}

- (NSArray *)accessibilityElements {
    NSMutableArray *elements = [NSMutableArray array];
    [elements addObject:_presets ?: _name];
    [elements addObject:_reset];
    [elements addObjectsFromArray:_elements];
    return elements;
}

@end
