// RecorderSupport.m - logging, settings, track metadata, splitting and export.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import <sys/time.h>
#import <pthread.h>
#import <math.h>
#import <mach/mach.h>
#import <errno.h>
#import "EVRecorderInternal.h"

#pragma mark - Logger

static dispatch_queue_t evLogQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t o;
    dispatch_once(&o, ^{ q = dispatch_queue_create("eevee.recorder.log", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static NSMutableArray<NSString *> *evRing;
static FILE *evLogFile;
static unsigned long long evLogBytes;
static _Atomic(int) evAppState;

NSString *EVLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"eevee_recorder.log"];
}

static void evAppend(NSString *line) {            // runs on the log queue
    if (!evRing) evRing = [NSMutableArray array];
    [evRing addObject:line];
    if (evRing.count > 500) [evRing removeObjectsInRange:NSMakeRange(0, evRing.count - 500)];
    if (!evLogFile) {
        evLogFile = fopen(EVLogPath().fileSystemRepresentation, "a");
        if (evLogFile) { fseeko(evLogFile, 0, SEEK_END); evLogBytes = (unsigned long long)ftello(evLogFile); }
    }
    if (!evLogFile) return;
    fputs(line.UTF8String, evLogFile); fputc('\n', evLogFile); fflush(evLogFile);
    evLogBytes += line.length + 1;
    if (evLogBytes > 3ull * 1024 * 1024) {          // rotate at 3 MB
        fclose(evLogFile); evLogFile = NULL; evLogBytes = 0;
        NSString *p = EVLogPath(), *old = [p stringByAppendingString:@".1"];
        [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
        [[NSFileManager defaultManager] moveItemAtPath:p toPath:old error:nil];
    }
}

void EVLogSetAppState(int s) { atomic_store(&evAppState, s); }

void EVLogf(EVLogLevel level, const char *tag, NSString *fmt, ...) {
    if (level >= EVLogDebug && !EVSettingBool(@"verbose", NO)) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv; time_t sec = tv.tv_sec; localtime_r(&sec, &tmv);
    char ts[40]; strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    static const char lv[] = "EWIDT";
    int st = atomic_load(&evAppState);
    char sc = st == 0 ? 'A' : (st == 1 ? 'I' : 'B');
    mach_port_t tid = pthread_mach_thread_np(pthread_self());
    NSString *line = [NSString stringWithFormat:@"%s.%03d %c %c [%s] (%@%x) %@", ts, (int)(tv.tv_usec / 1000),
                      lv[level < 5 ? level : 4], sc, tag, [NSThread isMainThread] ? @"main" : @"t", tid, msg];
    NSLog(@"[EeveeRec][%s] %@", tag, msg);
    dispatch_async(evLogQueue(), ^{ evAppend(line); });
}

void EVLogFlush(void) {
    dispatch_sync(evLogQueue(), ^{ if (evLogFile) fflush(evLogFile); });
}
NSArray<NSString *> *EVLogTail(NSUInteger n) {
    __block NSArray *out;
    dispatch_sync(evLogQueue(), ^{
        NSUInteger c = evRing.count;
        out = c <= n ? [evRing copy] : [evRing subarrayWithRange:NSMakeRange(c - n, n)];
    });
    return out ?: @[];
}
void EVLogClear(void) {
    dispatch_sync(evLogQueue(), ^{
        [evRing removeAllObjects];
        if (evLogFile) { fclose(evLogFile); evLogFile = NULL; }
        evLogBytes = 0;
        [[NSFileManager defaultManager] removeItemAtPath:EVLogPath() error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[EVLogPath() stringByAppendingString:@".1"] error:nil];
    });
}

#pragma mark - Settings / paths

static NSString *evKey(NSString *k) { return [@"EVRec." stringByAppendingString:k]; }
BOOL EVSettingBool(NSString *k, BOOL d) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:evKey(k)];
    return v ? [v boolValue] : d;
}
void EVSetSettingBool(NSString *k, BOOL v) { [[NSUserDefaults standardUserDefaults] setBool:v forKey:evKey(k)]; }
NSInteger EVSettingInt(NSString *k, NSInteger d) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:evKey(k)];
    return v ? [v integerValue] : d;
}
void EVSetSettingInt(NSString *k, NSInteger v) { [[NSUserDefaults standardUserDefaults] setInteger:v forKey:evKey(k)]; }
NSString *EVSettingString(NSString *k, NSString *d) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:evKey(k)];
    return v ?: d;
}
void EVSetSettingString(NSString *k, NSString *v) { [[NSUserDefaults standardUserDefaults] setObject:v forKey:evKey(k)]; }

NSURL *EVRecordingsRoot(void) {
    NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *u = [docs URLByAppendingPathComponent:@"Recordings" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];
    return u;
}

NSString *EVFormatTime(double s) {
    if (s < 0 || !isfinite(s)) s = 0;
    long long ms = (long long)llround(s * 1000.0);
    return [NSString stringWithFormat:@"%lld:%02lld.%03lld", ms / 60000, (ms / 1000) % 60, ms % 1000];
}

#pragma mark - Track model

@implementation EVTrackInfo
- (NSDictionary *)dictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    void (^s)(NSString *, id) = ^(NSString *k, id v) { if (v) d[k] = v; };
    s(@"key", self.key); s(@"title", self.title); s(@"artist", self.artist); s(@"album", self.album);
    s(@"albumArtist", self.albumArtist); s(@"genre", self.genre); s(@"uri", self.uri); s(@"isrc", self.isrc);
    if (self.trackNumber) d[@"trackNumber"] = @(self.trackNumber);
    if (self.trackCount) d[@"trackCount"] = @(self.trackCount);
    if (self.discNumber) d[@"discNumber"] = @(self.discNumber);
    if (self.year) d[@"year"] = @(self.year);
    if (self.duration > 0) d[@"expectedDuration"] = @(self.duration);
    return d;
}
+ (instancetype)fromDictionary:(NSDictionary *)d {
    EVTrackInfo *t = [EVTrackInfo new];
    t.key = d[@"key"]; t.title = d[@"title"]; t.artist = d[@"artist"]; t.album = d[@"album"];
    t.albumArtist = d[@"albumArtist"]; t.genre = d[@"genre"]; t.uri = d[@"uri"]; t.isrc = d[@"isrc"];
    t.trackNumber = [d[@"trackNumber"] integerValue]; t.trackCount = [d[@"trackCount"] integerValue];
    t.discNumber = [d[@"discNumber"] integerValue]; t.year = [d[@"year"] integerValue];
    t.duration = [d[@"expectedDuration"] doubleValue];
    return t;
}
@end

