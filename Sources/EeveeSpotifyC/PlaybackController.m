// PlaybackController.m - drives SPTNowPlayingPlaybackControllerImplementation directly.
//
// Verified with Frida (Home tab and Now Playing): the object exists, isPaused/setPaused: work.
// NOT yet verified: next/previous/shuffle/repeat through this path, background, locked screen.
//
// How the instance is captured (no code patching, plain ObjC method replacement, no JIT needed):
//   - initWithPlayer:testManager:inStreamClient:  -> catches it when Spotify creates it
//   - isPaused / isShuffling getters              -> catches it if it was created before we loaded
// Only a weak reference is kept, so Spotify's object lifetime is unchanged.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "include/EVPlayback.h"

static NSString *const kControllerClass = @"SPTNowPlayingPlaybackControllerImplementation";

static __weak id sController;
static NSString *sCapturedVia = @"not captured";
static BOOL sInstalled;
static IMP sOrigInit, sOrigIsPaused, sOrigIsShuffling;

static void evCapture(id obj, NSString *how) {
    if (!obj) return;
    if (sController != obj) {
        sController = obj;
        sCapturedVia = how;
        NSLog(@"[EeveePlayback] controller captured via %@ (%@ %p)", how, NSStringFromClass(object_getClass(obj)), obj);
    }
}

static id evInitSwz(id self, SEL _cmd, id a, id b, id c) {
    id r = ((id (*)(id, SEL, id, id, id))sOrigInit)(self, _cmd, a, b, c);
    evCapture(r, @"init");
    return r;
}
static BOOL evIsPausedSwz(id self, SEL _cmd) {
    evCapture(self, @"isPaused getter");
    return ((BOOL (*)(id, SEL))sOrigIsPaused)(self, _cmd);
}
static BOOL evIsShufflingSwz(id self, SEL _cmd) {
    evCapture(self, @"isShuffling getter");
    return ((BOOL (*)(id, SEL))sOrigIsShuffling)(self, _cmd);
}

// Replace a method only if its type encoding is what we expect; returns the original IMP.
static IMP evReplace(Class cls, const char *selName, IMP imp, unsigned expectedArgs, char expectedRet) {
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[EeveePlayback] %s not found - skipped", selName); return NULL; }
    char *ret = method_copyReturnType(m);
    char r0 = ret ? ret[0] : '?';
    free(ret);
    BOOL retOK = expectedRet == 'B' ? (r0 == 'B' || r0 == 'c') : r0 == expectedRet;
    if (method_getNumberOfArguments(m) != expectedArgs || !retOK) {
        NSLog(@"[EeveePlayback] %s has unexpected signature (args=%u ret=%c) - skipped", selName, method_getNumberOfArguments(m), r0);
        return NULL;
    }
    IMP inherited = method_getImplementation(m);
    IMP prev = class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m));
    NSLog(@"[EeveePlayback] hooked %s", selName);
    return prev ?: inherited;
}

static void evInstall(int attempt) {
    if (sInstalled) return;
    Class cls = NSClassFromString(kControllerClass);
    if (!cls) {
        if (attempt >= 60) { NSLog(@"[EeveePlayback] class %@ never appeared - giving up", kControllerClass); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ evInstall(attempt + 1); });
        return;
    }
    sInstalled = YES;
    sOrigInit = evReplace(cls, "initWithPlayer:testManager:inStreamClient:", (IMP)evInitSwz, 5, '@');
    sOrigIsPaused = evReplace(cls, "isPaused", (IMP)evIsPausedSwz, 2, 'B');
    sOrigIsShuffling = evReplace(cls, "isShuffling", (IMP)evIsShufflingSwz, 2, 'B');
    NSLog(@"[EeveePlayback] installed after %d attempt(s)", attempt + 1);
}

__attribute__((constructor)) static void evPlaybackInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ evInstall(0); });
}

#pragma mark - Actions

static BOOL evRun(NSString *what, void (^block)(id c)) {
    if (!sController) { NSLog(@"[EeveePlayback] %@: controller not captured yet (open the Now Playing screen once)", what); return NO; }
    void (^run)(void) = ^{
        id c = sController;
        if (!c) { NSLog(@"[EeveePlayback] %@: controller is gone", what); return; }
        @try { block(c); NSLog(@"[EeveePlayback] %@ done", what); }
        @catch (NSException *e) { NSLog(@"[EeveePlayback] %@ threw %@: %@", what, e.name, e.reason); }
    };
    if ([NSThread isMainThread]) run(); else dispatch_async(dispatch_get_main_queue(), run);
    return YES;
}

static BOOL evCall0(id c, const char *selName) {
    SEL s = sel_registerName(selName);
    if (![c respondsToSelector:s]) { NSLog(@"[EeveePlayback] controller lacks %s", selName); return NO; }
    ((void (*)(id, SEL))objc_msgSend)(c, s);
    return YES;
}
static BOOL evCallBool(id c, const char *selName, BOOL v) {
    SEL s = sel_registerName(selName);
    if (![c respondsToSelector:s]) { NSLog(@"[EeveePlayback] controller lacks %s", selName); return NO; }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(c, s, v);
    return YES;
}

BOOL EeveePlaybackAvailable(void) { return sController != nil; }
BOOL EeveePlaybackPlay(void) { return evRun(@"play", ^(id c) { evCallBool(c, "setPaused:", NO); }); }
BOOL EeveePlaybackPause(void) { return evRun(@"pause", ^(id c) { evCallBool(c, "setPaused:", YES); }); }
BOOL EeveePlaybackTogglePause(void) {
    return evRun(@"toggle play/pause", ^(id c) {
        BOOL paused = ((BOOL (*)(id, SEL))objc_msgSend)(c, sel_registerName("isPaused"));
        evCallBool(c, "setPaused:", !paused);
    });
}
BOOL EeveePlaybackNext(void) { return evRun(@"next", ^(id c) { evCallBool(c, "skipToNextWhileDragging:", NO); }); }
BOOL EeveePlaybackPrevious(void) { return evRun(@"previous", ^(id c) { evCallBool(c, "skipToPreviousWhileDragging:", NO); }); }
BOOL EeveePlaybackToggleShuffle(void) { return evRun(@"toggle shuffle", ^(id c) { evCall0(c, "toggleShuffleBehaviour"); }); }
BOOL EeveePlaybackToggleRepeat(void) { return evRun(@"toggle repeat", ^(id c) { evCall0(c, "toggleRepeatMode"); }); }

NSString *EeveePlaybackStatus(void) {
    __block NSString *s = @"controller not captured yet";
    void (^read)(void) = ^{
        id c = sController;
        if (!c) return;
        BOOL paused = ((BOOL (*)(id, SEL))objc_msgSend)(c, sel_registerName("isPaused"));
        BOOL shuf = ((BOOL (*)(id, SEL))objc_msgSend)(c, sel_registerName("isShuffling"));
        int rep = (int)((long (*)(id, SEL))objc_msgSend)(c, sel_registerName("repeatMode"));
        s = [NSString stringWithFormat:@"paused=%d shuffling=%d repeatMode=%d | captured via %@", paused, shuf, rep, sCapturedVia];
    };
    if ([NSThread isMainThread]) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    return s;
}
