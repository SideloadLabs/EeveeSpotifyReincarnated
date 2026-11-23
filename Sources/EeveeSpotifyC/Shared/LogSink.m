#import "LogSink.h"
#import <os/lock.h>

enum { kFeatures = EeveeLogEqualizer + 1 };

static NSString *const kPrefixes[kFeatures] = {@"[EeveeSpotify][SpeedPitch]", @"[EeveeSpotify][Equalizer]"};
static void (^sg_sinks[kFeatures])(NSString *);
static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;

void EeveeLogSinkSet(EeveeLogFeature feature, void (^sink)(NSString *message)) {
    if (feature < 0 || feature >= kFeatures) return;
    void (^copied)(NSString *) = [sink copy];
    os_unfair_lock_lock(&sg_lock);
    sg_sinks[feature] = copied;
    os_unfair_lock_unlock(&sg_lock);
}

void EeveeLogSinkWrite(EeveeLogFeature feature, NSString *format, va_list arguments) {
    if (feature < 0 || feature >= kFeatures) return;
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    os_unfair_lock_lock(&sg_lock);
    void (^sink)(NSString *) = sg_sinks[feature];
    os_unfair_lock_unlock(&sg_lock);
    if (sink) sink(message);
    else NSLog(@"%@ %@", kPrefixes[feature], message);
}
