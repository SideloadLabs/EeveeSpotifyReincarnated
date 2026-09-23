// BiniLyrics, the widest of the sources that serve Apple Music's own TTML: over a million recordings,
// word timed, and no key to ask for. Searched by title, artist and length, so it needs a source
// before it in the order — or the player — to have named the track. The search answers with metadata
// and a link; the TTML itself is a second request, to a plain file host.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kAPI = @"https://lyrics-api.binimum.org/";
// A recording is only taken when its length is this close to the track's, so the words fall on the
// same beat. The search is by name, and a live or sped up cut of the same song is a different take.
static const NSInteger kLengthSlack = 4;

// The best of what the search found: word timing wins over line timing, then the closest length.
static NSDictionary *bestOf(id results, NSInteger seconds) {
    NSDictionary *best = nil;
    BOOL bestWordTimed = NO;
    NSInteger bestOff = NSIntegerMax;
    for (NSDictionary *found in [results isKindOfClass:NSArray.class] ? results : @[]) {
        if (![found isKindOfClass:NSDictionary.class] || ![found[@"lyricsUrl"] isKindOfClass:NSString.class]) continue;
        NSInteger length = [found[@"duration"] integerValue];
        NSInteger off = seconds > 0 && length > 0 ? labs(length - seconds) : 0;
        if (off > kLengthSlack) continue;
        BOOL wordTimed = [found[@"timing_type"] isEqual:@"word"];
        if (best && !(wordTimed && !bestWordTimed) && (bestWordTimed != wordTimed || off >= bestOff)) continue;
        best = found;
        bestWordTimed = wordTimed;
        bestOff = off;
    }
    return best;
}

SGLyricsAsk SGBiniLyricsAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        SGLog(@"binilyrics: nothing to search with for %@", query.trackID);
        done(nil);
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *search = [NSMutableDictionary dictionaryWithDictionary:@{
        @"track": query.title,
        @"artist": query.artist,
    }];
    if (query.seconds > 0) search[@"duration"] = @(query.seconds).stringValue;
    if (query.album.length) search[@"album"] = query.album;
    SGLyricsGetJSON(SGLyricsURL(kAPI, search), nil, ^(id root) {
        NSDictionary *found = bestOf([root isKindOfClass:NSDictionary.class] ? root[@"results"] : nil, query.seconds);
        if (!found) {
            SGLog(@"binilyrics: nothing within %lds of %@ by %@", (long)kLengthSlack, query.title, query.artist);
            done(nil);
            return;
        }
        SGLyricsGetText([NSURL URLWithString:found[@"lyricsUrl"]], ^(NSString *ttml) {
            NSArray<SGKaraokeLine *> *lines = SGTTMLLines(ttml);
            if (!lines) {
                SGLog(@"binilyrics: %@ gave nothing the page could show", found[@"lyricsUrl"]);
                done(nil);
                return;
            }
            SGLyricsResult *result = [SGLyricsResult new];
            result.synced = YES;
            result.wordTimed = [found[@"timing_type"] isEqual:@"word"];
            result.karaokeLines = lines;
            NSArray<NSNumber *> *starts;
            NSArray<NSString *> *texts;
            SGLyricsPageLines(lines, &starts, &texts);
            result.starts = starts;
            result.texts = texts;
            SGLog(@"binilyrics: %@ by %@ has %lu %@ lines", query.title, query.artist,
                  (unsigned long)lines.count, result.wordTimed ? @"word timed" : @"line timed");
            done(result);
        });
    });
};
