// Polls the player and sends the activity a new state only when what its view shows changes: the
// lyrics' line, what is up next, the control menu's tab, track, shuffle, repeat or sleep timer, or a
// pause. The view is read on every tick, so picking another one shows within a tick. Spotify keeps
// playing in the background, so the timer keeps running there too, and with it the sleep timer.
// The activity is started only while the app is in front, the one place ActivityKit allows it.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "LiveActivity.h"

API_AVAILABLE(ios(17.0))
@interface SGLiveActivityBridge : NSObject
@property (class, nonatomic, readonly) BOOL isShowing;
+ (void)showWithView:(NSInteger)view paused:(BOOL)paused line:(NSString *)line nextLine:(NSString *)nextLine
              titles:(NSArray<NSString *> *)titles artists:(NSArray<NSString *> *)artists uris:(NSArray<NSString *> *)uris
                 tab:(NSInteger)tab title:(NSString *)title artist:(NSString *)artist shuffle:(BOOL)shuffle repeatMode:(NSInteger)repeatMode
            timerEnd:(NSDate *)timerEnd timerEndOfTrack:(BOOL)timerEndOfTrack;
+ (void)end;
@end

// The control menu's tabs, SGLyricsAttributes.Tab's values.
typedef NS_ENUM(NSInteger, SGLiveActivityTab) {
    SGLiveActivityTabControls = 0,
    SGLiveActivityTabQueue,
    SGLiveActivityTabTimer,
};

static const NSTimeInterval kTick = 0.25;
// Paused, the only thing on the card that still moves is the sleep timer, and a slower tick catches
// its end well within the second the card shows. Four ticks a second for a still card is a wake up
// eighty times a minute for a picture that does not change.
static const NSTimeInterval kPausedTick = 1;
// Past a line's sung end by this much, with the next line at least this far off, the line gives way to a note.
static const NSInteger kBreakMs = 4000;
// Seconds between attempts to start one, so a refused request (activities turned off) is not retried every tick.
static const NSTimeInterval kStartRetry = 10;
// Tracks up next: the queue view shows four on the lock screen (three in the Dynamic Island), the
// control menu's queue tab three.
static const NSUInteger kUpNextQueue = 4;
static const NSUInteger kUpNextPanel = 3;
// The end of track timer pauses this close to the end, so the next track never starts.
static const NSInteger kEndOfTrackMs = 500;

static NSTimer *sg_timer;
static NSTimeInterval sg_tickEvery;
static NSString *sg_shown;
static NSString *sg_missingLyrics;
static NSDate *sg_lastStart;
static SGLiveActivityTab sg_tab;
// The sleep timer: an end, or the end of the track it was set on.
static NSDate *sg_sleepEnd;
static NSString *sg_sleepTrack;

static void tick(void) API_AVAILABLE(ios(17.0));

