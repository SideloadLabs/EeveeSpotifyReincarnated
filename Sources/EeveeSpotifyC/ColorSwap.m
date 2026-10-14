#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "Tweak.h"

// Spotify's base surface (#121212) and brand greens are each one token, so they're swapped where colors are born.
static BOOL sAmoled;
static BOOL sAccentOn;
static CGFloat sAccent[3];
static const uint32_t kGreens[] = {0x1ED760, 0x1DB954};
static atomic_long sGreyHits, sGreenHits, sInitHits;

static BOOL isBaseGrey(const CGFloat *c, size_t n) {
    if (n == 2) return c[0] > 0.01 && c[0] <= 0.10;
    if (n < 3) return NO;
    return c[0] > 0.01 && c[0] <= 0.10 && fabs(c[0] - c[1]) < 0.02 && fabs(c[1] - c[2]) < 0.02;
}

// The darker green variants keep their relation to the token as the same shade of the accent.
static BOOL swapGreen(CGFloat *r, CGFloat *g, CGFloat *b) {
    if (!sAccentOn) return NO;
    for (size_t i = 0; i < sizeof(kGreens) / sizeof(kGreens[0]); i++) {
        CGFloat gr = ((kGreens[i] >> 16) & 0xFF) / 255.0, gg = ((kGreens[i] >> 8) & 0xFF) / 255.0, gb = (kGreens[i] & 0xFF) / 255.0;
        if (fabs(*r - gr) > 0.01 || fabs(*g - gg) > 0.01 || fabs(*b - gb) > 0.01) continue;
        CGFloat factor = MAX(gr, MAX(gg, gb)) / (0xD7 / 255.0);
        *r = MIN(1, sAccent[0] * factor);
        *g = MIN(1, sAccent[1] * factor);
        *b = MIN(1, sAccent[2] * factor);
        return YES;
    }
    return NO;
}

// Layers get colors from background threads too, so only CoreGraphics here, no UIKit objects.
static CGColorRef copySwapped(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID()) return NULL;
    size_t n = CGColorGetNumberOfComponents(color);
    const CGFloat *c = CGColorGetComponents(color);
    if (sAmoled && isBaseGrey(c, n)) {
        atomic_fetch_add_explicit(&sGreyHits, 1, memory_order_relaxed);
        return CGColorCreateGenericGray(0, CGColorGetAlpha(color));
    }
    if (n != 4) return NULL;
    CGFloat r = c[0], g = c[1], b = c[2];
    if (!swapGreen(&r, &g, &b)) return NULL;
    atomic_fetch_add_explicit(&sGreenHits, 1, memory_order_relaxed);
    CGFloat out[] = {r, g, b, c[3]};
    return CGColorCreate(CGColorGetColorSpace(color), out);
}

static id swappedObject(id value) {
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CGColorGetTypeID()) return value;
    CGColorRef swapped = copySwapped((__bridge CGColorRef)value);
    return swapped ? (__bridge_transfer id)swapped : value;
}

#define SWIZZLE_CGCOLOR_SETTER(cls, sel) do { \
    Method m = class_getInstanceMethod(cls, sel); \
    if (!m) break; \
    void (*orig)(id, SEL, CGColorRef) = (void (*)(id, SEL, CGColorRef))method_getImplementation(m); \
    method_setImplementation(m, imp_implementationWithBlock(^(id self_, CGColorRef color) { \
        CGColorRef swapped = copySwapped(color); \
        orig(self_, sel, swapped ?: color); \
        if (swapped) CGColorRelease(swapped); \
    })); \
    count++; \
} while (0)
// Targeted image handling: 510x31 template tint and 510x1 strip recoloring.
static const CGFloat kTintW = 510, kTintH = 31;
static char sStripCacheKey, sStripProcessedKey;

static BOOL isTintTarget(UIImage *img) {
    return img && fabs(img.size.width - kTintW) < 1 &&
           fabs(img.size.height - kTintH) < 1;
}

static BOOL isStripTarget(UIImage *img) {
    return img && fabs(img.size.width - 510.0) < 0.1 &&
           fabs(img.size.height - 1.0) < 0.1;
}

