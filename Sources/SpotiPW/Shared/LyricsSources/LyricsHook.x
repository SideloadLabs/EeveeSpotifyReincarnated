// Puts the sources' lines on Spotify's lyrics page. Spotify's own color-lyrics 200 gets them swapped in;
// a track Spotify has none for is asked for as the donor track and its 200 carries them instead; the card
// list gets a lyrics section, without which the player never asks for lyrics at all.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import "Shared/Lyrics/Protobuf.h"
#import "Headers/SPTPlayer.h"
#import <os/lock.h>

// Its lyrics are offered wherever Spotify offers lyrics at all.
static NSString *const kDonorTrack = @"0VjIjW4GlUZAMYd2vXMi3b";
static NSString *const kLyricsPath = @"/color-lyrics/v2/track/";
static NSString *const kCardListPath = @"/scrollsita/";
static NSString *const kTrackPrefix = @"spotify:track:";
// On a request sent to the donor, the track it really asks for.
static NSString *const kDonorForKey = @"spotifyglass.lyricsDonorFor";
static NSString *const kUnnamedProvider = @"spoti.pw";

typedef void (^SGDisposition)(NSURLSessionResponseDisposition disposition);
typedef void (^SGForwardResponse)(NSURLResponse *response, SGDisposition handler);
typedef void (^SGForwardEnd)(NSError *error);

typedef NS_ENUM(NSInteger, SGLyricsTaskKind) {
    SGLyricsTaskCardList,   // scrollsita, answered 200
    SGLyricsTaskSpotify,    // Spotify's own 200
    SGLyricsTaskDonor,      // the donor's 200, for a track Spotify has none for
    SGLyricsTaskMissing,    // anything but a 200
};

// What a task is and where it stands. The first five are set before the state is attached to its task
// and never change; the rest are read and written under @synchronized on the state, from URLSession's
// delegate queue and the main queue both.
@interface SGLyricsTaskState : NSObject
@property (nonatomic) SGLyricsTaskKind kind;
@property (nonatomic, copy) NSString *track;
@property (nonatomic) NSInteger status;
@property (nonatomic) BOOL donor, artwork;
@property (nonatomic, strong) NSMutableData *body;     // collected, none of it forwarded
@property (nonatomic) BOOL dropping;                   // the server's bytes go nowhere
@property (nonatomic) BOOL held, delivering, ended;
@property (nonatomic, strong) SGLyricsResult *chain;   // what a donor 200 was let through on
@property (nonatomic, strong) NSData *handing;         // the body this file is giving Spotify's delegate
@property (nonatomic, copy) SGDisposition realHandler;
@property (nonatomic) BOOL bodyGiven, chose;
@property (nonatomic) NSURLSessionResponseDisposition choice;
@end

@implementation SGLyricsTaskState
@end

static char kStateKey, kAnswerKey;
static NSData *sg_sectionTemplate;
static os_unfair_lock sg_templateLock = OS_UNFAIR_LOCK_INIT;

#pragma mark - reading requests

static NSString *lyricsTrack(NSURL *url) {
    NSString *path = url.path;
    NSRange marker = [path rangeOfString:kLyricsPath];
    if (marker.location == NSNotFound) return nil;
    NSString *rest = [path substringFromIndex:NSMaxRange(marker)];
    NSRange slash = [rest rangeOfString:@"/"];
    NSString *track = slash.location == NSNotFound ? rest : [rest substringToIndex:slash.location];
    return track.length ? track : nil;
}

static NSString *cardListTrack(NSURL *url) {
    if (![url.path containsString:kCardListPath]) return nil;
    for (NSString *component in url.pathComponents) {
        NSString *uri = component.stringByRemovingPercentEncoding ?: component;
        if ([uri hasPrefix:kTrackPrefix] && uri.length > kTrackPrefix.length) return [uri substringFromIndex:kTrackPrefix.length];
    }
    return nil;
}

static NSString *donorFor(NSURLRequest *request) {
    id track = request ? [NSURLProtocol propertyForKey:kDonorForKey inRequest:request] : nil;
    return [track isKindOfClass:NSString.class] && [track length] ? track : nil;
}

static NSString *trackOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    NSString *text = [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : [uri description];
    return [text hasPrefix:kTrackPrefix] && text.length > kTrackPrefix.length ? [text substringFromIndex:kTrackPrefix.length] : nil;
}

static NSURL *urlOf(NSURLSessionTask *task) {
    return task.currentRequest.URL ?: task.originalRequest.URL;
}

