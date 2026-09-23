#import "SGBackdrop.h"

// Small enough that no shape of the cover survives the scaling back up, large enough to keep the
// colours where they were in it.
static const CGFloat kCoverSample = 48;

@interface SGScrimView : UIView
@end

@implementation SGScrimView
+ (Class)layerClass {
    return CAGradientLayer.class;
}
@end

UIImage *SGBackdropSample(UIImage *cover) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    CGRect square = CGRectMake(0, 0, kCoverSample, kCoverSample);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:square.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [cover drawInRect:square];
    }];
}

UIView *SGBackdropMake(CGRect frame, CGFloat bottomAlpha) {
    UIViewAutoresizing fill = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIView *backdrop = [[UIView alloc] initWithFrame:frame];
    backdrop.userInteractionEnabled = NO;
    backdrop.clipsToBounds = YES;
    backdrop.autoresizingMask = fill;

    UIImageView *cover = [[UIImageView alloc] initWithFrame:backdrop.bounds];
    cover.contentMode = UIViewContentModeScaleAspectFill;
    cover.autoresizingMask = fill;
    [backdrop addSubview:cover];

    // The scaled up cover comes back with the seams of its 48 pixels in it; the blur takes those out.
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.frame = backdrop.bounds;
    blur.autoresizingMask = fill;
    [backdrop addSubview:blur];

    SGScrimView *scrim = [[SGScrimView alloc] initWithFrame:backdrop.bounds];
    scrim.autoresizingMask = fill;
    CAGradientLayer *fade = (CAGradientLayer *)scrim.layer;
    fade.colors = @[
        (id)[UIColor colorWithWhite:0 alpha:0.40].CGColor,
        (id)[UIColor colorWithWhite:0 alpha:0.60].CGColor,
        (id)[UIColor colorWithWhite:0 alpha:bottomAlpha].CGColor,
    ];
    fade.locations = @[@0, @0.5, @1];
    [backdrop addSubview:scrim];
    return backdrop;
}

UIImageView *SGBackdropImageView(UIView *backdrop) {
    return (UIImageView *)backdrop.subviews.firstObject;
}
