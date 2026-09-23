// TTML, the shape Apple Music writes its lyrics in and the one BiniLyrics and Unison serve.
//
// <p begin="0:13.148" end="0:15.705" ttm:agent="v1">
//   <span begin="0:13.148" end="0:13.385">You</span> <span …>called</span>
//   <span ttm:role="x-bg"><span begin="0:15.083" end="0:15.401">(Aye,</span> …</span>
// </p>
//
// Two things here exist in no other source the mod reads. ttm:agent names the voice, which is how a
// duet ends up on two sides of the page; a span with the x-bg role holds the backing vocals sung
// under the line. The third is quieter but matters more: the spans of a Japanese or Chinese line sit
// flush against each other with no whitespace between them, and that is the only way to tell that a
// syllable continues a word rather than starting one.
//
// The head can carry the lines again in two more ways, each keyed to its line by the itunes:key of
// the <p>: Apple's translations, as text, and its pronunciations (transliterations), spelt in the
// Latin alphabet and timed by spans that start with the words of the line they spell out.
//
// <iTunesMetadata><translations><translation xml:lang="en-US"><text for="L1">I'm so drunk …
// <transliterations><transliteration xml:lang="ja-Latn"><text for="L1"><span begin=…>zenbu</span> …
#import "LyricsSources.h"

