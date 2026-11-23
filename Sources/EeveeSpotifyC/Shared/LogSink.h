// where a feature's debug log lines go: the block its install hands over (eevee's log), or NSLog until then.
// any thread but a render thread.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, EeveeLogFeature) {
    EeveeLogSpeedPitch,
    EeveeLogEqualizer,
};

void EeveeLogSinkSet(EeveeLogFeature feature, void (^sink)(NSString *message));
void EeveeLogSinkWrite(EeveeLogFeature feature, NSString *format, va_list arguments) NS_FORMAT_FUNCTION(2, 0);
