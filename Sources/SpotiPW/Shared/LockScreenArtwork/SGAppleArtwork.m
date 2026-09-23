#import "Core/SGCore.h"
#import "SGAppleArtwork.h"
#import "SGCanvas.h"

static NSString *const kTokenKey = @"spotifyglass.lockscreen.appletoken";
static NSString *const kWebPlayer = @"https://music.apple.com/us/browse";
static NSString *const kSearch = @"https://amp-api.music.apple.com/v1/catalog/us/search";
static NSString *const kBrowser = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                                   "(KHTML, like Gecko) Version/18.0 Safari/605.1.15";
// The lock screen is about 1200 pixels across; the stream above this one is twice the size for nothing.
static const NSInteger kWidestStream = 1100;

#pragma mark - reading the answers

static NSString *firstMatch(NSString *pattern, NSString *text, NSUInteger group) {
    if (!text.length) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:group]] : nil;
}

static NSDictionary *tokenPart(NSString *token, NSUInteger part) {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count != 3) return nil;
    NSMutableString *base64 = [[[parts[part] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                                stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
    while (base64.length % 4) [base64 appendString:@"="];
    NSData *json = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    id object = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

// The script carries a few tokens; the web player's is the one issued to AMPWebPlay.
NSString *SGAppleTokenIn(NSString *script) {
    if (!script.length) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
        @"[\"'](eyJ[A-Za-z0-9_=-]+\\.[A-Za-z0-9_=-]+\\.[A-Za-z0-9_=-]+)[\"']" options:0 error:nil];
    NSString *first = nil;
    for (NSTextCheckingResult *match in [regex matchesInString:script options:0 range:NSMakeRange(0, script.length)]) {
        NSString *token = [script substringWithRange:[match rangeAtIndex:1]];
        if ([tokenPart(token, 1)[@"iss"] isEqual:@"AMPWebPlay"]) return token;
        if (!first) first = token;
    }
    return first;
}

NSDate *SGAppleTokenExpiry(NSString *token) {
    id expiry = token.length ? tokenPart(token, 1)[@"exp"] : nil;
    return [expiry isKindOfClass:NSNumber.class] ? [NSDate dateWithTimeIntervalSince1970:[expiry doubleValue]] : nil;
}

// Lower case, accents and punctuation gone, so "Short n’ Sweet" and "Short n' Sweet" are one name.
static NSString *plain(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *folded = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [folded componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]) {
        if (word.length) [words addObject:word];
    }
    return [words componentsJoinedByString:@" "];
}

// The name without what tells one edition from another: "(Deluxe)", "[Remastered]", " - Single".
static NSString *withoutEdition(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]|\\s+-\\s+.*$"
                                                                           options:0 error:nil];
    return [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
}

// Spotify names the first artist, Apple Music may name them all: "Xavier Omär & ELHAE".
static BOOL sameArtist(NSString *theirs, NSString *ours) {
    if (!theirs.length || !ours.length) return NO;
    NSString *longer = theirs.length >= ours.length ? theirs : ours;
    NSString *shorter = longer == theirs ? ours : theirs;
    return [[NSString stringWithFormat:@" %@ ", longer] containsString:[NSString stringWithFormat:@" %@ ", shorter]];
}

static NSURL *coverIn(id videos, BOOL tall) {
    if (![videos isKindOfClass:NSDictionary.class]) return nil;
    NSArray<NSString *> *keys = tall ? @[@"motionTallVideo3x4", @"motionDetailTall", @"motionSquareVideo1x1", @"motionDetailSquare"]
                                     : @[@"motionSquareVideo1x1", @"motionDetailSquare"];
    for (NSString *key in keys) {
        id video = videos[key];
        id address = [video isKindOfClass:NSDictionary.class] ? video[@"video"] : nil;
        NSURL *url = [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
        if (url) return url;
    }
    return nil;
}

NSURL *SGAppleCoverPlaylist(NSArray *albums, NSString *artist, NSString *album, BOOL tall) {
    if (![albums isKindOfClass:NSArray.class]) return nil;
    NSString *wantedArtist = plain(artist), *wantedName = plain(album), *wantedBase = plain(withoutEdition(album));
    NSURL *edition = nil;
    for (id entry in albums) {
        id attributes = [entry isKindOfClass:NSDictionary.class] ? entry[@"attributes"] : nil;
        if (![attributes isKindOfClass:NSDictionary.class]) continue;
        if (!sameArtist(plain(attributes[@"artistName"]), wantedArtist)) continue;
        NSURL *playlist = coverIn(attributes[@"editorialVideo"], tall);
        if (!playlist) continue;
        if ([plain(attributes[@"name"]) isEqualToString:wantedName]) return playlist;
        if (!edition && wantedBase.length && [plain(withoutEdition(attributes[@"name"])) isEqualToString:wantedBase]) edition = playlist;
    }
    return edition;
}

static NSDictionary<NSString *, NSString *> *attributesOf(NSString *tag) {
    NSMutableDictionary<NSString *, NSString *> *attributes = [NSMutableDictionary dictionary];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)" options:0 error:nil];
    for (NSTextCheckingResult *match in [regex matchesInString:tag options:0 range:NSMakeRange(0, tag.length)]) {
        NSString *value = [tag substringWithRange:[match rangeAtIndex:2]];
        attributes[[tag substringWithRange:[match rangeAtIndex:1]]] = [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
    }
    return attributes;
}

static NSArray<NSString *> *linesOf(NSString *playlist) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [playlist componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [lines addObject:trimmed];
    }
    return lines;
}