@implementation EVMarker @end

#pragma mark - Now-playing watcher

static dispatch_source_t evMetaTimer;
static dispatch_queue_t evMetaQ;
static EVTrackChangeBlock evMetaBlock;
static NSString *evLastKey;
static double evLastElapsed, evLastDuration;
static uint64_t evLastTickFrames;
static EVTrackInfo *evCurrent;
static NSString *evArtKey;
static NSUInteger evMissCount;
static NSDictionary *evExtra;
static NSString *evLastNowPlayingNote = @"not started";
static BOOL evWaitingForFreshStart;

static NSString *EVStr(id v) { return [v isKindOfClass:NSString.class] && [(NSString *)v length] ? v : nil; }
// Spotify appends an ephemeral playback-session id after '#'.  It changes when
// another app takes audio focus, but the text before it identifies the song.
static NSString *EVStableTrackKey(NSString *identifier) {
    NSRange hash = [identifier rangeOfString:@"#"];
    return hash.location == NSNotFound ? identifier : [identifier substringToIndex:hash.location];
}

static EVTrackInfo *EVReadNowPlaying(void) {
    NSDictionary *d = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
    if (![d isKindOfClass:NSDictionary.class] || d.count == 0) return nil;
    EVTrackInfo *t = [EVTrackInfo new];
    t.title = EVStr(d[MPMediaItemPropertyTitle]);
    t.artist = EVStr(d[MPMediaItemPropertyArtist]);
    t.album = EVStr(d[MPMediaItemPropertyAlbumTitle]);
    t.albumArtist = EVStr(d[MPMediaItemPropertyAlbumArtist]);
    t.genre = EVStr(d[MPMediaItemPropertyGenre]);
    t.trackNumber = [d[MPMediaItemPropertyAlbumTrackNumber] integerValue];
    t.trackCount = [d[MPMediaItemPropertyAlbumTrackCount] integerValue];
    t.discNumber = [d[MPMediaItemPropertyDiscNumber] integerValue];
    t.duration = [d[MPMediaItemPropertyPlaybackDuration] doubleValue];
    t.elapsed = [d[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
    t.artworkObject = d[MPMediaItemPropertyArtwork];
    NSString *ext = EVStr(d[MPNowPlayingInfoPropertyExternalContentIdentifier]);
    t.uri = ext;
    t.key = ext.length ? EVStableTrackKey(ext) : [NSString stringWithFormat:@"%@|%@|%@|%.0f", t.title ?: @"", t.artist ?: @"", t.album ?: @"", t.duration];
    return t;
}

static void EVApplyExtra(EVTrackInfo *t) {
    NSDictionary *x; @synchronized([EVTrackInfo class]) { x = evExtra; }
    if (!x.count) return;
    NSString *xt = EVStr(x[@"title"]);
    if (xt && t.title && [xt caseInsensitiveCompare:t.title] != NSOrderedSame) return;   // belongs to another track
    NSString *(^S)(NSString *) = ^NSString *(NSString *k) { return EVStr(x[k]); };
    if (S(@"artist")) t.artist = S(@"artist");
    if (S(@"album")) t.album = S(@"album");
    if (S(@"albumArtist")) t.albumArtist = S(@"albumArtist");
    if (S(@"genre")) t.genre = S(@"genre");
    if (S(@"uri")) t.uri = S(@"uri");
    if (S(@"isrc")) t.isrc = S(@"isrc");
    if ([x[@"trackNumber"] integerValue]) t.trackNumber = [x[@"trackNumber"] integerValue];
    if ([x[@"discNumber"] integerValue]) t.discNumber = [x[@"discNumber"] integerValue];
    if ([x[@"year"] integerValue]) t.year = [x[@"year"] integerValue];
}

void EeveeRecorderSetExtraMetadata(NSDictionary *md) {
    @synchronized([EVTrackInfo class]) { evExtra = [md copy]; }
    EVI("Meta", @"extra metadata supplied: %@", md.allKeys);
}

static void EVMergeInto(EVTrackInfo *dst, EVTrackInfo *src) {
    if (!dst.genre) dst.genre = src.genre;
    if (!dst.album) dst.album = src.album;
    if (!dst.albumArtist) dst.albumArtist = src.albumArtist;
    if (!dst.isrc) dst.isrc = src.isrc;
    if (!dst.uri) dst.uri = src.uri;
    if (!dst.trackNumber) dst.trackNumber = src.trackNumber;
    if (!dst.trackCount) dst.trackCount = src.trackCount;
    if (!dst.discNumber) dst.discNumber = src.discNumber;
    if (!dst.year) dst.year = src.year;
    if (dst.duration <= 0) dst.duration = src.duration;
    if (!dst.artworkObject) dst.artworkObject = src.artworkObject;
}

static void EVFetchArtwork(EVTrackInfo *t) {
    if (!t.artworkObject || t.artworkJPEG || [evArtKey isEqualToString:t.key]) return;
    evArtKey = t.key;
    id art = t.artworkObject;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIImage *img = [(MPMediaItemArtwork *)art imageWithSize:CGSizeMake(1200, 1200)];
            NSData *jpg = img ? UIImageJPEGRepresentation(img, 0.92) : nil;
            if (jpg) { t.artworkJPEG = jpg; EVD("Meta", @"artwork %lu KB for '%@'", (unsigned long)jpg.length / 1024, t.title); }
            else EVW("Meta", @"artwork request returned no image for '%@'", t.title);
        } @catch (NSException *e) { EVW("Meta", @"artwork exception: %@", e.reason); }
    });
}

