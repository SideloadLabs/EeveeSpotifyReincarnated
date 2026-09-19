#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "Tweak.h"

#if THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <libroot.h>
#endif

NSString *EeveeJBRootPath(NSString *path) {
#if THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return JBROOT_PATH_NSSTRING(path);
#endif
}

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) {
    if (!target || !selector) return;
    typedef id (*SeekFn)(id, SEL, double);
    SeekFn fn = (SeekFn)objc_msgSend;
    (void)fn(target, selector, argument);
}

#pragma mark - Liquid Glass

// iOS 26 API that no SDK EeveeSpotify builds against declares. Declared here
// only so the calls below type-check; every use is guarded by a respondsTo
// check first, so nothing here is sent on an older system.
@interface UIView (EeveeGlassPrivate)
- (void)setCornerConfiguration:(id)configuration;
@end

BOOL EeveeGlassIsAvailable(void) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    return glass && [glass respondsToSelector:@selector(effectWithStyle:)];
}

UIVisualEffect *EeveeGlassMakeEffect(void) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    if ([glass respondsToSelector:@selector(effectWithStyle:)]) {
        // Style 0 is the regular (non-clear) material. Spotify's own
        // Reprise chrome builds its glass the same way.
        typedef id (*EffectFn)(id, SEL, NSInteger);
        EffectFn fn = (EffectFn)objc_msgSend;
        id effect = fn(glass, @selector(effectWithStyle:), 0);
        if (effect && [effect isKindOfClass:UIVisualEffect.class]) {
            return effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
void EeveeGlassApplyShape(UIView *pane, CGFloat radius, BOOL capsule) {
    if (!pane) return;

    Class config = NSClassFromString(@"UICornerConfiguration");
    Class cornerRadius = NSClassFromString(@"UICornerRadius");
    id shape = nil;

    if (config && [pane respondsToSelector:@selector(setCornerConfiguration:)]) {
        if (capsule && [config respondsToSelector:@selector(capsuleConfiguration)]) {
            shape = [(id)config performSelector:@selector(capsuleConfiguration)];
        } else if ([config respondsToSelector:@selector(configurationWithUniformRadius:)] &&
                   [cornerRadius respondsToSelector:@selector(fixedRadius:)]) {
            // +fixedRadius: takes a CGFloat, so it cannot go through
            // performSelector: — CGFloat is not an object and would be
            // read as a pointer.
            typedef id (*RadiusFn)(id, SEL, CGFloat);
            RadiusFn makeRadius = (RadiusFn)objc_msgSend;
            id value = makeRadius(cornerRadius, @selector(fixedRadius:), radius);
            if (value) shape = [(id)config performSelector:@selector(configurationWithUniformRadius:) withObject:value];
        }
    }

    if (shape) {
        [pane setCornerConfiguration:shape];
        pane.clipsToBounds = NO;
    } else {
        pane.layer.cornerRadius = capsule ? pane.bounds.size.height / 2 : radius;
        pane.layer.cornerCurve = kCACornerCurveContinuous;
        pane.clipsToBounds = YES;
    }
}
#pragma clang diagnostic pop

static void writeDebugLog(NSString *message) {
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void init() {
    @try {
        NSLog(@"[EeveeSpotify] Initializing tweak...");

        // Initialize Orion - do not remove this line.
        orion_init();

        NSLog(@"[EeveeSpotify] Tweak initialized successfully");
        // Custom initialization code goes here.
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        NSLog(@"[EeveeSpotify] %@", errorMsg);
        writeDebugLog(errorMsg);
    }
}