NSURL *SGAppleStream(NSString *master, NSURL *base) {
    NSArray<NSString *> *lines = linesOf(master);
    NSString *best = nil;
    BOOL bestHEVC = NO;
    NSInteger bestArea = 0, bestRate = 0;
    for (NSUInteger at = 0; at + 1 < lines.count; at++) {
        if (![lines[at] hasPrefix:@"#EXT-X-STREAM-INF:"] || [lines[at + 1] hasPrefix:@"#"]) continue;
        NSDictionary<NSString *, NSString *> *attributes = attributesOf(lines[at]);
        NSArray<NSString *> *size = [attributes[@"RESOLUTION"] componentsSeparatedByString:@"x"];
        if (size.count != 2 || size[0].integerValue > kWidestStream) continue;
        NSInteger area = size[0].integerValue * size[1].integerValue;
        NSInteger rate = (attributes[@"AVERAGE-BANDWIDTH"] ?: attributes[@"BANDWIDTH"]).integerValue;
        BOOL hevc = [attributes[@"CODECS"] hasPrefix:@"hvc1"] || [attributes[@"CODECS"] hasPrefix:@"hev1"];
        BOOL better = !best || (hevc && !bestHEVC) ||
                      (hevc == bestHEVC && (area > bestArea || (area == bestArea && rate < bestRate)));
        if (!better) continue;
        best = lines[at + 1];
        bestHEVC = hevc;
        bestArea = area;
        bestRate = rate;
    }
    return best ? [NSURL URLWithString:best relativeToURL:base].absoluteURL : nil;
}

NSURL *SGAppleStreamFile(NSString *media, NSURL *base) {
    NSString *file = nil;
    for (NSString *line in linesOf(media)) {
        NSString *uri = [line hasPrefix:@"#EXT-X-MAP:"] ? attributesOf(line)[@"URI"] : [line hasPrefix:@"#"] ? nil : line;
        if (!uri) continue;
        if (file && ![file isEqualToString:uri]) return nil;
        file = uri;
    }
    return file ? [NSURL URLWithString:file relativeToURL:base].absoluteURL : nil;
}

#pragma mark - asking Apple

static NSString *sg_token;
static NSMutableArray<void (^)(NSString *)> *sg_waiting;
static NSMutableDictionary<NSString *, id> *sg_known;   // what each album gave this launch, NSNull for nothing
static CFAbsoluteTime sg_quietUntil;

// Every request goes out the way the web player's would; the answer lands on the main queue.
static void get(NSURL *url, NSString *token, void (^done)(NSString *body, NSInteger status)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.allowsConstrainedNetworkAccess = NO;
    [request setValue:kBrowser forHTTPHeaderField:@"User-Agent"];
    if (token) {
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:@"https://music.apple.com" forHTTPHeaderField:@"Origin"];
    }
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *body = data && !error ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(body, status); });
    }] resume];
}

static void readToken(void (^done)(NSString *token, NSString *note)) {
    get([NSURL URLWithString:kWebPlayer], nil, ^(NSString *page, NSInteger status) {
        NSString *script = firstMatch(@"/assets/index~[^\"']+\\.js", page, 0) ?: firstMatch(@"/assets/index[^\"']*\\.js", page, 0);
        if (!script) {
            done(nil, [NSString stringWithFormat:@"no script on the web player's page (%ld)", (long)status]);
            return;
        }
        get([NSURL URLWithString:script relativeToURL:[NSURL URLWithString:kWebPlayer]], nil, ^(NSString *code, NSInteger scriptStatus) {
            NSString *token = SGAppleTokenIn(code);
            done(token, token ? [NSString stringWithFormat:@"read, good until %@", SGAppleTokenExpiry(token)]
                              : [NSString stringWithFormat:@"not in %@ (%ld)", script, (long)scriptStatus]);
        });
    });
}