static void evMetaPoll(void) {
    uint64_t f0 = EVCoreFramesCaptured();
    uint64_t prevF = evLastTickFrames;
    evLastTickFrames = f0;
    EVTrackInfo *info = EVReadNowPlaying();
    if (!info) {
        if (++evMissCount == 1 || evMissCount % 400 == 0)
            EVW("Meta", @"MPNowPlayingInfoCenter is empty (x%lu): no track names; recording will be one file", (unsigned long)evMissCount);
        evLastNowPlayingNote = @"now-playing info EMPTY";
        return;
    }
    evMissCount = 0;
    EVApplyExtra(info);
    evLastNowPlayingNote = [NSString stringWithFormat:@"%@ - %@ (elapsed %.1fs of %.1fs)", info.artist, info.title, info.elapsed, info.duration];

    BOOL first = (evLastKey == nil);
    BOOL changed = !first && ![info.key isEqualToString:evLastKey];
    BOOL repeat = !first && !changed && evLastDuration > 20 && evLastElapsed > evLastDuration * 0.8 &&
                  info.elapsed < 1.5 && (evLastElapsed - info.elapsed) > 5;
    evLastElapsed = info.elapsed;
    evLastDuration = info.duration;

    if (first && EVSettingBool(@"waitForTrackStart", NO) && info.elapsed > 1.0) {
        evLastKey = info.key; evCurrent = info; evWaitingForFreshStart = YES;
        EVFetchArtwork(info);
        EVI("Meta", @"recording armed at %.1fs; waiting for the next track beginning", info.elapsed);
        return;
    }

    if (first || changed || repeat) {
        uint32_t rate = EVCoreSampleRate() ?: 44100;
        uint64_t frame = first ? f0 : (prevF + f0) / 2;               // change happened between the two polls
        BOOL partial = first ? (info.elapsed > 1.0) : (info.elapsed > 1.5);
        NSInteger latMs = EVSettingInt(@"metaLatencyMs", 0);
        int64_t shifted = (int64_t)frame - (int64_t)(latMs * (int64_t)rate / 1000);
        frame = shifted < 0 ? 0 : (uint64_t)shifted;
        evLastKey = info.key;
        evCurrent = info;
        if (evWaitingForFreshStart) EVI("Meta", @"new track detected; recording output begins here");
        evWaitingForFreshStart = NO;
        EVFetchArtwork(info);
        if (evMetaBlock) evMetaBlock(info, frame, partial);
    } else if (evCurrent) {
        EVMergeInto(evCurrent, info);
        EVFetchArtwork(evCurrent);
    }
}

