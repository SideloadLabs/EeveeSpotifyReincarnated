// keeps Spotify's progress bar and lyrics in step with the speed. every Spotify class and method name the
// feature uses is here; each hook group only goes in when its methods exist, and a missing one is logged.
//
// between its player's reports Spotify counts the position itself: -[SPTPlayerState position] is the
// reported position plus the time since, times -playbackSpeed, so playbackSpeed is scaled by our speed.
// once the speed leaves 1x, -position answers from our own clock instead: Spotify's position at that
// moment plus the song the engine has handed over since. a seek, skip, stop, new track or stall hands the
// clock back to Spotify's, and the next report away from 1x starts ours again.
%config(generator=internal);

#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
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

// our clock: `on` while it counts, from `position` seconds into the song when SpeedPitchEnginePlayedSeconds()
// was `played`. `armed` starts it at the first report stamped at or after `notBefore`.
static struct {
    BOOL on, armed;
    CFAbsoluteTime notBefore;
    double position, played;
} sg_clock;

// -position may be asked again from inside itself; only the outer one corrects.
static _Thread_local BOOL sg_correcting;

// the newest report, to spot a seek made elsewhere (another device over Connect): a report more than kSeekGap
// seconds from where the one before would be by then, both made since the speed last changed.
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

// each report Spotify's player makes. away from 1x its core sometimes can't keep up and stalls: the mixer
// hands over zeros and the core reports speed 0 where it stopped, then resumes from there. our clock counted
// the zeros and is ahead by then, so a stall hands the clock back to Spotify's.
static void noteState(id state) {
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")]) return;
    dispatch_block_t note = ^{
        SPTPlayerState *playerState = state;
        sg_playerState = playerState;
        if (SpeedPitchEngineSpeed() == 1 || !playerState.isPlaying || playerState.isPaused) return;
        SEL isBuffering = NSSelectorFromString(@"isBuffering");
        BOOL buffering = [playerState respondsToSelector:isBuffering] && [[playerState valueForKey:@"isBuffering"] boolValue];
        if (buffering || playerState.playbackSpeed == 0) rearmClock();
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

// the rest of the observer calls, as eevee's karaoke observer has them, in case Spotify sends one unchecked.
- (void)player:(id)player didEncounterError:(id)error {}
- (void)player:(id)player didMoveToRelativeTrack:(NSInteger)relativeIndex {}
- (void)player:(id)player queueDidChange:(id)queue {}
@end

static EeveeSpeedPitchObserver *sg_observer;

%group EeveeSpeedPitchClock
%hook SPTPlayerState
- (double)playbackSpeed {
    double speed = %orig;
    float ours = SpeedPitchEngineSpeed();
    return ours > 0 && ours != 1 ? speed * ours : speed;
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
    CFAbsoluteTime stamp = self.timestamp.timeIntervalSinceReferenceDate;
    double speed = self.isPaused ? 0 : self.playbackSpeed, asOf = position - (CFAbsoluteTimeGetCurrent() - stamp) * speed;
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
    if (!sg_clock.on && sg_clock.armed && track && stamp >= sg_clock.notBefore) {
        sg_clock = (typeof(sg_clock)){.on = YES, .position = position, .played = played};
        sg_clockTrack = track;
    }
    // while paused too: Spotify's paused report is just as far behind.
    if (sg_clock.on) position = sg_clock.position + (played - sg_clock.played);
    os_unfair_lock_unlock(&sg_clockLock);
    if (seekedAway) SPLog(@"Spotify moved to %.1f s without a seek here; the clock starts over", asOf);
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

%group EeveeSpeedPitchSeek
%hook SPTEsperantoPlayer
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator {
    handBack();
    return %orig;
}
%end
%end

%group EeveeSpeedPitchSkipNext
%hook SPTEsperantoPlayer
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    handBack();
    return %orig;
}
%end
%end

%group EeveeSpeedPitchSkipPrevious
%hook SPTEsperantoPlayer
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    handBack();
    return %orig;
}
%end
%end

%group EeveeSpeedPitchStop
%hook SPTEsperantoPlayer
- (id)stop {
    handBack();
    return %orig;
}
%end
%end

// a group only goes in when all its methods exist, so a Spotify update that renames one only loses that piece.
static BOOL hasMethods(NSString *className, NSArray<NSString *> *selectors) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        SPLog(@"%@ is missing", className);
        return NO;
    }
    for (NSString *selector in selectors) {
        if (class_getInstanceMethod(cls, NSSelectorFromString(selector))) continue;
        SPLog(@"-[%@ %@] is missing", className, selector);
        return NO;
    }
    return YES;
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
    if (hasMethods(player, @[@"seekTo:relative:options:creatorTimestampPositionMs:"])) {
        %init(EeveeSpeedPitchSeek);
    }
    if (hasMethods(player, @[@"skipToNextTrackWithOptions:track:loggingParams:"])) {
        %init(EeveeSpeedPitchSkipNext);
    }
    if (hasMethods(player, @[@"skipToPreviousTrackWithOptions:track:loggingParams:"])) {
        %init(EeveeSpeedPitchSkipPrevious);
    }
    if (hasMethods(player, @[@"stop"])) {
        %init(EeveeSpeedPitchStop);
    }
    return hooked;
}

void SpeedPitchClockSpeedWillChange(float from, float to) {
    // Spotify's count is still right before the speed leaves 1x, so our clock starts from it.
    SPTPlayerState *state = sg_playerState;
    sg_spotifyPosition = -1;
    [state position];
    double position = sg_spotifyPosition;
    NSString *track = state ? trackOf(state) : nil;
    os_unfair_lock_lock(&sg_clockLock);
    if (!sg_clock.on && !sg_clock.armed && to != 1) {
        if (track && position >= 0) {
            sg_clock = (typeof(sg_clock)){.on = YES, .position = position, .played = SpeedPitchEnginePlayedSeconds()};
            sg_clockTrack = track;
        } else {
            // no report yet: the next one starts it.
            sg_clock = (typeof(sg_clock)){.armed = YES, .notBefore = CFAbsoluteTimeGetCurrent()};
        }
    }
    if (to != from) sg_speedChangedAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&sg_clockLock);
}