// The token lasts about ten weeks, so it is read once and kept until it runs out or Apple turns it down.
static void withToken(BOOL fresh, void (^use)(NSString *token)) {
    if (!fresh) {
        NSString *kept = sg_token ?: [NSUserDefaults.standardUserDefaults stringForKey:kTokenKey];
        if ([SGAppleTokenExpiry(kept) timeIntervalSinceNow] > 3600) {
            sg_token = kept;
            use(kept);
            return;
        }
    }
    if (sg_waiting) {
        [sg_waiting addObject:use];
        return;
    }
    sg_waiting = [NSMutableArray arrayWithObject:use];
    readToken(^(NSString *token, NSString *note) {
        SGLog(@"lock artwork: Apple Music token %@", note);
        sg_token = token;
        if (token) [NSUserDefaults.standardUserDefaults setObject:token forKey:kTokenKey];
        NSArray<void (^)(NSString *)> *waiting = sg_waiting;
        sg_waiting = nil;
        for (void (^waiter)(NSString *) in waiting) waiter(token);
    });
}

static void clipIn(NSURL *playlist, void (^done)(NSURL *file, NSString *note)) {
    get(playlist, nil, ^(NSString *master, NSInteger status) {
        NSURL *stream = SGAppleStream(master, playlist);
        if (!stream) {
            done(nil, [NSString stringWithFormat:@"no stream in the cover's playlist (%ld)", (long)status]);
            return;
        }
        get(stream, nil, ^(NSString *media, NSInteger mediaStatus) {
            NSURL *file = SGAppleStreamFile(media, stream);
            done(file, file ? [NSString stringWithFormat:@"stream %@", stream.lastPathComponent]
                            : [NSString stringWithFormat:@"%@ is not one file (%ld)", stream.lastPathComponent, (long)mediaStatus]);
        });
    });
}

static void search(NSString *token, NSString *artist, NSString *album, BOOL tall, NSString *known, BOOL mayRetry,
                   void (^done)(SGCanvas *canvas, NSString *note)) {
    if (!token) {
        done(nil, @"no Apple Music token");
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:kSearch];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"term" value:[NSString stringWithFormat:@"%@ %@", artist, withoutEdition(album)]],
        [NSURLQueryItem queryItemWithName:@"types" value:@"albums"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"10"],
        [NSURLQueryItem queryItemWithName:@"extend" value:@"editorialVideo"],
    ];
    get(components.URL, token, ^(NSString *body, NSInteger status) {
        if (status == 401 && mayRetry) {
            withToken(YES, ^(NSString *fresh) { search(fresh, artist, album, tall, known, NO, done); });
            return;
        }
        if (status == 403 || status == 429) {
            sg_quietUntil = CFAbsoluteTimeGetCurrent() + 600;
            done(nil, [NSString stringWithFormat:@"Apple Music answered %ld, asking again in ten minutes", (long)status]);
            return;
        }
        id root = status == 200 ? [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil] : nil;
        if (![root isKindOfClass:NSDictionary.class]) {
            done(nil, [NSString stringWithFormat:@"the search answered %ld", (long)status]);
            return;
        }
        id results = root[@"results"];
        id albums = [results isKindOfClass:NSDictionary.class] ? results[@"albums"] : nil;
        NSURL *playlist = SGAppleCoverPlaylist([albums isKindOfClass:NSDictionary.class] ? albums[@"data"] : nil, artist, album, tall);
        if (!playlist) {
            sg_known[known] = NSNull.null;
            done(nil, @"no animated cover");
            return;
        }
        clipIn(playlist, ^(NSURL *file, NSString *note) {
            if (!file) {
                done(nil, note);
                return;
            }
            SGCanvas *canvas = [SGCanvas new];
            canvas.identifier = [@"am-" stringByAppendingString:file.lastPathComponent.stringByDeletingPathExtension];
            canvas.address = file.absoluteString;
            canvas.video = YES;
            sg_known[known] = canvas;
            done(canvas, note);
        });
    });
}

void SGAppleArtworkFind(NSString *artist, NSString *album, BOOL tall, void (^done)(SGCanvas *canvas, NSString *note)) {
    if (![artist isKindOfClass:NSString.class] || ![album isKindOfClass:NSString.class] || !artist.length || !album.length) {
        done(nil, @"no artist or album to look up");
        return;
    }
    if (!sg_known) sg_known = [NSMutableDictionary dictionary];
    NSString *known = [NSString stringWithFormat:@"%d\n%@\n%@", tall, plain(artist), plain(album)];
    id before = sg_known[known];
    if (before) {
        done(before == NSNull.null ? nil : before, @"known from before");
        return;
    }
    if (CFAbsoluteTimeGetCurrent() < sg_quietUntil) {
        done(nil, @"Apple Music asked for a pause");
        return;
    }
    withToken(NO, ^(NSString *token) { search(token, artist, album, tall, known, YES, done); });
}
