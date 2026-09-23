// Glass panes: one UIVisualEffectView per host, kept behind the host's own content.
#import <UIKit/UIKit.h>

// UIGlassEffect made the only way that resolves its material, or a dark chrome blur before iOS 26.
UIVisualEffect *SGGlassEffect(void);
UIVisualEffectView *SGGlassFor(UIView *host, const void *key);
// Several panes on one host, addressed by index; panes past `count` are hidden by SGHideGlassFrom.
UIVisualEffectView *SGGlassAt(UIView *host, NSUInteger index);
void SGHideGlassFrom(UIView *host, NSUInteger count);
// Glass takes its shape from cornerConfiguration on iOS 26; layer.cornerRadius is the fallback.
void SGShapeGlass(UIView *glass, CGFloat radius, BOOL capsule);

// The areas each look keeps transparent are its own: Native/Appearance/Repaint.h and
// Redesigned/Kit/SGRRepaint.h.
