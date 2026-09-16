#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);

#pragma mark - Liquid Glass

/// A UIGlassEffect when the running OS has one, otherwise a dark chrome
/// UIBlurEffect. Built here rather than in Swift because UIGlassEffect's
/// only initialiser is +effectWithStyle:, which does not exist in any SDK
/// EeveeSpotify builds against — it has to be reached by name at runtime.
/// A bare -init leaves the material unresolved and the pane comes out as a
/// flat blur, so the style argument is not optional.
UIVisualEffect *EeveeGlassMakeEffect(void);

/// YES when the running OS actually has UIGlassEffect (iOS 26+).
BOOL EeveeGlassIsAvailable(void);

/// Shapes a glass pane. On iOS 26 this goes through -setCornerConfiguration:,
/// which lets the material's edge lensing render *outside* the pane's own
/// bounds the way system glass does; clipsToBounds is left off for that
/// reason. Older systems fall back to a clipped continuous-curve
/// layer.cornerRadius, which loses the lensing overhang but keeps the shape.
/// Pass capsule=YES for fully round ends; radius is ignored then.
void EeveeGlassApplyShape(UIView *pane, CGFloat radius, BOOL capsule);
NSString *EeveeJBRootPath(NSString *path);

NS_ASSUME_NONNULL_END