void EVMetaStart(EVTrackChangeBlock block) {
    if (!evMetaQ) evMetaQ = dispatch_queue_create("eevee.recorder.meta", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    EVMetaStop();
    dispatch_sync(evMetaQ, ^{
        evMetaBlock = [block copy]; evLastKey = nil; evCurrent = nil; evArtKey = nil; evWaitingForFreshStart = NO;
        evLastElapsed = 0; evLastDuration = 0; evLastTickFrames = 0; evMissCount = 0;
        evMetaTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, evMetaQ);
        dispatch_source_set_timer(evMetaTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(evMetaTimer, ^{ evMetaPoll(); });
        dispatch_resume(evMetaTimer);
    });
    EVI("Meta", @"now-playing watcher started (50 ms poll, latency offset %ld ms)", (long)EVSettingInt(@"metaLatencyMs", 0));
}

void EVMetaStop(void) {
    if (!evMetaQ) return;
    dispatch_sync(evMetaQ, ^{
        if (evMetaTimer) { dispatch_source_cancel(evMetaTimer); evMetaTimer = nil; }
        evMetaBlock = nil;
    });
}

NSArray<NSString *> *EVMetaDebugLines(void) {
    return @[@"== Metadata ==", [NSString stringWithFormat:@"now playing: %@%@", evLastNowPlayingNote, evWaitingForFreshStart ? @" | armed: waiting for a new track" : @""],
             [NSString stringWithFormat:@"latency offset: %ld ms | export formats: %@ | keep session wav: %d",
              (long)EVSettingInt(@"metaLatencyMs", 0), EVSettingString(@"exportFormats", @"(none)"), EVSettingBool(@"keepSession", NO)]];
}

#pragma mark - WAV writing / boundary refinement

static void p16(uint8_t *p, uint16_t v) { p[0] = v & 255; p[1] = v >> 8; }
static void p32(uint8_t *p, uint32_t v) { p[0] = v & 255; p[1] = (v >> 8) & 255; p[2] = (v >> 16) & 255; p[3] = (v >> 24) & 255; }

static NSData *EVInfoChunk(EVTrackInfo *t, NSString *comment) {
    NSMutableData *body = [NSMutableData dataWithBytes:"INFO" length:4];
    void (^add)(const char *, NSString *) = ^(const char *fourcc, NSString *val) {
        if (!val.length) return;
        NSData *s = [val dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t sz = (uint32_t)s.length + 1, le = CFSwapInt32HostToLittle(sz);
        uint8_t z = 0;
        [body appendBytes:fourcc length:4]; [body appendBytes:&le length:4];
        [body appendData:s]; [body appendBytes:&z length:1];
        if (sz & 1) [body appendBytes:&z length:1];
    };
    add("INAM", t.title); add("IART", t.artist); add("IPRD", t.album); add("IGNR", t.genre);
    if (t.trackNumber) add("ITRK", [NSString stringWithFormat:@"%ld", (long)t.trackNumber]);
    add("ICMT", comment);
    NSMutableData *chunk = [NSMutableData dataWithBytes:"LIST" length:4];
    uint32_t le = CFSwapInt32HostToLittle((uint32_t)body.length);
    [chunk appendBytes:&le length:4]; [chunk appendData:body];
    return chunk;
}

static BOOL EVWriteSegment(NSURL *dst, const float *pcm, uint64_t start, uint64_t frames, uint32_t rate,
                           EVTrackInfo *t, NSString *comment, NSString **err) {
    uint64_t bytes = frames * 8;
    if (bytes > 0xFFFFF000ull) { *err = @"segment is larger than 4 GB (WAV limit)"; return NO; }
    NSData *info = EVInfoChunk(t, comment);
    FILE *f = fopen(dst.path.fileSystemRepresentation, "wb");
    if (!f) { *err = [NSString stringWithFormat:@"cannot create %@", dst.lastPathComponent]; return NO; }
    uint8_t h[44] = {0};
    memcpy(h, "RIFF", 4); p32(h + 4, (uint32_t)(36 + bytes + info.length)); memcpy(h + 8, "WAVEfmt ", 8);
    p32(h + 16, 16); p16(h + 20, 3); p16(h + 22, 2); p32(h + 24, rate); p32(h + 28, rate * 8);
    p16(h + 32, 8); p16(h + 34, 32); memcpy(h + 36, "data", 4); p32(h + 40, (uint32_t)bytes);
    BOOL ok = fwrite(h, 1, 44, f) == 44;
    const uint8_t *p = (const uint8_t *)(pcm + start * 2);
    uint64_t left = bytes;
    while (ok && left) {
        size_t n = left > (1u << 20) ? (1u << 20) : (size_t)left;
        ok = fwrite(p, 1, n, f) == n; p += n; left -= n;
    }
    if (ok) ok = fwrite(info.bytes, 1, info.length, f) == info.length;
    if (fclose(f) != 0) ok = NO;
    if (!ok) *err = [NSString stringWithFormat:@"write failed for %@ (disk full?)", dst.lastPathComponent];
    return ok;
}

// Moves a boundary to a clear energy valley (<=300 ms away) when there is one; gapless tracks usually have none.
static uint64_t EVSnapBoundary(const float *pcm, uint64_t total, uint64_t b, uint32_t rate, double *shiftMs, BOOL *snapped) {
    *snapped = NO; *shiftMs = 0;
    uint64_t win = (uint64_t)(0.3 * rate);
    uint64_t lo = b > win ? b - win : 0, hi = b + win < total ? b + win : total;
    uint32_t hop = rate / 500 ? rate / 500 : 1;                      // ~2 ms
    if (hi < lo + (uint64_t)hop * 8) return b;
    uint64_t nh = (hi - lo) / hop;
    double *e = calloc((size_t)nh, sizeof(double));
    if (!e) return b;
    double sum = 0, minE = 1e30;
    for (uint64_t k = 0; k < nh; k++) {
        const float *p = pcm + (lo + k * hop) * 2;
        double acc = 0;
        for (uint32_t i = 0; i < hop * 2; i++) acc += (double)p[i] * p[i];
        e[k] = acc / (hop * 2); sum += e[k]; if (e[k] < minE) minE = e[k];
    }
    double mean = sum / nh;
    uint64_t best = nh;
    if (minE < mean * 0.02 || minE < 1e-10) {
        double th = minE * 2 > 1e-10 ? minE * 2 : 1e-10;
        uint64_t bk = (b - lo) / hop, bestDist = UINT64_MAX;
        for (uint64_t k = 0; k < nh; k++) {
            if (e[k] > th) continue;
            uint64_t dist = k > bk ? k - bk : bk - k;
            if (dist < bestDist) { bestDist = dist; best = k; }
        }
    }
    free(e);
    if (best == nh) return b;
    uint64_t center = lo + best * hop + hop / 2, nb = center;
    float minAbs = 1e9f;
    uint64_t zlo = center > hop ? center - hop : 0, zhi = center + hop < total ? center + hop : total - 1;
    for (uint64_t i = zlo; i <= zhi; i++) {
        float m = fabsf((pcm[i * 2] + pcm[i * 2 + 1]) * 0.5f);
        if (m < minAbs) { minAbs = m; nb = i; }
    }
    *snapped = YES;
    *shiftMs = ((double)nb - (double)b) * 1000.0 / rate;
    return nb;
}

#pragma mark - Export (AAC / ALAC with tags)

static void EVBE16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void EVBE32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static uint32_t EVSyncSafe(uint32_t v) { return ((v & 0x7f000000) >> 3) | ((v & 0x007f0000) >> 2) | ((v & 0x00007f00) >> 1) | (v & 0x7f); }
static void EVAppendID3Text(NSMutableData *tag, const char *frame, NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return;
    NSMutableData *body = [NSMutableData dataWithBytes:"\x03" length:1];
    [body appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
    uint8_t h[10] = {0}; memcpy(h, frame, 4); EVBE32(h + 4, EVSyncSafe((uint32_t)body.length));
    [tag appendBytes:h length:10]; [tag appendData:body];
}
static void EVAppendID3Picture(NSMutableData *tag, NSData *jpeg) {
    if (!jpeg.length) return;
    NSMutableData *body = [NSMutableData dataWithBytes:"\x03image/jpeg\0\x03\0" length:14];
    [body appendData:jpeg];
    uint8_t h[10] = {0}; memcpy(h, "APIC", 4); EVBE32(h + 4, EVSyncSafe((uint32_t)body.length));
    [tag appendBytes:h length:10]; [tag appendData:body];
}
static void EVPutExtended80(uint8_t *p, double value) {
    if (!(value > 0) || !isfinite(value)) { memset(p, 0, 10); return; }
    int exponent = 0; double fraction = frexp(value, &exponent);
    uint16_t e = (uint16_t)(exponent - 1 + 16383);
    uint64_t mantissa = (uint64_t)ldexp(fraction, 64);
    EVBE16(p, e); for (int i = 0; i < 8; i++) p[2 + i] = (uint8_t)(mantissa >> (56 - i * 8));
}

// AIFF PCM is signed, big-endian integer audio. Store 32-bit samples to retain
// the captured float precision, and carry common tags/artwork in an ID3 chunk.
static NSString *EVExportAIFF(NSURL *src, NSURL *dst, uint32_t rate, NSDictionary *tags, NSData *art) {
    NSError *e = nil;
    NSData *wav = [NSData dataWithContentsOfURL:src options:NSDataReadingMappedAlways error:&e];
    if (wav.length < 44 || memcmp((const uint8_t *)wav.bytes, "RIFF", 4) || memcmp((const uint8_t *)wav.bytes + 36, "data", 4))
        return e.localizedDescription ?: @"invalid source WAV";
    uint64_t frames64 = (wav.length - 44) / 8;
    if (!frames64 || frames64 > UINT32_MAX || frames64 * 8 > UINT32_MAX - 64) return @"AIFF file exceeds the 32-bit size limit";
    if (!rate) { const uint8_t *b = wav.bytes; rate = b[24] | ((uint32_t)b[25] << 8) | ((uint32_t)b[26] << 16) | ((uint32_t)b[27] << 24); }
    NSMutableData *id3 = [NSMutableData data];
    EVAppendID3Text(id3, "TIT2", tags[@"title"]); EVAppendID3Text(id3, "TPE1", tags[@"artist"]);
    EVAppendID3Text(id3, "TALB", tags[@"album"]); EVAppendID3Text(id3, "TPE2", tags[@"albumArtist"]);
    EVAppendID3Text(id3, "TCON", tags[@"genre"]); EVAppendID3Text(id3, "TDRC", [tags[@"year"] description]);
    NSInteger track = [tags[@"trackNumber"] integerValue], trackCount = [tags[@"trackCount"] integerValue];
    if (track > 0) EVAppendID3Text(id3, "TRCK", trackCount > 0 ? [NSString stringWithFormat:@"%ld/%ld", (long)track, (long)trackCount] : [NSString stringWithFormat:@"%ld", (long)track]);
    NSInteger disc = [tags[@"discNumber"] integerValue]; if (disc > 0) EVAppendID3Text(id3, "TPOS", [NSString stringWithFormat:@"%ld", (long)disc]);
    EVAppendID3Picture(id3, art);
    NSMutableData *tag = [NSMutableData data];
    if (id3.length) { uint8_t h[10] = {'I','D','3',4,0,0,0,0,0,0}; EVBE32(h + 6, EVSyncSafe((uint32_t)id3.length)); [tag appendBytes:h length:10]; [tag appendData:id3]; }
    uint64_t pcmBytes = frames64 * 8, ssndSize = 8 + pcmBytes;
    uint64_t formSize = 4 + 8 + 18 + 8 + ssndSize + (ssndSize & 1) + (tag.length ? 8 + tag.length + (tag.length & 1) : 0);
    if (formSize > UINT32_MAX) return @"AIFF file exceeds the 4 GB limit";
    NSMutableData *headerData = [NSMutableData dataWithLength:54];
    uint8_t header[54] = {0}; memcpy(header, "FORM", 4); EVBE32(header + 4, (uint32_t)formSize); memcpy(header + 8, "AIFFCOMM", 8);
    EVBE32(header + 16, 18); EVBE16(header + 20, 2); EVBE32(header + 22, (uint32_t)frames64); EVBE16(header + 26, 32); EVPutExtended80(header + 28, rate);
    memcpy(header + 38, "SSND", 4); EVBE32(header + 42, (uint32_t)ssndSize);
    memcpy(headerData.mutableBytes, header, sizeof(header));
    NSURL *tmp = [dst URLByAppendingPathExtension:@"partial"];
    [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
    FILE *file = fopen(tmp.path.fileSystemRepresentation, "wb");
    if (!file) return [NSString stringWithFormat:@"cannot create AIFF (errno %d)", errno];
    BOOL ok = fwrite(headerData.bytes, 1, headerData.length, file) == headerData.length;
    uint8_t zero[8] = {0}; if (ok) ok = fwrite(zero, 1, 8, file) == 8;
    const float *samples = (const float *)((const uint8_t *)wav.bytes + 44);
    NSMutableData *block = [NSMutableData dataWithLength:32768]; uint8_t *dstBytes = block.mutableBytes;
    NSDate *lastProgress = [NSDate date];
    EVI("Export", @"AIFF started: %@ (%.1f seconds)", dst.lastPathComponent, (double)frames64 / rate);
    for (uint64_t i = 0; ok && i < frames64 * 2; ) {
        NSUInteger n = (NSUInteger)MIN((uint64_t)(block.length / 4), frames64 * 2 - i);
        for (NSUInteger j = 0; j < n; j++) {
            double x = isfinite(samples[i + j]) ? samples[i + j] : 0.0; if (x > 1.0) x = 1.0; if (x < -1.0) x = -1.0;
            int32_t v = (int32_t)llround(x < 0 ? x * 2147483648.0 : x * 2147483647.0); EVBE32(dstBytes + j * 4, (uint32_t)v);
        }
        ok = fwrite(dstBytes, 4, n, file) == n; i += n;
        if ([[NSDate date] timeIntervalSinceDate:lastProgress] >= 5.0) {
            double pct = (double)i / (double)(frames64 * 2) * 100.0;
            EVI("Export", @"AIFF %@: %.0f%%", dst.lastPathComponent, pct);
            lastProgress = [NSDate date];
        }
    }
    if (ok && (ssndSize & 1)) ok = fwrite(zero, 1, 1, file) == 1;
    if (ok && tag.length) { uint8_t th[8] = {'I','D','3',' ',0,0,0,0}; EVBE32(th + 4, (uint32_t)tag.length); ok = fwrite(th, 1, 8, file) == 8 && fwrite(tag.bytes, 1, tag.length, file) == tag.length; if (ok && (tag.length & 1)) ok = fwrite(zero, 1, 1, file) == 1; }
    if (fclose(file) != 0) ok = NO;
    if (!ok) { [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil]; return @"failed while writing AIFF data"; }
    [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
    if (![[NSFileManager defaultManager] moveItemAtURL:tmp toURL:dst error:&e]) return e.localizedDescription ?: @"cannot finish AIFF";
    EVI("Export", @"AIFF finished: %@", dst.lastPathComponent);
    return nil;
}

static NSArray<AVMetadataItem *> *EVMetaItems(NSDictionary *t, NSData *art) {
    NSMutableArray *a = [NSMutableArray array];
    void (^str)(NSString *, NSString *) = ^(NSString *ident, NSString *val) {
        if (![val isKindOfClass:NSString.class] || !val.length) return;
        AVMutableMetadataItem *i = [AVMutableMetadataItem new];
        i.identifier = ident; i.value = val; i.dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF8;
        i.extendedLanguageTag = @"und"; [a addObject:i];
    };
    str(AVMetadataCommonIdentifierTitle, t[@"title"]);
    str(AVMetadataCommonIdentifierArtist, t[@"artist"]);
    str(AVMetadataCommonIdentifierAlbumName, t[@"album"]);
    str(AVMetadataIdentifieriTunesMetadataAlbumArtist, t[@"albumArtist"]);
    str(AVMetadataIdentifieriTunesMetadataUserGenre, t[@"genre"]);
    NSInteger trk = [t[@"trackNumber"] integerValue], tot = [t[@"trackCount"] integerValue];
    if (trk > 0) {
        uint8_t b[8] = {0, 0, (uint8_t)(trk >> 8), (uint8_t)trk, (uint8_t)(tot >> 8), (uint8_t)tot, 0, 0};
        AVMutableMetadataItem *i = [AVMutableMetadataItem new];
        i.identifier = AVMetadataIdentifieriTunesMetadataTrackNumber;
        i.value = [NSData dataWithBytes:b length:8];
        i.dataType = (__bridge NSString *)kCMMetadataBaseDataType_RawData;
        [a addObject:i];
    }
    if (art.length) {
        AVMutableMetadataItem *i = [AVMutableMetadataItem new];
        i.identifier = AVMetadataCommonIdentifierArtwork; i.value = art;
        i.dataType = (__bridge NSString *)kCMMetadataBaseDataType_JPEG; [a addObject:i];
    }
    return a;
}

static NSString *EVExportM4A(NSURL *src, NSURL *dst, BOOL lossless, uint32_t rate, NSArray<AVMetadataItem *> *meta) {
    [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:src options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return @"no audio track in WAV";
    NSError *e = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&e];
    if (!reader) return e.localizedDescription ?: @"reader failed";
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO}];
    [reader addOutput:out];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:dst fileType:AVFileTypeAppleM4A error:&e];
    if (!writer) return e.localizedDescription ?: @"writer failed";
    NSDictionary *ws = lossless
        ? @{AVFormatIDKey: @(kAudioFormatAppleLossless), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @2, AVEncoderBitDepthHintKey: @24}
        : @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @2, AVEncoderBitRateKey: @256000};
    AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:ws];
    if (![writer canAddInput:in]) return @"writer rejected the audio settings";
    [writer addInput:in];
    writer.metadata = meta;
    if (![reader startReading]) return reader.error.localizedDescription ?: @"cannot read WAV";
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create("eevee.recorder.export", DISPATCH_QUEUE_SERIAL);
    [in requestMediaDataWhenReadyOnQueue:q usingBlock:^{
        while (in.isReadyForMoreMediaData) {
            CMSampleBufferRef sb = [out copyNextSampleBuffer];
            if (sb) { [in appendSampleBuffer:sb]; CFRelease(sb); }
            else {
                [in markAsFinished];
                [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
                break;
            }
        }
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return writer.status == AVAssetWriterStatusCompleted ? nil : (writer.error.localizedDescription ?: @"export failed");
}

#pragma mark - Finalize (split + tag + export)

static dispatch_queue_t evFinQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t o;
    dispatch_once(&o, ^{ q = dispatch_queue_create("eevee.recorder.finalize", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static NSString *EVSanitize(NSString *s) {
    NSMutableString *m = [NSMutableString string];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        [m appendString:([bad characterIsMember:c] || c < 32) ? @"_" : [NSString stringWithCharacters:&c length:1]];
    }
    NSString *t = [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length > 80 ? [t substringToIndex:80] : t;
}

static NSDecimalNumber *EVSec(uint64_t frames, uint32_t rate) {
    return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.3f", (double)frames / rate]];
}

static void EVExportOne(NSURL *wav, NSDictionary *tags, NSData *art, uint32_t rate, NSString *fmt,
                        NSMutableArray<NSURL *> *outFiles, NSMutableArray<NSString *> *errs) {
    if ([fmt isEqualToString:@"aiff"]) {
        NSURL *aiff = [[wav URLByDeletingPathExtension] URLByAppendingPathExtension:@"aiff"];
        NSString *aiffError = EVExportAIFF(wav, aiff, rate, tags, art);
        if (aiffError) { [errs addObject:[NSString stringWithFormat:@"%@: %@", aiff.lastPathComponent, aiffError]]; EVE("Export", @"%@ failed: %@", aiff.lastPathComponent, aiffError); }
        else { [outFiles addObject:aiff]; EVI("Export", @"wrote %@", aiff.lastPathComponent); }
        return;
    }
    BOOL lossless = [fmt isEqualToString:@"alac"];
    NSURL *dst = [[wav URLByDeletingPathExtension] URLByAppendingPathExtension:@"m4a"];
    if (lossless) dst = [[[wav URLByDeletingPathExtension] URLByAppendingPathExtension:@"lossless"] URLByAppendingPathExtension:@"m4a"];
    EVI("Export", @"%@ started: %@", lossless ? @"ALAC" : @"AAC", dst.lastPathComponent);
    NSString *err = EVExportM4A(wav, dst, lossless, rate, EVMetaItems(tags, art));
    if (err) { [errs addObject:[NSString stringWithFormat:@"%@: %@", dst.lastPathComponent, err]]; EVE("Export", @"%@ failed: %@", dst.lastPathComponent, err); }
    else { [outFiles addObject:dst]; EVI("Export", @"%@ finished: %@", lossless ? @"ALAC" : @"AAC", dst.lastPathComponent); }
}

static NSArray<NSString *> *EVExportFormats(void) {
    NSString *s = EVSettingString(@"exportFormats", @"");
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *p in [s componentsSeparatedByString:@","]) if (p.length) [a addObject:p];
    return a;
}

static void evRunFinalize(NSURL *wav, uint32_t rate, NSArray<EVMarker *> *markersIn, uint64_t totalFrames,
                          NSMutableArray<NSURL *> *outFiles, NSMutableArray<NSDictionary *> *outTracks, NSMutableArray<NSString *> *errs) {
    NSURL *folder = [wav URLByDeletingLastPathComponent];
    NSError *e = nil;
    NSData *data = [NSData dataWithContentsOfURL:wav options:NSDataReadingMappedAlways error:&e];
    if (!data || data.length < 44) { [errs addObject:@"session.wav is missing or empty"]; return; }
    const uint8_t *b = data.bytes;
    if (memcmp(b, "RIFF", 4) || memcmp(b + 36, "data", 4)) { [errs addObject:@"session.wav has an unexpected header"]; return; }
    if (!rate) rate = b[24] | (b[25] << 8) | (b[26] << 16) | ((uint32_t)b[27] << 24);
    if (!rate) rate = 44100;
    uint64_t avail = (data.length - 44) / 8;
    if (!totalFrames || totalFrames > avail) totalFrames = avail;
    if (totalFrames < rate / 2) { [errs addObject:@"nothing was recorded (less than half a second of audio)"]; return; }
    const float *pcm = (const float *)(b + 44);

    NSMutableArray<EVMarker *> *ms = [[markersIn sortedArrayUsingComparator:^NSComparisonResult(EVMarker *x, EVMarker *y) {
        return x.frame < y.frame ? NSOrderedAscending : (x.frame > y.frame ? NSOrderedDescending : NSOrderedSame);
    }] mutableCopy];
    for (NSInteger i = (NSInteger)ms.count - 1; i > 0; i--)               // same frame twice: keep the later one
        if (ms[i].frame == ms[i - 1].frame) [ms removeObjectAtIndex:i - 1];
    if (!ms.count && EVSettingBool(@"waitForTrackStart", NO)) {
        [errs addObject:@"No new track began after recording was armed."];
        return;
    }
    if (ms.count && ms[0].frame > 0 && EVSettingBool(@"waitForTrackStart", NO)) {
        EVI("Split", @"discarding %.3f seconds captured before the armed track began", (double)ms[0].frame / rate);
    } else if (!ms.count || ms[0].frame > 0) {
        EVMarker *m0 = [EVMarker new]; m0.frame = 0; m0.partialStart = YES; [ms insertObject:m0 atIndex:0];
    }

    NSMutableArray<NSMutableDictionary *> *segs = [NSMutableArray array];
    for (NSUInteger i = 0; i < ms.count; i++) {
        uint64_t s = ms[i].frame < totalFrames ? ms[i].frame : totalFrames;
        uint64_t en = (i + 1 < ms.count) ? (ms[i + 1].frame < totalFrames ? ms[i + 1].frame : totalFrames) : totalFrames;
        [segs addObject:[@{@"start": @(s), @"end": @(en), @"info": ms[i].info ?: [NSNull null],
                           @"partialStart": @(ms[i].partialStart || (i == 0 && ms[i].info == nil)), @"partialEnd": @(i + 1 == ms.count),
                           @"method": @"metadata", @"shiftMs": @0.0} mutableCopy]];
    }
    // refine each internal boundary
    for (NSUInteger i = 1; i < segs.count; i++) {
        uint64_t bnd = [segs[i][@"start"] unsignedLongLongValue];
        double shift; BOOL snapped;
        uint64_t nb = EVSnapBoundary(pcm, totalFrames, bnd, rate, &shift, &snapped);
        if (snapped) {
            segs[i][@"start"] = @(nb); segs[i - 1][@"end"] = @(nb);
            segs[i][@"method"] = @"energy-valley"; segs[i][@"shiftMs"] = @(shift);
            EVI("Split", @"boundary %lu snapped %+.1f ms to an energy valley", (unsigned long)i, shift);
        } else EVI("Split", @"boundary %lu kept at metadata position (no clear silence nearby)", (unsigned long)i);
    }

    NSArray<NSString *> *formats = EVExportFormats();
    NSMutableArray *sessionTracks = [NSMutableArray array];
    NSUInteger number = 0;
    for (NSMutableDictionary *sg in segs) {
        uint64_t s = [sg[@"start"] unsignedLongLongValue], en = [sg[@"end"] unsignedLongLongValue];
        if (en <= s || en - s < rate) { if (segs.count > 1) { EVW("Split", @"skipping segment shorter than 1 s (%.3f s)", (double)(en - s) / rate); continue; } }
        EVTrackInfo *info = [sg[@"info"] isKindOfClass:EVTrackInfo.class] ? sg[@"info"] : nil;
        number++;
        NSString *base = info.title.length
            ? [NSString stringWithFormat:@"%02lu %@%@", (unsigned long)number, info.artist.length ? [info.artist stringByAppendingString:@" - "] : @"", info.title]
            : [NSString stringWithFormat:@"%02lu Recording", (unsigned long)number];
        base = EVSanitize(base);
        NSURL *wavOut = [folder URLByAppendingPathComponent:[base stringByAppendingString:@".wav"]];
        double expected = info.duration, got = (double)(en - s) / rate;
        NSString *comment = [NSString stringWithFormat:@"Recorded with EeveeSpotify: %@ s, start %@, boundary %@",
                             [EVSec(en - s, rate) stringValue], EVFormatTime((double)s / rate), sg[@"method"]];
        NSString *werr = nil;
        if (!EVWriteSegment(wavOut, pcm, s, en - s, rate, info, comment, &werr)) { [errs addObject:werr]; continue; }
        [outFiles addObject:wavOut];

        NSMutableDictionary *side = [NSMutableDictionary dictionaryWithDictionary:info ? [info dictionary] : @{}];
        side[@"file"] = wavOut.lastPathComponent;
        side[@"sampleRate"] = @(rate); side[@"channels"] = @2; side[@"format"] = @"float32 WAV";
        side[@"startFrame"] = @(s); side[@"endFrame"] = @(en);
        side[@"startSeconds"] = EVSec(s, rate); side[@"endSeconds"] = EVSec(en, rate);
        side[@"durationSeconds"] = EVSec(en - s, rate);
        side[@"durationMs"] = @((long long)llround(got * 1000.0));
        if (expected > 0) side[@"deltaVsExpectedMs"] = @((long long)llround((got - expected) * 1000.0));
        side[@"partialStart"] = sg[@"partialStart"]; side[@"partialEnd"] = sg[@"partialEnd"];
        side[@"boundaryMethod"] = sg[@"method"]; side[@"boundaryShiftMs"] = @(round([sg[@"shiftMs"] doubleValue] * 10) / 10);
        NSURL *js = [[wavOut URLByDeletingPathExtension] URLByAppendingPathExtension:@"json"];
        [[NSJSONSerialization dataWithJSONObject:side options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil] writeToURL:js atomically:YES];
        [outFiles addObject:js];
        if (info.artworkJPEG.length) {
            NSURL *jpg = [[wavOut URLByDeletingPathExtension] URLByAppendingPathExtension:@"jpg"];
            [info.artworkJPEG writeToURL:jpg atomically:YES]; [outFiles addObject:jpg];
        }
        for (NSString *fmt in formats) EVExportOne(wavOut, side, info.artworkJPEG, rate, fmt, outFiles, errs);
        [outTracks addObject:@{@"title": info.title ?: @"Recording", @"artist": info.artist ?: @"", @"file": wavOut.lastPathComponent,
                               @"durationMs": side[@"durationMs"], @"path": wavOut.path, @"partial": @([sg[@"partialStart"] boolValue] || [sg[@"partialEnd"] boolValue])}];
        [sessionTracks addObject:side];
        EVI("Split", @"wrote '%@' %@ (expected %@)%@", wavOut.lastPathComponent, EVFormatTime(got),
            expected > 0 ? EVFormatTime(expected) : @"?", expected > 0 ? [NSString stringWithFormat:@", delta %+lld ms", (long long)llround((got - expected) * 1000.0)] : @"");
    }

    NSDictionary *summary = @{@"sampleRate": @(rate), @"totalFrames": @(totalFrames), @"totalSeconds": EVSec(totalFrames, rate),
                              @"tracks": sessionTracks, @"errors": errs};
    [[NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[folder URLByAppendingPathComponent:@"session.json"] atomically:YES];
    if (outTracks.count && !errs.count && !EVSettingBool(@"keepSession", NO)) {
        [[NSFileManager defaultManager] removeItemAtURL:wav error:nil];
        EVI("Split", @"removed session.wav (enable 'Keep full session WAV' to keep it)");
    }
    if (outTracks.count) [@"done\n" writeToURL:[folder URLByAppendingPathComponent:@".done"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void EVFinalizeSession(NSURL *wav, uint32_t rate, NSArray<EVMarker *> *markersIn, uint64_t total, EVFinalizeDone done) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier bg = UIBackgroundTaskInvalid;
    bg = [app beginBackgroundTaskWithName:@"EeveeRecorderFinalize" expirationHandler:^{
        EVW("Split", @"background time expired while splitting; it resumes at next launch");
        if (bg != UIBackgroundTaskInvalid) { [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
    }];
    dispatch_async(evFinQueue(), ^{
        @autoreleasepool {
            NSMutableArray<NSURL *> *files = [NSMutableArray array];
            NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
            NSMutableArray<NSString *> *errs = [NSMutableArray array];
            uint64_t t0 = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000);
            evRunFinalize(wav, rate, markersIn, total, files, tracks, errs);
            EVI("Split", @"finalize finished in %llu ms: %lu file(s), %lu track(s), %lu error(s)",
                (unsigned long long)((uint64_t)([[NSDate date] timeIntervalSince1970] * 1000) - t0),
                (unsigned long)files.count, (unsigned long)tracks.count, (unsigned long)errs.count);
            if (done) done(files, [wav URLByDeletingLastPathComponent], tracks, errs.count ? [errs componentsJoinedByString:@"; "] : nil);
        }
        if (bg != UIBackgroundTaskInvalid) { [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
    });
}

void EVExportFolder(NSURL *folder, NSString *format, EVFinalizeDone done) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier bg = [app beginBackgroundTaskWithName:@"EeveeRecorderExport" expirationHandler:^{}];
    dispatch_async(evFinQueue(), ^{
        NSMutableArray<NSURL *> *files = [NSMutableArray array];
        NSMutableArray<NSString *> *errs = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
        for (NSURL *u in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![u.pathExtension isEqualToString:@"wav"] || [u.lastPathComponent isEqualToString:@"session.wav"]) continue;
            NSURL *js = [[u URLByDeletingPathExtension] URLByAppendingPathExtension:@"json"];
            NSURL *jpg = [[u URLByDeletingPathExtension] URLByAppendingPathExtension:@"jpg"];
            NSDictionary *tags = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:js] ?: [NSData data] options:0 error:nil];
            uint32_t rate = [tags[@"sampleRate"] unsignedIntValue] ?: 44100;
            EVExportOne(u, tags ?: @{}, [NSData dataWithContentsOfURL:jpg], rate, format, files, errs);
            [tracks addObject:@{@"title": tags[@"title"] ?: u.lastPathComponent, @"artist": tags[@"artist"] ?: @"", @"file": u.lastPathComponent}];
        }
        if (done) done(files, folder, tracks, errs.count ? [errs componentsJoinedByString:@"; "] : (files.count ? nil : @"no WAV files found in that folder"));
        if (bg != UIBackgroundTaskInvalid) { [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
    });
}

#pragma mark - Resume sessions that were interrupted (crash, kill, background expiry)

void EVResumePendingSessions(void) {
    dispatch_async(evFinQueue(), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *active = EVCoreActiveSessionPath();
        for (NSURL *dir in [fm contentsOfDirectoryAtURL:EVRecordingsRoot() includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
            NSURL *wav = [dir URLByAppendingPathComponent:@"session.wav"];
            NSURL *mj = [dir URLByAppendingPathComponent:@"markers.json"];
            if (![fm fileExistsAtPath:wav.path] || ![fm fileExistsAtPath:mj.path]) continue;
            if ([fm fileExistsAtPath:[dir URLByAppendingPathComponent:@".done"].path]) continue;
            if (active && [active hasPrefix:dir.path]) continue;
            NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:mj] ?: [NSData data] options:0 error:nil];
            if (![root isKindOfClass:NSDictionary.class]) continue;
            NSMutableArray *ms = [NSMutableArray array];
            for (NSDictionary *m in root[@"markers"]) {
                EVMarker *mk = [EVMarker new];
                mk.frame = [m[@"frame"] unsignedLongLongValue]; mk.partialStart = [m[@"partialStart"] boolValue];
                mk.info = [EVTrackInfo fromDictionary:m[@"info"] ?: @{}];
                [ms addObject:mk];
            }
            EVI("Resume", @"finishing interrupted session %@ (%lu marker(s))", dir.lastPathComponent, (unsigned long)ms.count);
            NSMutableArray<NSURL *> *files = [NSMutableArray array];
            NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
            NSMutableArray<NSString *> *errs = [NSMutableArray array];
            evRunFinalize(wav, [root[@"rate"] unsignedIntValue], ms, 0, files, tracks, errs);
            EVI("Resume", @"%@: %lu track(s), errors: %@", dir.lastPathComponent, (unsigned long)tracks.count, errs.count ? errs : @"none");
        }
    });
}