#pragma mark - the donor

// Only a real 200 makes the lyrics card show, so a track Spotify has none for is asked for as the
// donor, whose reply then carries the sources' lines. Everything but the id stays as Spotify sent it.
static NSURLRequest *donorRequestFor(NSURLRequest *request) {
    NSString *address = request.URL.absoluteString;
    if (![address containsString:kLyricsPath]) return nil;
    if ([NSURLProtocol propertyForKey:SGLyricsOwnRequestKey inRequest:request] || donorFor(request)) return nil;
    NSString *track = lyricsTrack(request.URL);
    if (!track || [track isEqualToString:kDonorTrack]) return nil;
    if (SGLyricsSpotifyHas(track) != 0 || !SGLyricsMayHave(track)) return nil;
    NSRange range = [address rangeOfString:[kLyricsPath stringByAppendingString:track]];
    if (range.location == NSNotFound) return nil;
    NSString *donorAddress = [address stringByReplacingCharactersInRange:range withString:[kLyricsPath stringByAppendingString:kDonorTrack]];
    NSURL *url = [NSURL URLWithString:donorAddress];
    if (!url) return nil;
    NSMutableURLRequest *donor = [request mutableCopy];
    donor.URL = url;
    [NSURLProtocol setProperty:track forKey:kDonorForKey inRequest:donor];
    SGLog(@"lyrics: Spotify has none for %@, its request goes to the donor", track);
    SGLyricsPrefetch(track);
    return donor;
}

#pragma mark - bodies

static NSData *defaultColours(void) {
    return SGPBSerialize(@[SGPBVarint(1, 0xFF535353u), SGPBVarint(2, 0xFF000000u), SGPBVarint(3, 0xFFFFFFFFu)]);
}

static NSData *coloursIn(NSData *body) {
    SGPBField *colours = SGPBFirst(SGPBParse(body), 2);
    return colours.wire == 2 ? colours.payload : nil;
}

static BOOL isJSON(NSData *body) {
    return body.length && ((const uint8_t *)body.bytes)[0] == '{';
}

static NSData *pageBody(SGLyricsResult *chain, NSData *colours) {
    NSMutableArray<SGPBField *> *lyrics = [NSMutableArray array];
    if (chain.synced) [lyrics addObject:SGPBVarint(1, 1)];
    NSArray<NSNumber *> *starts = chain.starts;
    [chain.texts enumerateObjectsUsingBlock:^(NSString *text, NSUInteger i, BOOL *stop) {
        NSInteger start = i < starts.count ? [starts[i] integerValue] : 0;
        NSData *line = SGPBSerialize(@[SGPBVarint(1, (uint64_t)MAX(start, 0)),
                                       SGPBString(2, [text isKindOfClass:NSString.class] ? text : @"")]);
        [lyrics addObject:SGPBBytes(2, line)];
    }];
    [lyrics addObject:SGPBString(5, chain.provider.length ? chain.provider : kUnnamedProvider)];
    return SGPBSerialize(@[SGPBBytes(1, SGPBSerialize(lyrics)), SGPBBytes(2, colours ?: defaultColours())]);
}

static NSString *timingName(NSArray<SGKaraokeLine *> *lines) {
    switch (SGKaraokeLinesTiming(lines)) {
        case SGKaraokeTimingWords: return @"word timed";
        case SGKaraokeTimingLine: return @"line timed";
        default: return @"untimed";
    }
}

// Which lines Spotify's page and the lyrics view get, the view's kept and credited. The body returned
// is the page's when the sources' lines replace Spotify's, nil when they do not.
static NSData *decide(NSString *track, SGLyricsResult *chain, NSData *spotifyBody, BOOL donor, NSData *colours) {
    NSArray<SGKaraokeLine *> *spotifyLines = spotifyBody ? SGKaraokeLinesFromBody(spotifyBody) : nil;
    if (!spotifyLines.count) spotifyLines = nil;
    SGKaraokeTiming spotifyTiming = SGKaraokeLinesTiming(spotifyLines);
    BOOL replace = chain.texts.count && (chain.synced || spotifyTiming == SGKaraokeTimingNone);
    NSData *page = replace ? pageBody(chain, colours) : nil;

    NSArray<SGKaraokeLine *> *viewLines = nil;
    NSString *credit = chain.provider;
    if (chain.karaokeLines.count && (!spotifyLines || SGKaraokeLinesTiming(chain.karaokeLines) <= spotifyTiming)) {
        viewLines = chain.karaokeLines;
    } else if (spotifyLines) {
        viewLines = spotifyLines;
        credit = @"Spotify";
    }
    if (viewLines) SGKaraokeKeepLines(track, viewLines);
    SGLyricsSetCredit(track, credit);
    // Spotify's JSON may have the song timed where its page does not.
    if (!donor && spotifyBody.length && SGKaraokeLinesTiming(viewLines) == SGKaraokeTimingNone) SGKaraokeAskSpotifyForTiming(track);

    NSString *provider = chain.provider.length ? chain.provider : kUnnamedProvider;
    NSString *pageGets = page ? [NSString stringWithFormat:@"%@'s lines", provider] : spotifyBody ? @"Spotify's own" : @"none";
    NSString *viewGets = viewLines ? [NSString stringWithFormat:@"%@'s lines, %@", viewLines == spotifyLines ? @"Spotify" : provider, timingName(viewLines)] : @"nothing";
    SGLog(@"lyrics: page of %@ gets %@; the lyrics view gets %@", track, pageGets, viewGets);
    return page;
}

