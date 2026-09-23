#import "SGViewTree.h"

void SGForEachView(UIView *view, void (^fn)(UIView *)) {
    fn(view);
    for (UIView *sub in view.subviews) SGForEachView(sub, fn);
}

CGRect SGFrameIn(UIView *view, UIView *target) {
    return [view.superview convertRect:view.frame toView:target];
}

BOOL SGIsInside(UIView *view, UIView *root) {
    if (!root) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UIVisualEffectView.class]) return NO;
        if (v == root) return YES;
    }
    return NO;
}

UIStackView *SGRowIn(UIView *host) {
    __block UIStackView *row = nil;
    SGForEachView(host, ^(UIView *v) {
        if (!row && [v isKindOfClass:UIStackView.class] && v.bounds.size.width > 200 && ((UIStackView *)v).arrangedSubviews.count >= 2) row = (UIStackView *)v;
    });
    return row;
}

BOOL SGHasClass(UIView *root, NSString *marker) {
    __block BOOL found = NO;
    SGForEachView(root, ^(UIView *v) {
        if (!found && [NSStringFromClass(v.class) containsString:marker]) found = YES;
    });
    return found;
}

BOOL SGKeepsColor(UIView *view) {
    return [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] || view.bounds.size.height <= 4;
}

void SGStripBackgrounds(UIView *view) {
    if ([view isKindOfClass:UIVisualEffectView.class]) return;
    // The karaoke views paint nothing to strip and hold a label for every word in sight.
    if ([NSStringFromClass(view.class) hasPrefix:@"SGRKaraoke"]) return;
    if (!SGKeepsColor(view)) view.layer.backgroundColor = NULL;
    if ([view.layer isKindOfClass:CAGradientLayer.class] || [NSStringFromClass(view.class) containsString:@"GradientView"]) view.hidden = YES;
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:CAGradientLayer.class]) layer.hidden = YES;
    }
    for (UIView *sub in view.subviews) SGStripBackgrounds(sub);
}

BOOL SGIsVisibleColor(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.05) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    CGFloat brightest = 0;
    for (size_t i = 0; i + 1 < n; i++) brightest = MAX(brightest, c[i]);
    return brightest > 0.08;
}

BOOL SGIsLightColor(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.5) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    for (size_t i = 0; i + 1 < n; i++) if (c[i] < 0.85) return NO;
    return YES;
}

// Lighter greys (#1F1F1F placeholders, #292929 cards) and translucent paint stay.
BOOL SGIsBaseSurface(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID() || CGColorGetAlpha(color) < 0.95) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n == 2) return c[0] <= 0.10;
    if (n < 3) return NO;
    return c[0] <= 0.10 && fabs(c[0] - c[1]) < 0.02 && fabs(c[1] - c[2]) < 0.02;
}

BOOL SGLooksLikeCard(UIView *view, CGColorRef color) {
    CGSize size = view.bounds.size;
    return size.height >= 40 && size.height <= 140 && size.width >= 200 && SGIsVisibleColor(color);
}
