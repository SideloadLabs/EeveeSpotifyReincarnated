#import "SGGlowSwitch.h"

static const CGFloat kWidth = 56, kHeight = 32, kKnobInset = 3, kKnobStretch = 5;
static const CGFloat kRimWidth = 2, kGlowWidth = 5, kGlowRadius = 6, kGlowBleed = 14;
static const CFTimeInterval kTurn = 4;   // seconds for the rainbow to go round once
static NSString *const kTurnKey = @"turn";

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
@end

// Around the capsule the way a conic gradient runs, starting and ending on the same pink so the turn
// has no seam.
static NSArray *rainbow(void) {
    static NSArray *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (NSNumber *rgb in @[@0xFF375F, @0xFF9F0A, @0xFFD60A, @0x30D158, @0x64D2FF, @0x0A84FF, @0xBF5AF2, @0xFF375F]) {
            uint32_t v = rgb.unsignedIntValue;
            [list addObject:(id)[UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1].CGColor];
        }
        colors = list;
    });
    return colors;
}

static CAGradientLayer *newRainbow(void) {
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.type = kCAGradientLayerConic;
    gradient.colors = rainbow();
    gradient.startPoint = CGPointMake(0.5, 0.5);
    gradient.endPoint = CGPointMake(0.5, 0);
    return gradient;
}

static CAShapeLayer *newStroke(CGFloat width) {
    CAShapeLayer *stroke = [CAShapeLayer layer];
    stroke.fillColor = UIColor.clearColor.CGColor;
    stroke.strokeColor = UIColor.blackColor.CGColor;
    stroke.lineWidth = width;
    return stroke;
}

@implementation SGGlowSwitch {
    CAShapeLayer *_track;
    CALayer *_rim, *_glow, *_glowShape, *_wash;
    CAShapeLayer *_rimMask, *_glowMask, *_washMask;
    CAGradientLayer *_rimColors, *_glowColors, *_washColors;
    UIView *_knob;
    UIImpactFeedbackGenerator *_haptic;
    BOOL _pressed;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:CGRectMake(frame.origin.x, frame.origin.y, kWidth, kHeight)])) return nil;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    if (@available(iOS 17.0, *)) self.accessibilityTraits = UIAccessibilityTraitToggleButton;

    _track = [CAShapeLayer layer];
    _track.lineWidth = 1;
    [self.layer addSublayer:_track];

    // The rainbow washed faintly over the inside of the track.
    _wash = [CALayer layer];
    _washMask = [CAShapeLayer layer];
    _wash.mask = _washMask;
    _washColors = newRainbow();
    [_wash addSublayer:_washColors];
    [self.layer addSublayer:_wash];

    // The glow: the rainbow cut to a wide stroke, blurred as a whole, in a layer larger than the switch
    // so the blur has room to spread.
    _glow = [CALayer layer];
    _glowShape = [CALayer layer];
    _glowMask = newStroke(kGlowWidth);
    _glowShape.mask = _glowMask;
    _glowColors = newRainbow();
    [_glowShape addSublayer:_glowColors];
    [_glow addSublayer:_glowShape];
    CAFilter *blur = [NSClassFromString(@"CAFilter") respondsToSelector:@selector(filterWithType:)] ? [NSClassFromString(@"CAFilter") filterWithType:@"gaussianBlur"] : nil;
    if (blur) {
        [blur setValue:@(kGlowRadius) forKey:@"inputRadius"];
        _glow.filters = @[blur];
    }
    [self.layer addSublayer:_glow];

    _rim = [CALayer layer];
    _rimMask = newStroke(kRimWidth);
    _rim.mask = _rimMask;
    _rimColors = newRainbow();
    [_rim addSublayer:_rimColors];
    [self.layer addSublayer:_rim];

    _knob = [UIView new];
    _knob.userInteractionEnabled = NO;
    _knob.backgroundColor = UIColor.whiteColor;
    _knob.layer.shadowColor = UIColor.blackColor.CGColor;
    _knob.layer.shadowOpacity = 0.3;
    _knob.layer.shadowRadius = 3;
    _knob.layer.shadowOffset = CGSizeMake(0, 1);
    [self addSubview:_knob];

    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [self paint];
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kWidth, kHeight);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(kWidth, kHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, kRimWidth / 2, kRimWidth / 2) cornerRadius:bounds.size.height / 2];
    // A square the capsule's diagonal across, so the colours cover the rim at every angle of the turn.
    CGFloat side = ceil(hypot(bounds.size.width, bounds.size.height)) + 2;
    CGRect square = CGRectMake(CGRectGetMidX(bounds) - side / 2, CGRectGetMidY(bounds) - side / 2, side, side);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.frame = bounds;
    _track.path = capsule.CGPath;
    _rim.frame = bounds;
    _rimMask.frame = bounds;
    _rimMask.path = capsule.CGPath;
    _rimColors.frame = square;
    _wash.frame = bounds;
    _washMask.frame = bounds;
    _washMask.path = capsule.CGPath;
    _washColors.frame = square;

    _glow.frame = CGRectInset(bounds, -kGlowBleed, -kGlowBleed);
    _glowShape.frame = _glow.bounds;
    _glowMask.frame = _glow.bounds;
    UIBezierPath *glowPath = [capsule copy];
    [glowPath applyTransform:CGAffineTransformMakeTranslation(kGlowBleed, kGlowBleed)];
    _glowMask.path = glowPath.CGPath;
    _glowColors.frame = CGRectOffset(square, kGlowBleed, kGlowBleed);
    [CATransaction commit];

    [self placeKnob];
}