#pragma mark - the card list

static NSData *sectionTemplate(NSData *latest) {
    os_unfair_lock_lock(&sg_templateLock);
    if (latest) sg_sectionTemplate = [latest copy];
    NSData *template = sg_sectionTemplate;
    os_unfair_lock_unlock(&sg_templateLock);
    return template;
}

static BOOL isLyricsSection(NSData *section) {
    for (SGPBField *field in SGPBParse(section)) {
        if (field.number == 5 && field.wire == 2) return YES;
    }
    return NO;
}

// A lyrics section Spotify sent for another track carries whatever else a section holds; one made from
// nothing has only the track.
static NSData *lyricsSection(NSString *track) {
    NSData *lyrics = SGPBSerialize(@[SGPBString(1, [kTrackPrefix stringByAppendingString:track])]);
    NSMutableArray<SGPBField *> *fields = SGPBParse(sectionTemplate(nil));
    for (SGPBField *field in fields) {
        if (field.number != 5 || field.wire != 2) continue;
        field.payload = lyrics;
        return SGPBSerialize(fields);
    }
    return SGPBSerialize(@[SGPBBytes(5, lyrics)]);
}

// The player asks for lyrics only when the list has a lyrics section, which the server sends only
// for tracks Spotify has lyrics for.
static NSData *amendedCardList(NSData *body, NSString *track) {
    NSMutableArray<SGPBField *> *top = SGPBParse(body);
    SGPBField *structure = SGPBFirst(top, 1);
    NSArray<SGPBField *> *sections = structure.wire == 2 ? SGPBParse(structure.payload) : nil;
    if (!sections) {
        SGLog(@"scrollsita: the card list of %@ could not be read, %lu bytes", track, (unsigned long)body.length);
        return body;
    }
    for (SGPBField *section in sections) {
        if (section.number != 1 || section.wire != 2 || !isLyricsSection(section.payload)) continue;
        sectionTemplate(section.payload);
        return body;
    }
    if (!SGLyricsMayHave(track)) return body;
    NSMutableData *amended = [SGPBSerialize(@[SGPBBytes(1, lyricsSection(track))]) mutableCopy];
    [amended appendData:structure.payload];
    structure.payload = amended;
    SGLog(@"scrollsita: lyrics section added for %@", track);
    return SGPBSerialize(top);
}

#pragma mark - the task's own -response

static Method ownMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int i = 0; i < count && !own; i++) {
        if (method_getName(methods[i]) == selector) own = methods[i];
    }
    free(methods);
    return own;
}

// Spotify may read the status off the task as well as the delegate argument. The task classes are
// private and differ between OS versions, so the one answering is taken from the first task that needs it.
static void answerAs(NSURLSessionTask *task, NSHTTPURLResponse *response) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL selector = @selector(response);
        for (Class cls = object_getClass(task); cls; cls = class_getSuperclass(cls)) {
            Method method = ownMethod(cls, selector);
            if (!method) continue;
            NSURLResponse *(*original)(id, SEL) = (NSURLResponse *(*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, imp_implementationWithBlock(^NSURLResponse *(id me) {
                return objc_getAssociatedObject(me, &kAnswerKey) ?: original(me, selector);
            }));
            SGLog(@"lyrics: -response answered on %s", class_getName(cls));
            return;
        }
    });
    objc_setAssociatedObject(task, &kAnswerKey, response, OBJC_ASSOCIATION_RETAIN);
}

#pragma mark - replies