// An NSTimer cannot be asked to change pace, so changing it is putting one down and another up.
static void startTimer(NSTimeInterval every) API_AVAILABLE(ios(17.0)) {
    [sg_timer invalidate];
    sg_tickEvery = every;
    sg_timer = [NSTimer timerWithTimeInterval:every repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
}

// Sends `shown`, what the activity is to show as one string, unless it is showing that already; starts
// the activity when there is none and the app is in front.
static void send(NSString *shown, void (^show)(void)) API_AVAILABLE(ios(17.0)) {
    if (SGLiveActivityBridge.isShowing) {
        if ([shown isEqualToString:sg_shown]) return;
    } else {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (sg_lastStart && -sg_lastStart.timeIntervalSinceNow < kStartRetry) return;
        sg_lastStart = [NSDate date];
    }
    sg_shown = shown;
    show();
}

// A track's URI as a string; the player hands out NSURL or NSString.
static NSString *uriOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

// The state's tracks up next, skipping what is not a track or has no title or URI.
static NSArray<SPTPlayerTrack *> *upNext(SPTPlayerState *state) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    for (id track in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (![track isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        if (![(SPTPlayerTrack *)track trackTitle].length || !uriOf(track)) continue;
        [tracks addObject:track];
    }
    return tracks;
}

// 0 off, 1 the playlist or album, 2 the track.
static NSInteger repeatModeOf(SPTPlayerOptions *options) {
    return options.repeatingTrack ? 2 : options.repeatingContext ? 1 : 0;
}

// The line being sung and the one after it; before the first line, between lines and without lyrics
// at all, a note holds the place.
static NSString *lyricsLine(NSString *trackID, NSString **next) {
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        if (trackID && ![trackID isEqualToString:sg_missingLyrics]) {
            sg_missingLyrics = trackID;
            SGLog(@"live activity: no lyrics yet for %@", trackID);
        }
    }
    // Plain text has no line being sung: the note, as for a track with no lyrics.
    if (lines && SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) lines = nil;
    NSInteger position = SGKaraokePositionMs();
    // With two voices at once, the one that came in first, and the one singing over it as the next.
    NSInteger index = SGKaraokeLeadLine(lines, position);
    *next = index + 1 < (NSInteger)lines.count ? SGKaraokeLineText(lines[index + 1]) : @"";
    if (index < 0) return @"♪";
    SGKaraokeLine *current = lines[index];
    BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > kBreakMs;
    return position > current.end + kBreakMs && nextFarOff ? @"♪" : SGKaraokeLineText(current);
}

static void clearSleepTimer(void) {
    sg_sleepEnd = nil;
    sg_sleepTrack = nil;
}

// Pauses once the sleep timer is up: at its end, or just before the end of the track it was set on
// (on the next track, should the length not be known).
static void checkSleepTimer(id<SPTPlayer> player, SPTPlayerState *state, NSString *trackID) {
    BOOL up = NO;
    if (sg_sleepEnd) {
        up = sg_sleepEnd.timeIntervalSinceNow <= 0;
    } else if (sg_sleepTrack) {
        double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
        NSInteger position = SGKaraokePositionMs();
        up = ![trackID isEqualToString:sg_sleepTrack]
            || (duration > 0 && position >= 0 && duration * 1000 - position < kEndOfTrackMs);
    }
    if (!up) return;
    clearSleepTimer();
    if (!state.isPaused) [player pause:nil];
    SGLog(@"live activity: sleep timer up, paused");
}

static void tick(void) API_AVAILABLE(ios(17.0)) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    SPTPlayerTrack *track = state.track;
    if (!track.trackTitle.length) return;
    NSString *trackID = SGKaraokePlayingTrack();
    checkSleepTimer(player, state, trackID);

    NSInteger view = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
    BOOL paused = state.isPaused;
    NSTimeInterval every = paused ? kPausedTick : kTick;
    if (sg_timer && sg_tickEvery != every) startTimer(every);
    NSString *line = @"", *next = @"";
    if (view == SGLiveActivityLyrics) line = lyricsLine(trackID, &next);

    NSMutableArray<NSString *> *titles = [NSMutableArray array], *artists = [NSMutableArray array], *uris = [NSMutableArray array];
    if (view != SGLiveActivityLyrics) {
        NSUInteger limit = view == SGLiveActivityQueue ? kUpNextQueue : kUpNextPanel;
        for (SPTPlayerTrack *upcoming in upNext(state)) {
            if (titles.count == limit) break;
            [titles addObject:upcoming.trackTitle];
            [artists addObject:upcoming.artistName ?: @""];
            [uris addObject:uriOf(upcoming)];
        }
    }

    BOOL panel = view == SGLiveActivityPanel;
    NSString *title = panel ? track.trackTitle : @"", *artist = panel ? track.artistName ?: @"" : @"";
    BOOL shuffle = panel && state.options.shufflingContext;
    NSInteger repeatMode = panel ? repeatModeOf(state.options) : 0;
    NSInteger tab = panel ? sg_tab : 0;
    NSDate *sleepEnd = sg_sleepEnd;
    BOOL endOfTrack = sg_sleepTrack != nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:@(view).stringValue, paused ? @"1" : @"0", line, next,
        @(tab).stringValue, title, artist, shuffle ? @"1" : @"0", @(repeatMode).stringValue,
        @((long long)sleepEnd.timeIntervalSince1970).stringValue, endOfTrack ? @"1" : @"0", nil];
    for (NSUInteger i = 0; i < titles.count; i++) [parts addObject:[NSString stringWithFormat:@"%@\t%@\t%@", titles[i], artists[i], uris[i]]];
    send([parts componentsJoinedByString:@"\n"], ^{
        [SGLiveActivityBridge showWithView:view paused:paused line:line nextLine:next titles:titles artists:artists uris:uris
                                        tab:tab title:title artist:artist shuffle:shuffle repeatMode:repeatMode
                                   timerEnd:sleepEnd timerEndOfTrack:endOfTrack];
    });
}

