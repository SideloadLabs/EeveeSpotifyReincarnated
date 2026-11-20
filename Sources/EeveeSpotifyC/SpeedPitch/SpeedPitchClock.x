// keeps Spotify's progress bar and lyrics in step with the speed (README.md, the progress bar). every Spotify
// name the feature uses is here; a hook group only goes in when its methods exist.
%config(generator=internal);

#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import "SpeedPitchPrivate.h"

// only what this file reads; the names are Spotify's.
@interface SPTPlayerTrack : NSObject
@property (nonatomic, readonly) id URI;
@end

@interface SPTPlayerState : NSObject
@property (nonatomic, readonly) SPTPlayerTrack *track;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) double position;
@property (nonatomic, readonly) NSDate *timestamp;
@property (nonatomic, readonly) double playbackSpeed;
@end

// the latest state Spotify's player reported, main thread.
static SPTPlayerState *sg_playerState;

// Spotify's own answer in the last -position on this thread, before ours replaced it.
static _Thread_local double sg_spotifyPosition;

// our clock: `on` while it counts, from `position` when SpeedPitchEnginePlayedSeconds() was `played`, at `rate`
// (Spotify's own speed). `armed` starts it at the first report from `notBefore`; `away` after the music
// played elsewhere.
static struct {
    BOOL on, armed, away;
    CFAbsoluteTime notBefore;
    double position, played, rate;
} sg_clock;

// Spotify playing this long with nothing through the engine: the music is elsewhere (Connect, or Spotify's
// own connection).
static const double kAwayAfter = 3;
static _Atomic double sg_playingSince;     // since when Spotify's player says it plays, 0 while it doesn't

// -playbackSpeed asked for Spotify's own speed, without ours.
static _Thread_local BOOL sg_native;

// -position may be asked again from inside itself; only the outer one corrects.
static _Thread_local BOOL sg_correcting;

// the newest report, to spot a seek made elsewhere: one more than kSeekGap from where the last would be by then.
static struct {
    CFAbsoluteTime stamp;
    double asOf, speed;
} sg_lastReport;
static CFAbsoluteTime sg_speedChangedAt;
static const double kSeekGap = 3;
static NSString *sg_clockTrack;            // the track our clock counts for
static os_unfair_lock sg_clockLock = OS_UNFAIR_LOCK_INIT;

static NSString *trackOf(SPTPlayerState *state) {
    return [state.track.URI description];
}

// 1 for music, a podcast's chosen speed (Spotify's zephyr), 0 while stalled.
static double nativeSpeed(SPTPlayerState *state) {
    sg_native = YES;
    double speed = state.playbackSpeed;
    sg_native = NO;
    return speed;
}

// whether the music plays through the engine, at our speed; not paused there's nothing to tell by.
static BOOL playsHere(void) {
    double since = atomic_load_explicit(&sg_playingSince, memory_order_relaxed);
    return since <= 0 || CFAbsoluteTimeGetCurrent() - since < kAwayAfter || SpeedPitchEngineSecondsSincePlayed() < kAwayAfter;
}

// away from 1x, Spotify's next report from now restarts our clock.
static void rearmClock(void) {
    os_unfair_lock_lock(&sg_clockLock);
    sg_clock = (typeof(sg_clock)){.armed = SpeedPitchEngineSpeed() != 1, .notBefore = CFAbsoluteTimeGetCurrent()};
    os_unfair_lock_unlock(&sg_clockLock);
}

// back to Spotify's clock from here, and the unit starts clean at the new place.
static void handBack(void) {
    rearmClock();
    SpeedPitchEngineResetUnit();
}

