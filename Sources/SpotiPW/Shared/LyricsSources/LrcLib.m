// LRCLIB, the floor of the order. It is an open library with no key and no catalogue to license, so
// it holds what the rest cannot: the tracks Apple's word by word programme never reached, and the
// ones Musixmatch may show nobody. It times lines and not words, which is the whole point of putting
// it last — the estimate inside a line is still a sweep, where Spotify's own lyrics only scroll.
//
// Its /api/get wants the length to agree almost exactly and answers 404 otherwise, so a miss falls
// back to /api/search, which answers with whole recordings to pick the closest of. LRCLIB asks that
// clients say who they are, and the mod does.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kGet = @"https://lrclib.net/api/get";
static NSString *const kSearch = @"https://lrclib.net/api/search";
// Line timing is only worth taking from a recording of about the same length as the one playing.
static const NSInteger kLengthSlack = 4;

static NSDictionary<NSString *, NSString *> *headers(void) {
    return @{@"User-Agent": @"spoti.pw " @SG_VERSION @" (https://github.com/skopevoj/spoti.pw)"};
}

// [00:34.30] Look — the timestamp in minutes, seconds and hundredths, or thousandths where a line
// carries three digits. A line may be stamped more than once when it is sung more than once, and
// the tags LRC opens with ([ar:…], [length:…]) are not timestamps, so they fall out on their own.
static NSArray<SGKaraokeLine *> *linesFromLRC(NSString *lrc) {
    static NSRegularExpression *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]" options:0 error:nil];
    });
    NSMutableArray<NSDictionary *> *stamped = [NSMutableArray array];
    for (NSString *row in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSTextCheckingResult *> *found = [stamp matchesInString:row options:0 range:NSMakeRange(0, row.length)];
        // Only the stamps a line opens with are its own; one further in is part of the words.
        NSUInteger end = 0;
        NSMutableArray<NSNumber *> *at = [NSMutableArray array];
        for (NSTextCheckingResult *match in found) {
            if (match.range.location != end) break;
            end = NSMaxRange(match.range);
            NSInteger minutes = [row substringWithRange:[match rangeAtIndex:1]].integerValue;
            NSInteger seconds = [row substringWithRange:[match rangeAtIndex:2]].integerValue;
            NSInteger fraction = 0;
            NSRange part = [match rangeAtIndex:3];
            if (part.location != NSNotFound) {
                NSString *digits = [row substringWithRange:part];
                fraction = digits.integerValue * (digits.length == 1 ? 100 : digits.length == 2 ? 10 : 1);
            }
            [at addObject:@((minutes * 60 + seconds) * 1000 + fraction)];
        }
        if (!at.count) continue;
        NSString *text = [[row substringFromIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSNumber *ms in at) [stamped addObject:@{@"ms": ms, @"text": text}];
    }
    if (!stamped.count) return nil;
    [stamped sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"ms"] compare:b[@"ms"]];
    }];
    // The empty rows stay in: they are the breaks, and each one is the end of the line before it.
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *row in stamped) {
        [starts addObject:row[@"ms"]];
        [texts addObject:row[@"text"]];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

static SGLyricsResult *resultFrom(NSDictionary *record) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    result.instrumental = [record[@"instrumental"] boolValue];
    if (result.instrumental) return result;
    id synced = record[@"syncedLyrics"], plain = record[@"plainLyrics"];
    NSArray<SGKaraokeLine *> *lines = [synced isKindOfClass:NSString.class] ? linesFromLRC(synced) : nil;
    if (lines) {
        result.synced = YES;
        result.karaokeLines = lines;
        NSArray<NSNumber *> *starts;
        NSArray<NSString *> *texts;
        SGLyricsPageLines(lines, &starts, &texts);
        result.starts = starts;
        result.texts = texts;
        return result;
    }
    // Nothing timed, but the words still beat an empty page when no other source has any.
    if (![plain isKindOfClass:NSString.class] || ![plain length]) return nil;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSString *row in [plain componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        [starts addObject:@0];
        [texts addObject:row.length ? row : @"♪"];
    }
    result.starts = starts;
    result.texts = texts;
    result.karaokeLines = SGKaraokeStaticLines(texts);
    return result;
}

// How good a recording is for the track: timed beats untimed, then the closest length. With no
// length to go on, the fullest sheet wins — the search will happily rank a seventeen second stub of
// a song above the song, and a stub is the one thing a length would have caught.
static BOOL betterRecord(NSDictionary *record, NSDictionary *best, NSInteger seconds) {
    if (!best) return YES;
    BOOL synced = [record[@"syncedLyrics"] isKindOfClass:NSString.class] && [record[@"syncedLyrics"] length];
    BOOL wasSynced = [best[@"syncedLyrics"] isKindOfClass:NSString.class] && [best[@"syncedLyrics"] length];
    if (synced != wasSynced) return synced;
    if (seconds > 0) {
        NSInteger off = labs((NSInteger)[record[@"duration"] doubleValue] - seconds);
        NSInteger wasOff = labs((NSInteger)[best[@"duration"] doubleValue] - seconds);
        return off < wasOff;
    }
    NSString *text = record[@"syncedLyrics"] ?: record[@"plainLyrics"] ?: @"";
    NSString *wasText = best[@"syncedLyrics"] ?: best[@"plainLyrics"] ?: @"";
    return [text isKindOfClass:NSString.class] && [text length] > [wasText length];
}

static NSDictionary *bestOf(id found, NSInteger seconds) {
    NSDictionary *best = nil;
    for (NSDictionary *record in [found isKindOfClass:NSArray.class] ? found : @[]) {
        if (![record isKindOfClass:NSDictionary.class]) continue;
        NSInteger length = (NSInteger)[record[@"duration"] doubleValue];
        if (seconds > 0 && length > 0 && labs(length - seconds) > kLengthSlack) continue;
        if (betterRecord(record, best, seconds)) best = record;
    }
    return best;
}

SGLyricsAsk SGLrcLibAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        SGLog(@"lrclib: nothing to search with for %@", query.trackID);
        done(nil);
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *search = [NSMutableDictionary dictionaryWithDictionary:@{
        @"track_name": query.title,
        @"artist_name": query.artist,
    }];
    if (query.album.length) search[@"album_name"] = query.album;

    void (^bySearch)(void) = ^{
        SGLyricsGetJSON(SGLyricsURL(kSearch, search), headers(), ^(id found) {
            NSDictionary *record = bestOf(found, query.seconds);
            SGLyricsResult *result = resultFrom(record);
            SGLog(@"lrclib: search for %@ by %@ gave %@", query.title, query.artist,
                  !result ? @"nothing" : result.instrumental ? @"an instrumental"
                  : result.synced ? [NSString stringWithFormat:@"%lu timed lines", (unsigned long)result.karaokeLines.count]
                  : [NSString stringWithFormat:@"%lu untimed lines", (unsigned long)result.texts.count]);
            done(result);
        });
    };

    // With no length to match on, the exact lookup would be a guess; the search ranks by itself.
    if (query.seconds <= 0) {
        bySearch();
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *exact = [search mutableCopy];
    exact[@"duration"] = @(query.seconds).stringValue;
    SGLyricsGetJSON(SGLyricsURL(kGet, exact), headers(), ^(id record) {
        SGLyricsResult *result = resultFrom(record);
        if (!result) {
            bySearch();
            return;
        }
        SGLog(@"lrclib: %@ by %@ matched exactly, %@", query.title, query.artist,
              result.instrumental ? @"instrumental" : result.synced ? @"timed" : @"untimed");
        done(result);
    });
};
