// Spotify's now playing info passes through with the artist swapped for the current line, and a timer
// sends it again each time the line changes. Spotify itself only ever sees its own dictionary back.
//
// The timer follows the playback rate rather than running from launch: a paused player's line does not
// move, so working it out four times a second only wakes the phone. The lock screen keeps the line it
// was left on until the sound starts again.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"

static const NSTimeInterval kTick = 0.25;
// Past a line's sung end by this much, with the next line at least this far off, the artist comes back.
static const NSInteger kBreakMs = 4000;
// About what the lock screen's artist row fits before it cuts the text off.
static const NSUInteger kMaxChars = 30;

// Spotify may set the info from any thread; the timer reads it on the main one.
static NSObject *sg_lock;
static NSDictionary *sg_spotifyInfo;
static CFAbsoluteTime sg_spotifyInfoAt;
static NSString *sg_shownLine;
static BOOL sg_resending;
static NSTimer *sg_timer;

static NSString *textOf(NSArray<SGKaraokeWord *> *words) {
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    return SGKaraokeLineText(line);
}

// A line longer than the artist row holds, split into even pieces rather than a full one and a stub.
// Each piece shows from its first word's estimated start.
static NSArray<NSArray<SGKaraokeWord *> *> *piecesOf(SGKaraokeLine *line) {
    NSUInteger length = textOf(line.words).length;
    NSUInteger count = MAX((length + kMaxChars - 1) / kMaxChars, 1);
    NSUInteger target = (length + count - 1) / count;
    NSMutableArray<NSArray<SGKaraokeWord *> *> *pieces = [NSMutableArray array];
    NSMutableArray<SGKaraokeWord *> *piece = [NSMutableArray array];
    NSUInteger pieceLength = 0;
    for (SGKaraokeWord *word in line.words) {
        NSUInteger gap = pieceLength && !word.joined ? 1 : 0;
        NSUInteger withWord = pieceLength ? pieceLength + gap + word.text.length : word.text.length;
        if (pieceLength && (withWord > kMaxChars || (withWord > target && pieces.count + 1 < count))) {
            [pieces addObject:piece];
            piece = [NSMutableArray array];
            withWord = word.text.length;
        }
        [piece addObject:word];
        pieceLength = withWord;
    }
    if (piece.count) [pieces addObject:piece];
    return pieces;
}

// Seconds into the track at `now`, run on from what Spotify last reported.
static double elapsedAt(NSDictionary *info, CFAbsoluteTime reportedAt, CFAbsoluteTime now) {
    double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
    return [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] + rate * (now - reportedAt);
}

// nil between lines and for a track without synced lyrics, plain text included.
static NSString *lineFor(NSDictionary *info, double elapsed) {
    SPTPlayerState *state = [(id<SPTPlayer>)SGKaraokePlayer() state];
    // The player's track can lag behind the now playing info; its lyrics would then be another song's.
    if (![state.track.trackTitle isEqualToString:info[MPMediaItemPropertyTitle]]) return nil;
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        return nil;
    }
    // Plain text has no line being sung to show.
    if (SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) return nil;
    NSInteger position = (NSInteger)(elapsed * 1000);
    NSInteger index = SGKaraokeLeadLine(lines, position);
    if (index < 0) return nil;
    BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > kBreakMs;
    if (position > lines[index].end + kBreakMs && nextFarOff) return nil;
    NSString *shown = nil;
    for (NSArray<SGKaraokeWord *> *piece in piecesOf(lines[index])) {
        if (!shown || piece.firstObject.start <= position) shown = textOf(piece);
    }
    return shown;
}

static NSDictionary *withLine(NSDictionary *info, NSString *line, double elapsed) {
    NSMutableDictionary *shown = [info mutableCopy];
    shown[MPMediaItemPropertyArtist] = line;
    shown[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    return shown;
}

static void tick(void) {
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
        reportedAt = sg_spotifyInfoAt;
    }
    if (!info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double elapsed = elapsedAt(info, reportedAt, now);
    NSString *line = lineFor(info, elapsed);
    if (line == sg_shownLine || [line isEqualToString:sg_shownLine]) return;
    sg_shownLine = line;
    sg_resending = YES;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = line ? withLine(info, line, elapsed) : info;
    sg_resending = NO;
}

// Main thread, as everything the timer touches is.
static void setTicking(BOOL on) {
    if (on == (sg_timer != nil)) return;
    if (!on) {
        [sg_timer invalidate];
        sg_timer = nil;
        return;
    }
    sg_timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
}

// Whether the sound is moving. A rate Spotify did not report at all counts as moving: the line would
// stand still either way, and a missing key is no reason to leave the feature switched off for good.
static BOOL playingBy(NSDictionary *info) {
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    return !rate || rate.doubleValue > 0;
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (sg_resending) {
        %orig;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (sg_lock) {
        sg_spotifyInfo = info;
        sg_spotifyInfoAt = now;
    }
    BOOL playing = playingBy(info) && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] != nil;
    // Karaoke's lyrics are main-thread state; off it the info goes out as it is and the next tick adds the line.
    if (!NSThread.isMainThread || !info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_shownLine = nil;
            setTicking(playing);
        });
        %orig;
        return;
    }
    setTicking(playing);
    double elapsed = elapsedAt(info, now, now);
    NSString *line = lineFor(info, elapsed);
    sg_shownLine = line;
    %orig(line ? withLine(info, line, elapsed) : info);
}

- (NSDictionary *)nowPlayingInfo {
    NSDictionary *info;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
    }
    return info ?: %orig;
}
%end

%ctor {
    if (!SGFlag(SGKeyLockScreenLyrics, NO)) return;
    sg_lock = [NSObject new];
    %init;
    // The timer waits for Spotify to report a playing track; nothing before that has a line to show.
    SGLog(@"lock screen lyrics: on");
}