- (void)placeKnob {
    CGFloat side = self.bounds.size.height - kKnobInset * 2;
    CGFloat width = side + (_pressed ? kKnobStretch : 0);
    CGFloat x = self.on ? self.bounds.size.width - kKnobInset - width : kKnobInset;
    _knob.frame = CGRectMake(x, kKnobInset, width, side);
    _knob.layer.cornerRadius = side / 2;
}

// Colours for the state. Off is meant to tempt: the rainbow already circles the rim, softer, with a
// fainter glow. On it comes in full, glow and all.
- (void)paint {
    BOOL on = self.on;
    BOOL glow = !UIAccessibilityIsReduceTransparencyEnabled();
    _track.fillColor = [UIColor colorWithWhite:on ? 0.08 : 0.12 alpha:1].CGColor;
    _track.strokeColor = UIColor.clearColor.CGColor;
    _wash.opacity = on ? 0.3 : 0.16;
    _rim.opacity = on ? 1 : 0.6;
    _glow.opacity = glow ? (on ? 0.9 : 0.45) : 0;
    _knob.alpha = self.enabled ? 1 : 0.5;
    self.alpha = self.enabled ? 1 : 0.4;
    self.accessibilityValue = on ? @"On" : @"Off";
    [self updateMotion];
}

- (void)updateMotion {
    BOOL moving = self.window && !UIAccessibilityIsReduceMotionEnabled();
    for (CAGradientLayer *colors in @[_rimColors, _glowColors, _washColors]) {
        if (!moving) {
            [colors removeAnimationForKey:kTurnKey];
            continue;
        }
        if ([colors animationForKey:kTurnKey]) continue;
        CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        turn.fromValue = @0;
        turn.toValue = @(M_PI * 2);
        turn.duration = kTurn;
        turn.repeatCount = HUGE_VALF;
        turn.removedOnCompletion = NO;
        [colors addAnimation:turn forKey:kTurnKey];
    }
}

// The app going to the background drops layer animations; they start again on the way back.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    if (self.window) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMotion) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self updateMotion];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setOn:(BOOL)on {
    [self setOn:on animated:NO];
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    if (!animated || UIAccessibilityIsReduceMotionEnabled()) {
        [CATransaction begin];
        [CATransaction setDisableActions:!animated];
        [self paint];
        [CATransaction commit];
        [self placeKnob];
        return;
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.3];
    [self paint];
    [CATransaction commit];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        [self placeKnob];
    } completion:nil];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self paint];
}

- (void)setPressed:(BOOL)pressed {
    if (pressed == _pressed) return;
    _pressed = pressed;
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut animations:^{
        [self placeKnob];
    } completion:nil];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [_haptic prepare];
    [self setPressed:YES];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self setPressed:NO];
    if (touch && CGRectContainsPoint(CGRectInset(self.bounds, -16, -16), [touch locationInView:self])) [self flip];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [self setPressed:NO];
}

- (BOOL)accessibilityActivate {
    [self flip];
    return YES;
}

- (void)flip {
    [self setOn:!self.on animated:YES];
    [_haptic impactOccurred];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

@end