static SGLyricsTaskState *stateOf(NSURLSessionTask *task) {
    id state = objc_getAssociatedObject(task, &kStateKey);
    return [state isKindOfClass:SGLyricsTaskState.class] ? state : nil;
}

// Received by a normal message send, so every hook on the selector sees it; this file's own lets it
// through by the object, since the server's bytes may be the same.
static void give(id delegate, NSURLSession *session, NSURLSessionDataTask *task, SGLyricsTaskState *state, NSData *body) {
    if (!body.length) return;
    @synchronized (state) { state.handing = body; }
    [delegate URLSession:session dataTask:task didReceiveData:body];
    @synchronized (state) { state.handing = nil; }
}

// Under @synchronized on the state. None once the task has ended.
static SGDisposition takeHandler(SGLyricsTaskState *state) {
    SGDisposition handler = state.ended ? nil : state.realHandler;
    state.realHandler = nil;
    return handler;
}

static SGLyricsTaskState *classify(NSURLSessionTask *task, NSURLResponse *response) {
    NSURLRequest *original = task.originalRequest, *current = task.currentRequest;
    NSString *originalAddress = original.URL.absoluteString, *currentAddress = current.URL.absoluteString;
    BOOL lyrics = [originalAddress containsString:kLyricsPath] || [currentAddress containsString:kLyricsPath];
    BOOL cards = [(currentAddress ?: originalAddress) containsString:kCardListPath];
    if (!lyrics && !cards) return nil;

    SGLyricsTaskState *state = [SGLyricsTaskState new];
    state.status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    NSString *cardTrack = cards ? cardListTrack(urlOf(task)) : nil;
    if (cardTrack) {
        if (state.status != 200) return nil;
        state.kind = SGLyricsTaskCardList;
        state.track = cardTrack;
        state.body = [NSMutableData data];
        return state;
    }

    NSString *track = donorFor(original) ?: donorFor(current);
    state.donor = track != nil;
    if (!track) track = lyricsTrack(original.URL) ?: lyricsTrack(current.URL);
    if (!track) return nil;
    state.track = track;
    SGLog(@"lyrics: Spotify answered %ld for %@%@", (long)state.status, track, state.donor ? @" through the donor" : @"");
    if (state.status == 200 && !state.donor) {
        state.kind = SGLyricsTaskSpotify;
        state.body = [NSMutableData data];
        return state;
    }
    state.kind = state.status == 200 ? SGLyricsTaskDonor : SGLyricsTaskMissing;
    state.artwork = state.donor && [current.URL.path containsString:@"/image/"];
    state.held = YES;
    state.dropping = YES;
    return state;
}

// A donor 200 goes through only with lines to put in it: once Spotify has seen a 200 it cannot be
// turned into "no lyrics", and the donor's own lines must never show.
static void answerDonor(NSURLSessionDataTask *task, SGLyricsTaskState *state, SGLyricsResult *chain,
                        NSURLResponse *response, SGDisposition handler, SGForwardResponse forward) {
    if (chain.texts.count) {
        @synchronized (state) {
            state.chain = chain;
            state.body = [NSMutableData data];
        }
        forward(response, handler);
        return;
    }
    decide(state.track, chain, nil, YES, nil);
    SGLog(@"lyrics: no source has lyrics for %@, it ends in a 404", state.track);
    NSHTTPURLResponse *notFound = [[NSHTTPURLResponse alloc] initWithURL:urlOf(task) statusCode:404 HTTPVersion:@"HTTP/2.0" headerFields:nil];
    answerAs(task, notFound);
    forward(notFound, handler);
}

// URLSession's handler waits until the body is in and Spotify's delegate has chosen, so none of the
// server's own bytes can reach the delegate ahead of it.
static void answerMissing(id delegate, NSURLSession *session, NSURLSessionDataTask *task, SGLyricsTaskState *state,
                          SGLyricsResult *chain, NSURLResponse *response, SGDisposition handler, SGForwardResponse forward) {
    NSData *page = decide(state.track, chain, nil, state.donor, nil);
    if (!page) {
        SGLog(@"lyrics: no source has lyrics for %@ either, it ends in Spotify's own %ld", state.track, (long)state.status);
        @synchronized (state) { state.dropping = NO; }
        forward(response, handler);
        return;
    }
    NSDictionary<NSString *, NSString *> *headers = @{
        @"Content-Type": @"application/protobuf",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)page.length],
    };
    NSHTTPURLResponse *found = [[NSHTTPURLResponse alloc] initWithURL:urlOf(task) statusCode:200 HTTPVersion:@"HTTP/2.0" headerFields:headers];
    @synchronized (state) { state.realHandler = handler; }
    answerAs(task, found);
    forward(found, ^(NSURLSessionResponseDisposition choice) {
        SGDisposition release = nil;
        @synchronized (state) {
            if (state.chose) return;
            state.chose = YES;
            state.choice = choice;
            if (state.bodyGiven) release = takeHandler(state);
        }
        if (release) release(choice);
    });
    give(delegate, session, task, state, page);
    SGDisposition release = nil;
    NSURLSessionResponseDisposition choice;
    @synchronized (state) {
        state.bodyGiven = YES;
        choice = state.choice;
        if (state.chose) release = takeHandler(state);
    }
    if (release) release(choice);
}