static UIImage *SPTRecolor510x1Image(UIImage *image) {
    if (!image.CGImage || !isStripTarget(image))
        return nil;

    id cached = objc_getAssociatedObject(image, &sStripCacheKey);
    if (cached)
        return cached == NSNull.null ? nil : cached;

    CGImageRef source = image.CGImage;
    size_t w = CGImageGetWidth(source), h = CGImageGetHeight(source);
    if (!w || !h || w > 8192 || h > 64)
        return nil;

    size_t rowBytes = w * 4;
    uint8_t *pixels = calloc(h, rowBytes);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = pixels && cs
        ? CGBitmapContextCreate(pixels, w, h, 8, rowBytes, cs,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big)
        : NULL;

    if (!ctx) {
        if (cs) CGColorSpaceRelease(cs);
        free(pixels);
        return nil;
    }

    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), source);
    BOOL changed = NO;

    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            uint8_t *px = pixels + y * rowBytes + x * 4;
            CGFloat a = px[3] / 255.0;
            if (a <= 0) continue;

            CGFloat r = MIN(1.0, px[0] / (255.0 * a));
            CGFloat g = MIN(1.0, px[1] / (255.0 * a));
            CGFloat b = MIN(1.0, px[2] / (255.0 * a));
            CGFloat brightness = MAX(r, MAX(g, b));
            CGFloat position = (CGFloat)x / (CGFloat)w;

            if (!((position >= 0.82 && position < 0.91) ||
                  (g > r * 1.05 && g > b * 0.75 && g > 0.08)))
                continue;

            CGFloat factor = MIN(1.0, brightness / (215.0 / 255.0));
            px[0] = (uint8_t)lrint(MIN(1.0, sAccent[0] * factor) * a * 255.0);
            px[1] = (uint8_t)lrint(MIN(1.0, sAccent[1] * factor) * a * 255.0);
            px[2] = (uint8_t)lrint(MIN(1.0, sAccent[2] * factor) * a * 255.0);
            changed = YES;
        }
    }

    CGImageRef outCG = changed ? CGBitmapContextCreateImage(ctx) : NULL;
    UIImage *out = outCG
        ? [[UIImage imageWithCGImage:outCG scale:image.scale
                        orientation:image.imageOrientation]
            imageWithRenderingMode:image.renderingMode]
        : nil;

    if (out) {
        objc_setAssociatedObject(out, &sStripProcessedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGImageRelease(outCG);
    }

    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(pixels);

    objc_setAssociatedObject(image, &sStripCacheKey,
        out ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

static UIImage *SPTProcess510x1Image(UIImage *image) {
    if (!image || objc_getAssociatedObject(image, &sStripProcessedKey))
        return image;
    if (!isStripTarget(image))
        return image;
    return SPTRecolor510x1Image(image) ?: image;
}

static UIImage *SPTProcessImage(UIImage *image) {
    return isTintTarget(image)
        ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
        : SPTProcess510x1Image(image);
}

int EeveeInstallColorSwaps(BOOL amoled, NSInteger accentRGB) {
    static dispatch_once_t once;
    __block int count = 0;
    dispatch_once(&once, ^{
        sAmoled = amoled;
        sAccentOn = accentRGB >= 0 && accentRGB <= 0xFFFFFF;
        sAccent[0] = ((accentRGB >> 16) & 0xFF) / 255.0;
        sAccent[1] = ((accentRGB >> 8) & 0xFF) / 255.0;
        sAccent[2] = (accentRGB & 0xFF) / 255.0;
        if (!sAmoled && !sAccentOn) return;

        SWIZZLE_CGCOLOR_SETTER(CALayer.class, @selector(setBackgroundColor:));

        Method colors = class_getInstanceMethod(CAGradientLayer.class, @selector(setColors:));
        if (colors) {
            void (*orig)(id, SEL, NSArray *) = (void (*)(id, SEL, NSArray *))method_getImplementation(colors);
            method_setImplementation(colors, imp_implementationWithBlock(^(id self_, NSArray *values) {
                NSMutableArray *mapped = nil;
                for (NSUInteger i = 0; i < values.count; i++) {
                    id swapped = swappedObject(values[i]);
                    if (swapped == values[i]) continue;
                    if (!mapped) mapped = [values mutableCopy];
                    mapped[i] = swapped;
                }
                orig(self_, @selector(setColors:), mapped ?: values);
            }));
            count++;
        }

        if (!sAccentOn) return;
        SWIZZLE_CGCOLOR_SETTER(CAShapeLayer.class, @selector(setFillColor:));
        SWIZZLE_CGCOLOR_SETTER(CAShapeLayer.class, @selector(setStrokeColor:));

        Method init = class_getInstanceMethod(UIColor.class, @selector(initWithRed:green:blue:alpha:));
        if (init) {
            UIColor *(*orig)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat) = (void *)method_getImplementation(init);
            method_setImplementation(init, imp_implementationWithBlock(^UIColor *(id self_, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
                if (swapGreen(&r, &g, &b)) atomic_fetch_add_explicit(&sInitHits, 1, memory_order_relaxed);
                return orig(self_, @selector(initWithRed:green:blue:alpha:), r, g, b, a);
            }));
            count++;
        }
        Method make = class_getClassMethod(UIColor.class, @selector(colorWithRed:green:blue:alpha:));
        if (make) {
            UIColor *(*orig)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat) = (void *)method_getImplementation(make);
            method_setImplementation(make, imp_implementationWithBlock(^UIColor *(id self_, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
                if (swapGreen(&r, &g, &b)) atomic_fetch_add_explicit(&sInitHits, 1, memory_order_relaxed);
                return orig(self_, @selector(colorWithRed:green:blue:alpha:), r, g, b, a);
            }));
            count++;
        }
        Method values = class_getInstanceMethod(CAKeyframeAnimation.class, @selector(setValues:));
        if (values) {
            void (*orig)(id, SEL, NSArray *) = (void (*)(id, SEL, NSArray *))method_getImplementation(values);
            method_setImplementation(values, imp_implementationWithBlock(^(id self_, NSArray *list) {
                NSMutableArray *mapped = nil;
                for (NSUInteger i = 0; i < list.count; i++) {
                    id swapped = swappedObject(list[i]);
                    if (swapped == list[i]) continue;
                    if (!mapped) mapped = [list mutableCopy];
                    mapped[i] = swapped;
                }
                orig(self_, @selector(setValues:), mapped ?: list);
            }));
            count++;
        }
        for (NSString *name in @[@"setFromValue:", @"setToValue:"]) {
            SEL sel = NSSelectorFromString(name);
            Method m = class_getInstanceMethod(CABasicAnimation.class, sel);
            if (!m) continue;
            void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^(id self_, id value) {
                orig(self_, sel, swappedObject(value));
            }));
            count++;
        }
	

        Method setImg = class_getInstanceMethod(UIImageView.class, @selector(setImage:));
        if (setImg) {
            void (*orig)(id, SEL, UIImage *) =
                (void *)method_getImplementation(setImg);
            method_setImplementation(setImg, imp_implementationWithBlock(
                ^(UIImageView *view, UIImage *img) {
                    BOOL tint = isTintTarget(img);
                    orig(view, @selector(setImage:), SPTProcessImage(img));
                    if (tint)
                        view.tintColor = [UIColor colorWithRed:sAccent[0]
                            green:sAccent[1] blue:sAccent[2] alpha:1];
                }));
            count++;
        }

        Method initImg = class_getInstanceMethod(UIImageView.class,
                                                  @selector(initWithImage:));
        if (initImg) {
            id (*orig)(id, SEL, UIImage *) =
                (void *)method_getImplementation(initImg);
            method_setImplementation(initImg, imp_implementationWithBlock(
                ^id(UIImageView *view, UIImage *img) {
                    BOOL tint = isTintTarget(img);
                    UIImageView *result = orig(view, @selector(initWithImage:),
                                                SPTProcessImage(img));
                    if (tint)
                        result.tintColor = [UIColor colorWithRed:sAccent[0]
                            green:sAccent[1] blue:sAccent[2] alpha:1];
                    return result;
                }));
            count++;
        }

        Method buttonImg = class_getInstanceMethod(UIButton.class,
                                                    @selector(setImage:forState:));
        if (buttonImg) {
            void (*orig)(id, SEL, UIImage *, UIControlState) =
                (void *)method_getImplementation(buttonImg);
            method_setImplementation(buttonImg, imp_implementationWithBlock(
                ^(UIButton *button, UIImage *img, UIControlState state) {
                    orig(button, @selector(setImage:forState:),
                         SPTProcess510x1Image(img), state);
                }));
            count++;
        }

        // Add a UISwitch-specific override; do not replace UIView's inherited method.
        SEL moveSel = @selector(didMoveToWindow);
        Method moveMethod = class_getInstanceMethod(UISwitch.class, moveSel);
        if (moveMethod) {
            void (*orig)(id, SEL) =
                (void *)method_getImplementation(moveMethod);
            IMP replacement = imp_implementationWithBlock(^(UISwitch *sw) {
                orig(sw, moveSel);
                if (sw.window)
                    sw.onTintColor = [UIColor colorWithRed:sAccent[0]
                        green:sAccent[1] blue:sAccent[2] alpha:1];
            });
            if (class_addMethod(UISwitch.class, moveSel, replacement,
                                method_getTypeEncoding(moveMethod)))
                count++;
        }
    });
    return count;
}

void EeveeColorSwapStats(long *grey, long *green, long *uiColor) {
    *grey = atomic_load_explicit(&sGreyHits, memory_order_relaxed);
    *green = atomic_load_explicit(&sGreenHits, memory_order_relaxed);
    *uiColor = atomic_load_explicit(&sInitHits, memory_order_relaxed);
}
