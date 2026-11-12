#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);
NSString *EeveeJBRootPath(NSString *path);
BOOL EeveeSetMainInfoValue(NSString *key, id value);
UIImage *_Nullable EeveeRenderTemplate(UIView *view);
UIImage *_Nullable EeveeEncoreIconImage(UIView *iconView, BOOL active);
BOOL EeveeFireTap(UIView *root);
int EeveeInstallColorSwaps(BOOL amoled, NSInteger accentRGB);
void EeveeColorSwapStats(long *grey, long *green, long *uiColor);
BOOL EeveePinSetter(id object, SEL setter, id value);
BOOL EeveeInterceptBackground(UIView *view, void (^sink)(UIColor *color));

// Artist-page download button of the Pixie companion. They resolve its exported functions at
// runtime and do nothing when the companion is not loaded.
void EeveePixieUpdateArtistDownloads(UIView *header, UIButton *_Nullable externalButton);
NSString *_Nullable EeveePixieArtistURIForHeader(UIView *header);
void EeveePixieInstallArtistFollow(void);
NSInteger EeveePixieArtistFollowing(UIView *header, void (^changed)(void));

NS_ASSUME_NONNULL_END