// Main queue, when the chain has answered for a held task. A task that ended meanwhile gets nothing.
static void answerHeld(id delegate, NSURLSession *session, NSURLSessionDataTask *task, SGLyricsTaskState *state,
                       SGLyricsResult *chain, NSURLResponse *response, SGDisposition handler, SGForwardResponse forward) {
    BOOL ended, cancelled = NO;
    @synchronized (state) {
        ended = state.ended;
        if (!ended) cancelled = task.state == NSURLSessionTaskStateCanceling || task.state == NSURLSessionTaskStateCompleted;
        if (!ended && !cancelled) {
            state.held = NO;
            state.delivering = YES;
        }
    }
    if (ended || cancelled) {
        SGLog(@"lyrics: the request for %@ ended before the sources answered, nothing delivered", state.track);
        // URLSession holds the end of a cancelled task back until it has a disposition.
        if (cancelled) handler(NSURLSessionResponseCancel);
        return;
    }
    if (state.kind == SGLyricsTaskDonor) answerDonor(task, state, chain, response, handler, forward);
    else answerMissing(delegate, session, task, state, chain, response, handler, forward);
    @synchronized (state) { state.delivering = NO; }
}

static void receivedResponse(id delegate, NSURLSession *session, NSURLSessionDataTask *task, NSURLResponse *response,
                             SGDisposition handler, SGForwardResponse forward) {
    if (objc_getAssociatedObject(task, &kStateKey)) {
        forward(response, handler);
        return;
    }
    SGLyricsTaskState *state = classify(task, response);
    BOOL held = state.held;
    objc_setAssociatedObject(task, &kStateKey, state ?: NSNull.null, OBJC_ASSOCIATION_RETAIN);
    if (!held) {
        forward(response, handler);
        return;
    }
    SGLyricsFetch(state.track, ^(SGLyricsResult *chain) {
        answerHeld(delegate, session, task, state, chain, response, handler, forward);
    });
}

static BOOL forwardsData(NSURLSessionTask *task, NSData *data) {
    SGLyricsTaskState *state = stateOf(task);
    if (!state) return YES;
    @synchronized (state) {
        if (data == state.handing) return YES;
        if (state.body) {
            [state.body appendData:data];
            return NO;
        }
        return !state.dropping;
    }
}

// Main queue.
static void finishSpotify(id delegate, NSURLSession *session, NSURLSessionDataTask *task, SGLyricsTaskState *state,
                          NSData *body, NSError *error, SGForwardEnd forward) {
    if (error) {
        forward(error);
        return;
    }
    if (isJSON(body)) {
        give(delegate, session, task, state, body);
        forward(nil);
        return;
    }
    SGLyricsFetch(state.track, ^(SGLyricsResult *chain) {
        NSData *page = decide(state.track, chain, body, NO, coloursIn(body));
        give(delegate, session, task, state, page ?: body);
        forward(nil);
    });
}

// Main queue.
static void finishDonor(id delegate, NSURLSession *session, NSURLSessionDataTask *task, SGLyricsTaskState *state,
                        NSData *body, NSError *error, SGForwardEnd forward) {
    SGLyricsResult *chain;
    @synchronized (state) { chain = state.chain; }
    if (error || !chain) {
        forward(error);
        return;
    }
    // The donor's colours are the track's own only when they were worked out from its artwork.
    NSData *page = decide(state.track, chain, nil, YES, state.artwork ? coloursIn(body) : nil);
    if (!page) {
        SGLog(@"lyrics: no source has lyrics for %@ any more, its request fails", state.track);
        NSString *reason = [NSString stringWithFormat:@"No lyrics source has lyrics for %@", state.track];
        forward([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorResourceUnavailable userInfo:@{NSLocalizedDescriptionKey: reason}]);
        return;
    }
    give(delegate, session, task, state, page);
    forward(nil);
}

