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


// Local audio recorder
BOOL EeveeAudioRecorderStart(void);
void EeveeAudioRecorderStop(void);
BOOL EeveeAudioRecorderIsRecording(void);
NSString * _Nullable EeveeAudioRecorderCurrentPath(void);

NS_ASSUME_NONNULL_END

#import "EVRecorder.h"

#import "EVPlayback.h"