// each report Spotify's player makes. a stall (speed 0 where the core stopped) leaves our clock ahead, having
// counted the zeros the mixer handed over, so it hands the clock back to Spotify's.
static void noteState(id state) {
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")]) return;
    dispatch_block_t note = ^{
        SPTPlayerState *playerState = state;
        sg_playerState = playerState;
        SEL isBuffering = NSSelectorFromString(@"isBuffering");
        BOOL buffering = [playerState respondsToSelector:isBuffering] && [[playerState valueForKey:@"isBuffering"] boolValue];
        BOOL stalled = buffering || nativeSpeed(playerState) == 0;
        BOOL playing = playerState.isPlaying && !playerState.isPaused;
        if (!playing || stalled) {
            atomic_store_explicit(&sg_playingSince, 0, memory_order_relaxed);
        } else if (atomic_load_explicit(&sg_playingSince, memory_order_relaxed) <= 0) {
            atomic_store_explicit(&sg_playingSince, CFAbsoluteTimeGetCurrent(), memory_order_relaxed);
        }
        os_unfair_lock_lock(&sg_clockLock);
        BOOL counting = sg_clock.on;
        os_unfair_lock_unlock(&sg_clockLock);
        if (playing && stalled && (counting || SpeedPitchEngineSpeed() != 1)) rearmClock();
    };
    if (NSThread.isMainThread) note();
    else dispatch_async(dispatch_get_main_queue(), note);
}

@interface EeveeSpeedPitchObserver : NSObject
@end

@implementation EeveeSpeedPitchObserver
- (void)player:(id)player stateDidChange:(id)state {
    noteState(state);
}

// the rest of the observer calls, in case Spotify sends one unchecked.
- (void)player:(id)player didEncounterError:(id)error {}
- (void)player:(id)player didMoveToRelativeTrack:(NSInteger)relativeIndex {}
- (void)player:(id)player queueDidChange:(id)queue {}
@end

static EeveeSpeedPitchObserver *sg_observer;

%group EeveeSpeedPitchClock
%hook SPTPlayerState
- (double)playbackSpeed {
    double speed = %orig;
    if (sg_native) return speed;
    float ours = SpeedPitchEngineSpeed();
    return ours > 0 && ours != 1 && playsHere() ? speed * ours : speed;
}

- (double)position {
    if (sg_correcting) return %orig;
    sg_correcting = YES;
    double position = %orig;
    sg_correcting = NO;
    sg_spotifyPosition = position;
    if (position < 0) return position;
    BOOL counting = sg_clock.on || sg_clock.armed;
    NSString *track = counting ? trackOf(self) : nil;
    double played = SpeedPitchEnginePlayedSeconds();
    // 0 when not asked: another thread may have started the clock since `counting` was read.
    double native = counting ? nativeSpeed(self) : 0;
    BOOL here = playsHere();
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(), stamp = self.timestamp.timeIntervalSinceReferenceDate;
    double speed = self.isPaused ? 0 : self.playbackSpeed, asOf = position - (now - stamp) * speed;
    os_unfair_lock_lock(&sg_clockLock);
    BOOL seeked = NO;
    if (stamp > sg_lastReport.stamp) {
        if (sg_lastReport.stamp > sg_speedChangedAt) seeked = fabs(asOf - (sg_lastReport.asOf + (stamp - sg_lastReport.stamp) * sg_lastReport.speed)) > kSeekGap;
        sg_lastReport = (typeof(sg_lastReport)){stamp, asOf, speed};
    }
    BOOL seekedAway = sg_clock.on && seeked;
    if (seekedAway || (sg_clock.on && track && ![track isEqualToString:sg_clockTrack])) {
        sg_clock = (typeof(sg_clock)){.armed = SpeedPitchEngineSpeed() != 1};
    }
    // elsewhere Spotify's clock is the right one, at the other device's speed.
    BOOL wentAway = sg_clock.on && !here;
    if (wentAway) sg_clock = (typeof(sg_clock)){.armed = SpeedPitchEngineSpeed() != 1, .away = YES};
    // back only once song comes through again: paused on the other device there's nothing to tell by.
    BOOL back = !sg_clock.away || SpeedPitchEngineSecondsSincePlayed() < 1;
    if (!sg_clock.on && sg_clock.armed && here && back && track && stamp >= sg_clock.notBefore) {
        // back from elsewhere: from where Spotify's clock had it.
        double from = !sg_clock.away ? position : asOf + (self.isPaused ? 0 : (now - stamp) * native);
        sg_clock = (typeof(sg_clock)){.on = YES, .position = from, .played = played, .rate = native > 0 ? native : 1};
        sg_clockTrack = track;
    }
    if (sg_clock.on) {
        // Spotify's own speed changed (a podcast's): what came before counts at the old one.
        if (native > 0 && native != sg_clock.rate && stamp >= sg_lastReport.stamp) {
            sg_clock.position += (played - sg_clock.played) * sg_clock.rate;
            sg_clock.played = played;
            sg_clock.rate = native;
        }
        // while paused too: Spotify's paused report is just as far behind.
        position = sg_clock.position + (played - sg_clock.played) * sg_clock.rate;
    }
    os_unfair_lock_unlock(&sg_clockLock);
    if (seekedAway) SPLog(@"Spotify moved to %.1f s without a seek here; the clock starts over", asOf);
    if (wentAway) SPLog(@"Spotify plays, but nothing has come through the engine for %.0f s (Connect, or Spotify's own connection): Spotify's clock until it does",
                        kAwayAfter);
    return position;
}
%end
%end