static void completed(id delegate, NSURLSession *session, NSURLSessionTask *task, NSError *error, SGForwardEnd forward) {
    SGLyricsTaskState *state = stateOf(task);
    if (!state) {
        forward(error);
        return;
    }
    NSURLSessionDataTask *dataTask = (NSURLSessionDataTask *)task;
    NSData *body;
    BOOL held, delivering;
    @synchronized (state) {
        body = state.body;
        state.body = nil;
        held = state.held;
        delivering = state.delivering;
        state.ended = YES;
    }
    if (state.kind == SGLyricsTaskCardList) {
        if (!error) give(delegate, session, dataTask, state, amendedCardList(body, state.track));
        forward(error);
    } else if (state.kind == SGLyricsTaskSpotify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finishSpotify(delegate, session, dataTask, state, body, error, forward);
        });
    } else if (held) {
        // Ended while the sources walk: the end goes through now, and their answer to nobody.
        forward(error);
    } else if (state.kind == SGLyricsTaskDonor) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finishDonor(delegate, session, dataTask, state, body, error, forward);
        });
    } else if (delivering) {
        // Behind the response and body the main queue is handing over.
        dispatch_async(dispatch_get_main_queue(), ^{ forward(error); });
    } else {
        forward(error);
    }
}

#pragma mark - hooks

%group SGLyricsReplies

%hook SPTDataLoaderService
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(SGDisposition)handler {
    receivedResponse(self, session, task, response, handler, ^(NSURLResponse *given, SGDisposition then) {
        %orig(session, task, given, then);
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (forwardsData(task, data)) %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(self, session, task, error, ^(NSError *given) {
        %orig(session, task, given);
    });
}
%end

%hook _TtC26Connectivity_HttpClientKit20HttpClientURLSession
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(SGDisposition)handler {
    receivedResponse(self, session, task, response, handler, ^(NSURLResponse *given, SGDisposition then) {
        %orig(session, task, given, then);
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (forwardsData(task, data)) %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(self, session, task, error, ^(NSError *given) {
        %orig(session, task, given);
    });
}
%end

%end

%group SGLyricsEveryTrack

// Spotify's own verdict is noted before it is overridden, for the donor to go by. The getter runs for
// every track in every list many times a second, so it does a few lookups and nothing more.
%hook SPTPlayerTrack
- (NSDictionary *)metadata {
    NSDictionary *metadata = %orig;
    NSString *track = trackOf(self);
    if (!track) return metadata;
    BOOL has = [@"true" isEqual:metadata[@"has_lyrics"]];
    SGLyricsNoteSpotifyHas(track, has);
    SGKaraokeRememberTrack(self);
    if (has || !SGLyricsMayHave(track)) return metadata;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"lyrics: has_lyrics forced on, first for spotify:track:%@", track); });
    NSMutableDictionary *forced = metadata ? [metadata mutableCopy] : [NSMutableDictionary dictionary];
    forced[@"has_lyrics"] = @"true";
    return forced;
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(donorRequestFor(request) ?: request);
}
%end

%end

%group SGLyricsLocalSession

%hook __NSURLSessionLocal
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(donorRequestFor(request) ?: request);
}
%end

%end

%ctor {
    SGLyricsMigrateLegacyKeys();
    if (!SGLyricsEnabled()) return;
    %init(SGLyricsReplies);
    BOOL everyTrack = SGFlag(SGKeyLyricsAllTracks, NO);
    if (everyTrack) {
        // The generator gives a class that only inherits the method an override of its own, which would
        // put a second hook in front of NSURLSession's.
        SEL selector = @selector(dataTaskWithRequest:);
        Class local = objc_getClass("__NSURLSessionLocal");
        Method own = local ? ownMethod(local, selector) : NULL;
        BOOL hookLocal = own && method_getImplementation(own) != method_getImplementation(class_getInstanceMethod(NSURLSession.class, selector));
        %init(SGLyricsEveryTrack);
        if (hookLocal) %init(SGLyricsLocalSession);
    }
    SGLog(@"lyrics: sources %@, every track %@", [SGLyricsOrder() componentsJoinedByString:@", "], everyTrack ? @"on" : @"off");
    SGRequireClasses(@[@"SPTPlayerTrack", @"SPTDataLoaderService", @"_TtC26Connectivity_HttpClientKit20HttpClientURLSession"]);
}