// A begin or end: seconds ("1.241"), minutes ("0:01.241"), hours ("1:02:03.456"), or a clock value
// with a unit after it ("1.5s", "500ms"). Negative on a value that is none of these.
static NSInteger msOfClock(NSString *clock) {
    NSString *text = [clock stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return -1;
    double scale = 1000;
    if ([text hasSuffix:@"ms"]) {
        scale = 1;
        text = [text substringToIndex:text.length - 2];
    } else if ([text hasSuffix:@"s"]) {
        text = [text substringToIndex:text.length - 1];
    }
    double total = 0;
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    if (parts.count > 3) return -1;
    for (NSString *part in parts) {
        if (!part.length || [part rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789."].invertedSet].location != NSNotFound) return -1;
        total = total * 60 + part.doubleValue;
    }
    return (NSInteger)llround(total * (parts.count > 1 ? 1000 : scale));
}

// The words of one container: a <p>, or the x-bg span inside it.
@interface SGTTMLContainer : NSObject
@property (nonatomic, strong) NSMutableArray<SGKaraokeWord *> *words;
@property (nonatomic) BOOL spaced;   // whitespace has gone by, so the next word is not joined
@end

@implementation SGTTMLContainer
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _words = [NSMutableArray array];
    _spaced = YES;
    return self;
}
@end

// A translation's or a pronunciation's text for one line, as read from the head.
@interface SGTTMLText : NSObject
@property (nonatomic, copy) NSArray<SGKaraokeWord *> *words, *backingWords;   // the timed spans
@property (nonatomic, copy) NSString *plain;                                  // every character
@end

@implementation SGTTMLText
@end

// What a <text> of the head is: a line again, in another language or spelt out.
typedef NS_ENUM(NSInteger, SGTTMLPart) {
    SGTTMLPartNone,
    SGTTMLPartTranslation,
    SGTTMLPartPronunciation,
};

@interface SGTTMLReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<SGKaraokeLine *> *lines;
@property (nonatomic, strong) NSMutableArray *keys;   // each line's itunes:key, NSNull where it has none
// By language, in the order the document lists them, then by the key of the line.
@property (nonatomic, strong) NSMutableArray<NSString *> *translationLanguages, *pronunciationLanguages;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, SGTTMLText *> *> *translations, *pronunciations;
@end

@implementation SGTTMLReader {
    NSMutableArray<SGTTMLContainer *> *_stack;   // the <p>, then its x-bg span while one is open
    SGTTMLContainer *_backing;                   // the x-bg container of the line being read
    NSInteger _lineStart, _lineEnd;
    NSString *_voice;
    NSString *_key;                              // the <p>'s itunes:key, or the <text>'s for
    SGTTMLPart _part, _reading;                  // the head's list open, and what the <text> read belongs to
    NSString *_language;                         // the xml:lang of that list
    NSMutableString *_plain;                     // every character of the line, for a line-timed <p>
    NSMutableString *_word;                      // the characters of the span being read
    NSInteger _wordStart, _wordEnd;
    NSUInteger _spanDepth, _bgDepth, _wordDepth;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lines = [NSMutableArray array];
    _keys = [NSMutableArray array];
    _stack = [NSMutableArray array];
    _translationLanguages = [NSMutableArray array];
    _pronunciationLanguages = [NSMutableArray array];
    _translations = [NSMutableDictionary dictionary];
    _pronunciations = [NSMutableDictionary dictionary];
    return self;
}

// A <p>, or a <text> of the head, starts: both are read into the same containers.
- (void)openLine {
    [_stack removeAllObjects];
    [_stack addObject:[SGTTMLContainer new]];
    _backing = nil;
    _word = nil;
    _spanDepth = _bgDepth = _wordDepth = 0;
    _plain = [NSMutableString string];
}

- (SGTTMLContainer *)top {
    return _stack.lastObject;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    if ([element isEqualToString:@"p"]) {
        [self openLine];
        _reading = SGTTMLPartNone;
        _lineStart = msOfClock(attributes[@"begin"]);
        _lineEnd = msOfClock(attributes[@"end"]);
        _voice = attributes[@"ttm:agent"] ?: attributes[@"agent"];
        _key = attributes[@"itunes:key"] ?: attributes[@"key"];
        return;
    }
    BOOL translation = [element isEqualToString:@"translation"];
    if (translation || [element isEqualToString:@"transliteration"]) {
        _part = translation ? SGTTMLPartTranslation : SGTTMLPartPronunciation;
        _language = attributes[@"xml:lang"] ?: attributes[@"lang"] ?: @"";
        return;
    }
    if ([element isEqualToString:@"text"] && _part != SGTTMLPartNone && attributes[@"for"].length) {
        [self openLine];
        _reading = _part;
        _key = attributes[@"for"];
        return;
    }
    if (![element isEqualToString:@"span"] || !_stack.count) return;
    _spanDepth++;
    NSString *role = attributes[@"ttm:role"] ?: attributes[@"role"];
    if ([role isEqualToString:@"x-bg"] && !_backing) {
        _backing = [SGTTMLContainer new];
        [_stack addObject:_backing];
        _bgDepth = _spanDepth;
        return;
    }
    // A span nested inside one that is already being read is ruby or a translation: its characters
    // belong to the word around it rather than making a word of their own.
    if (_word) return;
    NSInteger start = msOfClock(attributes[@"begin"]), end = msOfClock(attributes[@"end"]);
    if (start < 0) return;
    _word = [NSMutableString string];
    _wordStart = start;
    _wordEnd = MAX(end, start);
    _wordDepth = _spanDepth;
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)characters {
    if (!_stack.count) return;
    [_plain appendString:characters];
    if (_word) {
        [_word appendString:characters];
        return;
    }
    // Whitespace between two spans is the only record that a space belongs between the words.
    if ([characters stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return;
    if (characters.length) self.top.spaced = YES;
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified {
    if ([element isEqualToString:@"p"]) {
        [self finishLine];
        [_stack removeAllObjects];
        return;
    }
    if ([element isEqualToString:@"text"] && _reading != SGTTMLPartNone) {
        [self finishText];
        [_stack removeAllObjects];
        _reading = SGTTMLPartNone;
        return;
    }
    if ([element isEqualToString:@"translation"] || [element isEqualToString:@"transliteration"]) {
        _part = SGTTMLPartNone;
        return;
    }
    if (![element isEqualToString:@"span"] || !_stack.count) return;
    if (_word && _spanDepth == _wordDepth) {
        NSString *text = [_word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        SGTTMLContainer *into = self.top;
        if (text.length) {
            SGKaraokeWord *word = [SGKaraokeWord new];
            word.text = text;
            word.start = _wordStart;
            word.end = _wordEnd;
            word.joined = into.words.count > 0 && !into.spaced;
            [into.words addObject:word];
            into.spaced = NO;
        }
        _word = nil;
        _wordDepth = 0;
    }
    if (_bgDepth && _spanDepth == _bgDepth) {
        [_stack removeLastObject];
        _bgDepth = 0;
    }
    if (_spanDepth) _spanDepth--;
}

- (SGKaraokeLine *)lineFrom:(NSArray<SGKaraokeWord *> *)words {
    if (!words.count) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = words.firstObject.start;
    line.end = MAX(words.lastObject.end, line.start);
    return line;
}

- (void)finishLine {
    SGTTMLContainer *main = _stack.firstObject;
    SGKaraokeLine *line = [self lineFrom:main.words];
    // A document timed only by the line has no spans: its words are estimated, as Spotify's are.
    if (!line) {
        NSString *text = [_plain stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length || _lineStart < 0) return;
        NSInteger end = MAX(_lineEnd, _lineStart);
        line = [SGKaraokeEstimatedLines(@[@(_lineStart), @(end)], @[text, @""]) firstObject];
        if (!line) return;
    }
    if (_lineStart >= 0) line.start = _lineStart;
    if (_lineEnd > line.start) line.end = _lineEnd;
    line.voice = _voice;
    line.backing = [self lineFrom:_backing.words];
    [_lines addObject:line];
    [_keys addObject:_key ?: (id)NSNull.null];
}

- (void)finishText {
    BOOL translation = _reading == SGTTMLPartTranslation;
    NSMutableArray<NSString *> *languages = translation ? _translationLanguages : _pronunciationLanguages;
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, SGTTMLText *> *> *byLanguage = translation ? _translations : _pronunciations;
    if (!byLanguage[_language]) {
        byLanguage[_language] = [NSMutableDictionary dictionary];
        [languages addObject:_language];
    }
    SGTTMLText *text = [SGTTMLText new];
    text.words = _stack.firstObject.words;
    text.backingWords = _backing.words;
    // Whitespace as it would read: the head's text is set out over lines like any XML.
    NSArray<NSString *> *pieces = [_plain componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    text.plain = [[pieces filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    byLanguage[_language][_key] = text;
}

@end

#pragma mark - what the head adds to the lines

// The letters and digits alone, lowercased: a pronunciation or a translation that reads the same as its
// line is the line again, as an English line of a Japanese song is spelt out as itself.
static NSString *bareText(NSString *text) {
    NSMutableString *bare = [NSMutableString string];
    NSCharacterSet *kept = NSCharacterSet.alphanumericCharacterSet;
    NSString *lower = text.lowercaseString;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([kept characterIsMember:c]) [bare appendFormat:@"%C", c];
    }
    return bare;
}

// The translation the Lyrics page asks for: the one in that language, whichever the region ("en"
// takes "en-US"), and none in any other; with no language asked for, the first the document has.
static NSString *translationLanguage(NSArray<NSString *> *languages) {
    NSString *wanted = SGLyricsTranslationLanguage();
    if (!wanted.length) return languages.firstObject;
    NSString *base = [wanted componentsSeparatedByString:@"-"].firstObject.lowercaseString;
    for (NSString *language in languages) {
        if ([language caseInsensitiveCompare:wanted] == NSOrderedSame) return language;
    }
    for (NSString *language in languages) {
        if ([[language componentsSeparatedByString:@"-"].firstObject.lowercaseString isEqualToString:base]) return language;
    }
    return nil;
}

// A pronunciation in the Latin alphabet over any other ("ja-Latn" before "ja-Hira").
static NSString *pronunciationLanguage(NSArray<NSString *> *languages) {
    for (NSString *language in languages) {
        if ([language.lowercaseString hasSuffix:@"-latn"]) return language;
    }
    return languages.firstObject;
}

static SGKaraokeLine *spoken(NSArray<SGKaraokeWord *> *words, NSString *plain, SGKaraokeLine *of) {
    NSString *said = words.count ? nil : plain;
    SGKaraokeLine *line = nil;
    if (words.count) {
        line = [SGKaraokeLine new];
        line.words = words;
    } else if (said.length) {
        // Spelt out without spans: its words are estimated across the time of the line they spell.
        line = [SGKaraokeEstimatedLines(@[@(of.start), @(MAX(of.end, of.start))], @[said, @""]) firstObject];
    }
    if (!line || [bareText(SGKaraokeLineText(line)) isEqualToString:bareText(SGKaraokeLineText(of))]) return nil;
    line.start = of.start;
    line.end = MAX(of.end, line.words.lastObject.end);
    line.align = of.align;
    return line;
}

static void addHead(SGTTMLReader *reader) {
    NSString *translated = translationLanguage(reader.translationLanguages);
    NSString *spelt = pronunciationLanguage(reader.pronunciationLanguages);
    NSDictionary<NSString *, SGTTMLText *> *translations = translated ? reader.translations[translated] : nil;
    NSDictionary<NSString *, SGTTMLText *> *pronunciations = spelt ? reader.pronunciations[spelt] : nil;
    if (!translations.count && !pronunciations.count) return;
    [reader.lines enumerateObjectsUsingBlock:^(SGKaraokeLine *line, NSUInteger i, BOOL *stop) {
        id key = reader.keys[i];
        if (key == NSNull.null) return;
        NSString *translation = translations[key].plain;
        NSString *said = SGKaraokeLineText(line);
        if (line.backing) said = [said stringByAppendingFormat:@" %@", SGKaraokeLineText(line.backing)];
        if (translation.length && ![bareText(translation) isEqualToString:bareText(said)]) line.translation = translation;
        SGTTMLText *pronunciation = pronunciations[key];
        if (!pronunciation) return;
        line.pronunciation = spoken(pronunciation.words, pronunciation.plain, line);
        if (line.backing && pronunciation.backingWords.count) line.backing.pronunciation = spoken(pronunciation.backingWords, nil, line.backing);
    }];
}

NSArray<SGKaraokeLine *> *SGTTMLLines(NSString *xml) {
    if (![xml isKindOfClass:NSString.class] || !xml.length) return nil;
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    SGTTMLReader *reader = [SGTTMLReader new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = reader;
    // The TTML namespaces carry nothing the reader needs, and the prefixes it matches on
    // ("ttm:agent") only survive while they are left alone.
    parser.shouldProcessNamespaces = NO;
    [parser parse];
    if (!reader.lines.count) return nil;
    SGKaraokeAlignVoices(reader.lines);
    addHead(reader);
    return reader.lines;
}