// A tap on a track up next: skips ahead to it, found again by its URI in case the queue moved since
// the card was drawn.
static void playQueued(NSString *uri) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerTrack *target = nil;
    for (SPTPlayerTrack *track in upNext(player.state)) {
        if ([uriOf(track) isEqualToString:uri]) { target = track; break; }
    }
    if (!target || ![player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
        SGLog(@"live activity: cannot play %@ (in the queue: %@, player %@)", uri, target ? @"yes" : @"no", player ? NSStringFromClass([player class]) : @"nil");
        return;
    }
    id result = [player skipToNextTrackWithOptions:nil track:target];
    SGLog(@"live activity: play %@ -> %@", uri, result);
}

// A tap in the control menu, one of SGLiveActivityActionIntent's actions.
static void runAction(NSString *action) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    NSArray<NSString *> *parts = [action componentsSeparatedByString:@":"];
    NSString *name = parts.firstObject, *value = parts.count > 1 ? parts[1] : @"";
    id result = nil;
    if ([name isEqualToString:@"tab"]) {
        sg_tab = MAX(SGLiveActivityTabControls, MIN(SGLiveActivityTabTimer, value.integerValue));
    } else if ([name isEqualToString:@"toggle"]) {
        result = state.isPaused ? [player resume:nil] : [player pause:nil];
    } else if ([name isEqualToString:@"previous"]) {
        result = [player skipToPreviousTrackWithOptions:nil];
    } else if ([name isEqualToString:@"next"]) {
        result = [player skipToNextTrackWithOptions:nil];
    } else if ([name isEqualToString:@"shuffle"]) {
        result = [player setShufflingContext:!state.options.shufflingContext];
    } else if ([name isEqualToString:@"repeat"]) {
        // Off, then the playlist or album, then the track, then off again, the way Spotify's button goes.
        switch (repeatModeOf(state.options)) {
            case 0: result = [player setRepeatingContext:YES]; break;
            case 1: result = [player setRepeatingTrack:YES]; break;
            default:
                [player setRepeatingTrack:NO];
                result = [player setRepeatingContext:NO];
        }
    } else if ([name isEqualToString:@"timer"]) {
        if ([value isEqualToString:@"cancel"]) {
            clearSleepTimer();
        } else if ([value isEqualToString:@"track"]) {
            clearSleepTimer();
            sg_sleepTrack = SGKaraokePlayingTrack();
        } else if ([value isEqualToString:@"add"]) {
            NSDate *from = sg_sleepEnd && sg_sleepEnd.timeIntervalSinceNow > 0 ? sg_sleepEnd : [NSDate date];
            sg_sleepEnd = [from dateByAddingTimeInterval:15 * 60];
        } else if (value.integerValue > 0) {
            clearSleepTimer();
            sg_sleepEnd = [NSDate dateWithTimeIntervalSinceNow:value.integerValue * 60];
        }
    } else {
        SGLog(@"live activity: unknown action %@", action);
        return;
    }
    SGLog(@"live activity: %@ -> %@", action, result);
}

void SGSetLiveActivityEnabled(BOOL on) {
    if (@available(iOS 17.0, *)) {
        [sg_timer invalidate];
        sg_timer = nil;
        sg_shown = nil;
        sg_lastStart = nil;
        clearSleepTimer();
        if (!on) {
            [SGLiveActivityBridge end];
            SGLog(@"live activity: off");
            return;
        }
        static dispatch_once_t observing;
        dispatch_once(&observing, ^{
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:@"SGLiveActivityPlay" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([note.object isKindOfClass:NSString.class]) playQueued(note.object);
            }];
            // The new state goes out at once rather than on the next tick, the card being slow enough to redraw.
            [center addObserverForName:@"SGLiveActivityAction" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (![note.object isKindOfClass:NSString.class]) return;
                runAction(note.object);
                if (sg_timer) tick();
            }];
        });
        startTimer(kTick);
        SGLog(@"live activity: on");
    }
}

%ctor {
    if (@available(iOS 17.0, *)) {
        // It was the redesign's alone until it moved to Shared/; whoever had it on keeps it on.
        SGMigrateKey(SGKeyLiveActivityWas, SGKeyLiveActivity);
        SGMigrateKey(SGKeyLiveActivityViewWas, SGKeyLiveActivityView);
        BOOL on = SGFlag(SGKeyLiveActivity, NO);
        // Off, one left from a launch before the switch went off is ended.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (on) SGSetLiveActivityEnabled(YES);
            else [SGLiveActivityBridge end];
        });
    }
}