// observers are added from several threads as the app starts; the first player seen is the one watched.
%group EeveeSpeedPitchObserve
%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    id player = self;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_observer = [EeveeSpeedPitchObserver new];
            ((void (*)(id, SEL, id))objc_msgSend)(player, @selector(addPlayerObserver:), sg_observer);
            SEL stateSelector = NSSelectorFromString(@"state");
            if ([player respondsToSelector:stateSelector]) noteState(((id (*)(id, SEL))objc_msgSend)(player, stateSelector));
        });
    });
}
%end
%end

// without these the clock spots jumps in Spotify's reports instead.
%group EeveeSpeedPitchHandBack
%hook SPTEsperantoPlayer
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator {
    handBack();
    return %orig;
}

- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    handBack();
    return %orig;
}

- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    handBack();
    return %orig;
}

- (id)stop {
    handBack();
    return %orig;
}
%end
%end

static BOOL hasMethods(NSString *className, NSArray<NSString *> *selectors) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        SPLog(@"%@ is missing", className);
        return NO;
    }
    BOOL all = YES;
    for (NSString *selector in selectors) {
        if (class_getInstanceMethod(cls, NSSelectorFromString(selector))) continue;
        SPLog(@"-[%@ %@] is missing", className, selector);
        all = NO;
    }
    return all;
}

BOOL SpeedPitchClockInstall(void) {
    BOOL hooked = hasMethods(@"SPTPlayerState", @[@"playbackSpeed", @"position", @"timestamp", @"track", @"isPaused", @"isPlaying"]);
    // braces around each %init: it expands to a block, and the `;` after it would end an if before its else.
    if (hooked) {
        %init(EeveeSpeedPitchClock);
    } else {
        SPLog(@"Spotify's clock cannot follow the speed, so speed is off");
    }
    NSString *player = @"SPTEsperantoPlayer";
    if (hasMethods(player, @[@"addPlayerObserver:"])) {
        %init(EeveeSpeedPitchObserve);
    }
    if (hasMethods(player, @[@"seekTo:relative:options:creatorTimestampPositionMs:", @"skipToNextTrackWithOptions:track:loggingParams:",
                             @"skipToPreviousTrackWithOptions:track:loggingParams:", @"stop"])) {
        %init(EeveeSpeedPitchHandBack);
    }
    return hooked;
}

void SpeedPitchClockSpeedWillChange(float from, float to) {
    // Spotify's count is still right before the speed leaves 1x, so our clock starts from it.
    SPTPlayerState *state = sg_playerState;
    sg_spotifyPosition = -1;
    [state position];
    double position = sg_spotifyPosition, native = state ? nativeSpeed(state) : 1;
    NSString *track = state ? trackOf(state) : nil;
    os_unfair_lock_lock(&sg_clockLock);
    if (!sg_clock.on && !sg_clock.armed && to != 1) {
        if (track && position >= 0) {
            sg_clock = (typeof(sg_clock)){.on = YES, .position = position, .played = SpeedPitchEnginePlayedSeconds(), .rate = native > 0 ? native : 1};
            sg_clockTrack = track;
        } else {
            // no report yet: the next one starts it.
            sg_clock = (typeof(sg_clock)){.armed = YES, .notBefore = CFAbsoluteTimeGetCurrent()};
        }
    }
    if (to != from) sg_speedChangedAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&sg_clockLock);
}
