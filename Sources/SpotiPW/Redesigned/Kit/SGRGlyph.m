#import "Core/SGCore.h"
#import "SGRGlyph.h"
#import "SGRTokens.h"

static const CGFloat kMinTouch = 44, kPressAlpha = 0.5, kPressScale = 0.9, kDisabledAlpha = 0.35;

@implementation SGRGlyphView {
    NSString *_symbol;
}

- (instancetype)initWithSymbol:(NSString *)symbol pointSize:(CGFloat)size weight:(UIImageSymbolWeight)weight {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _symbol = [symbol copy];
    self.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    self.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    self.tintColor = SGRPrimary();
    self.contentMode = UIViewContentModeCenter;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = NO;
    self.accessibilityElementsHidden = YES;
    [self sizeToFit];
    return self;
}

- (NSString *)symbol {
    return _symbol;
}

- (void)setSymbol:(NSString *)symbol animated:(BOOL)animated {
    if (!symbol || [symbol isEqualToString:_symbol]) return;
    _symbol = [symbol copy];
    UIImage *image = [UIImage systemImageNamed:symbol];
    if (@available(iOS 17.0, *)) {
        if (animated && image && self.window && !SGRReduceMotion()) {
            // Twice UIKit's pace: a control's glyph answers a tap, and the default replace lingers.
            [self setSymbolImage:image withContentTransition:[NSSymbolReplaceContentTransition transition] options:[NSSymbolEffectOptions optionsWithSpeed:2]];
            return;
        }
    }
    self.image = image;
}

@end

@implementation SGRGlyphButton {
    SGRGlyphView *_glyph;
}

+ (instancetype)buttonWithSymbol:(NSString *)symbol pointSize:(CGFloat)size title:(NSString *)accessibilityTitle {
    SGRGlyphButton *button = [[self alloc] initWithFrame:CGRectMake(0, 0, kMinTouch, kMinTouch)];
    button->_glyph = [[SGRGlyphView alloc] initWithSymbol:symbol pointSize:size weight:UIImageSymbolWeightRegular];
    [button addSubview:button->_glyph];
    button.isAccessibilityElement = YES;
    button.accessibilityLabel = accessibilityTitle;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    button.showsLargeContentViewer = YES;
    button.largeContentTitle = accessibilityTitle;
    button.largeContentImage = button->_glyph.image;
    [button addInteraction:[UILargeContentViewerInteraction new]];
    // Touch up inside, not the primary action: UIKit sends the primary action from UIButton and the
    // controls built on it, never from a UIControl of one's own, so a handler registered for it is never
    // called and the button is dead to every tap (device, 2026-09-17, and the player harness).
    [button addTarget:button action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (SGRGlyphView *)glyph {
    return _glyph;
}

- (void)tapped {
    if (self.onTap) self.onTap();
}

// VoiceOver's double tap, which reaches a UIControl of one's own no other way.
- (BOOL)accessibilityActivate {
    if (!self.enabled) return NO;
    [self tapped];
    return YES;
}

- (CGSize)intrinsicContentSize {
    CGSize glyph = _glyph.intrinsicContentSize;
    return CGSizeMake(MAX(kMinTouch, glyph.width), MAX(kMinTouch, glyph.height));
}

- (CGSize)sizeThatFits:(CGSize)size {
    return self.intrinsicContentSize;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _glyph.bounds = (CGRect){CGPointZero, _glyph.intrinsicContentSize};
    _glyph.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}

// However small the frame it is given, a touch 44pt around its centre counts.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect bounds = self.bounds;
    CGFloat dx = MAX(0, (kMinTouch - bounds.size.width) / 2), dy = MAX(0, (kMinTouch - bounds.size.height) / 2);
    return CGRectContainsPoint(CGRectInset(bounds, -dx, -dy), point);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    SGRGlyphView *glyph = _glyph;
    SGRAnimate(SGRMotionPress, ^{
        glyph.alpha = highlighted ? kPressAlpha : 1;
        glyph.transform = highlighted ? CGAffineTransformMakeScale(kPressScale, kPressScale) : CGAffineTransformIdentity;
    }, nil);
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1 : kDisabledAlpha;
    self.accessibilityTraits = enabled ? UIAccessibilityTraitButton : UIAccessibilityTraitButton | UIAccessibilityTraitNotEnabled;
}

@end
