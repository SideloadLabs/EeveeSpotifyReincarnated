#import "PlayerTrace.h"
#import "WireProto.h"
#import "DiagnosticTrace.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>

static atomic_bool enabled;
static atomic_uint_fast64_t traceGeneration;
static atomic_uint pending, dropped, oversized;
static dispatch_queue_t traceQueue;
static void *traceQueueKey = &traceQueueKey;
static os_unfair_lock snapshotLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *snapshot;
// The following fields are only accessed on traceQueue.
static NSMutableArray<NSDictionary *> *events;
static NSDictionary *lastState;
static void (^eventSink)(NSDictionary *);
static uint8_t fingerprintSalt[32];
static NSUInteger sequence;
static const NSUInteger maxEvents = 120, maxRequestBytes = 65536, maxPending = 16;

static void initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        traceQueue = dispatch_queue_create("SpotifyAudioProbe.player-trace",
            dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        dispatch_queue_set_specific(traceQueue, traceQueueKey, traceQueueKey, NULL);
        events = [NSMutableArray array];
        snapshot = @{@"events": @[], @"event_count": @0};
    });
}
static void syncQueue(dispatch_block_t block) {
    initialize();
    if (dispatch_get_specific(traceQueueKey)) block();
    else dispatch_sync(traceQueue, block);
}
static BOOL current(uint64_t generation) {
    return atomic_load(&enabled) && atomic_load(&traceGeneration) == generation;
}
static BOOL reserve(uint64_t *generation) {
    if (!atomic_load(&enabled)) return NO;
    *generation = atomic_load(&traceGeneration);
    if (atomic_fetch_add(&pending, 1) >= maxPending) {
        atomic_fetch_sub(&pending, 1); atomic_fetch_add(&dropped, 1); return NO;
    }
    if (!current(*generation)) { atomic_fetch_sub(&pending, 1); return NO; }
    return YES;
}
static void append(NSDictionary *event, uint64_t generation) {
    if (!current(generation)) return;
    NSMutableDictionary *value = [event mutableCopy];
    value[@"sequence"] = @(++sequence);
    NSDictionary *immutable = [value copy];
    if([event[@"trace_segment"]unsignedLongLongValue]==SAPTraceGeneration())
        SAP_TRACE("player","structured_observation",[event[@"trace_operation_id"]unsignedLongLongValue],immutable);
    [events addObject:immutable];
    if (events.count > maxEvents) [events removeObjectAtIndex:0];
    NSDictionary *newSnapshot = @{@"events": [events copy], @"event_count": @(sequence),
        @"retained_events": @(events.count), @"max_events": @(maxEvents)};
    os_unfair_lock_lock(&snapshotLock); snapshot = newSnapshot; os_unfair_lock_unlock(&snapshotLock);
    // Neither the raw request nor any native objects reach the sink.
    if (current(generation) && eventSink) eventSink(immutable);
}
static NSString *safeURI(id value) {
    if ([value isKindOfClass:NSURL.class]) value=[value absoluteString];
    if (![value isKindOfClass:NSString.class]) return nil;
    if ([value isEqual:@"spotify:collection:tracks"]) return value;
    for (NSString *kind in @[@"track", @"album", @"playlist", @"artist", @"episode", @"show"]) {
        NSString *prefix = [NSString stringWithFormat:@"spotify:%@:", kind];
        if (![value hasPrefix:prefix] || [value length] != prefix.length + 22) continue;
        NSString *identifier = [value substringFromIndex:prefix.length];
        for (NSUInteger i = 0; i < identifier.length; i++) {
            unichar c = [identifier characterAtIndex:i];
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return nil;
        }
        return [value copy];
    }
    return nil;
}
static BOOL has(NSArray *fields, unsigned number, unsigned wire) {
    for (NSDictionary *field in fields)
        if ([field[@"number"] unsignedIntValue] == number && [field[@"wire"] unsignedIntValue] == wire) return YES;
    return NO;
}
static NSUInteger count(NSArray *fields, unsigned number, unsigned wire) {
    NSUInteger result = 0;
    for (NSDictionary *field in fields)
        if ([field[@"number"] unsignedIntValue] == number && [field[@"wire"] unsignedIntValue] == wire) result++;
    return result;
}
static void number(NSMutableDictionary *out, NSString *key, NSArray *fields, unsigned field, BOOL boolean) {
    if (has(fields, field, 0)) {
        uint64_t value = SAPProtoNumber(fields, field, 0);
        out[key] = boolean ? @(value != 0) : @(value);
    }
}
static void presence(NSMutableDictionary *out, NSString *key, NSArray *fields, unsigned field) {
    NSData *value = SAPProtoData(fields, field);
    out[[key stringByAppendingString:@"_present"]] = @(value != nil);
    if (value) out[[key stringByAppendingString:@"_bytes"]] = @(value.length);
}
// Salt is random per tracing session and is never exported. Only a short hash
// is retained, permitting PreparePlay/PlayPrepared correlation without IDs.
static NSString *fingerprint(NSData *data) {
    if (!data.length || data.length > 256) return nil;
    CC_SHA256_CTX context; uint8_t digest[CC_SHA256_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256_Init(&context);
    CC_SHA256_Update(&context, fingerprintSalt, sizeof(fingerprintSalt));
    CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
    CC_SHA256_Final(digest, &context);
#pragma clang diagnostic pop
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x",
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7]];
}
static void parseContext(NSMutableDictionary *out, NSArray *context) {
    NSString *uri = safeURI(SAPProtoString(context, 3));
    if (uri) out[@"context_uri"] = uri;
    out[@"context_url_present"] = @(SAPProtoData(context, 4) != nil);
    out[@"context_metadata_entries"] = @(count(context, 2, 2));
    number(out, @"context_is_loading", context, 5, YES);
    NSMutableArray *tracks = [NSMutableArray array];
    NSUInteger pages = 0, totalTracks = 0;
    BOOL invalidPage = NO;
    for (NSDictionary *field in context) {
        if ([field[@"number"] unsignedIntValue] != 1 || [field[@"wire"] unsignedIntValue] != 2) continue;
        pages++;
        NSArray *page = SAPProtoFields(field[@"value"]);
        if (!page) { invalidPage = YES; continue; }
        for (NSDictionary *track in page) {
            if ([track[@"number"] unsignedIntValue] != 1 || [track[@"wire"] unsignedIntValue] != 2) continue;
            totalTracks++;
            if (tracks.count >= 16) continue;
            NSString *trackURI = safeURI(SAPProtoString(SAPProtoFields(track[@"value"]), 1));
            if (trackURI) [tracks addObject:trackURI];
        }
    }
    out[@"context_pages"] = @(pages);
    out[@"context_explicit_tracks"] = @(totalTracks);
    if (tracks.count) out[@"context_track_uris"] = tracks;
    if (invalidPage) out[@"context_page_parse_failed"] = @YES;
}
static void parsePrepare(NSMutableDictionary *out, NSArray *prepare) {
    NSData *contextData = SAPProtoData(prepare, 1), *optionsData = SAPProtoData(prepare, 2);
    out[@"context_present"] = @(contextData != nil);
    out[@"prepare_options_present"] = @(optionsData != nil);
    NSArray *context = contextData ? SAPProtoFields(contextData) : nil;
    if (contextData && !context) out[@"context_parse_failed"] = @YES;
    if (context) parseContext(out, context);
    NSArray *options = optionsData ? SAPProtoFields(optionsData) : nil;
    if (optionsData && !options) { out[@"prepare_options_parse_failed"] = @YES; return; }
    number(out, @"always_play_something", options, 2, YES);
    number(out, @"initially_paused", options, 5, YES);
    number(out, @"system_initiated", options, 6, YES);
    number(out, @"prefetch_level", options, 9, NO);
    number(out, @"audio_stream", options, 10, NO);
    out[@"prefetch_level_effective"] = @(SAPProtoNumber(options, 9, 0));
    out[@"initially_paused_effective"] = @(SAPProtoNumber(options, 5, 0) != 0);
    out[@"player_options_override_present"] = @(SAPProtoData(options, 7) != nil);
    out[@"configuration_entries"] = @(count(options, 13, 2));
    out[@"seek_to_present"] = @(SAPProtoData(options, 4) != nil);
    presence(out, @"license", options, 12);
    presence(out, @"session_id", options, 11);
    presence(out, @"playback_id", options, 1);
    NSString *session = fingerprint(SAPProtoData(options, 11));
    NSString *playback = fingerprint(SAPProtoData(options, 1));
    if (session) out[@"session_fingerprint"] = session;
    if (playback) out[@"playback_fingerprint"] = playback;
    NSArray *skip = SAPProtoFields(SAPProtoData(options, 3));
    NSString *skipURI = safeURI(SAPProtoString(skip, 4));
    if (skipURI) out[@"skip_to_uri"] = skipURI;
    if (SAPProtoData(skip, 5)) number(out, @"skip_to_index", SAPProtoFields(SAPProtoData(skip, 5)), 1, NO);
    if (SAPProtoData(skip, 2)) number(out, @"skip_to_page", SAPProtoFields(SAPProtoData(skip, 2)), 1, NO);
}
void SAPPlayerTraceSetSink(void (^sink)(NSDictionary *)) {
    syncQueue(^{ eventSink = [sink copy]; });
}
void SAPPlayerTraceSetActive(BOOL active) {
    if(!active&&SAPTraceIsActive())return;
    initialize();
    if (!active) {
        atomic_store(&enabled, false);
        atomic_fetch_add(&traceGeneration, 1);
        return;
    }
    if (atomic_load(&enabled)) return;
    syncQueue(^{
        if (atomic_load(&enabled)) return;
        atomic_fetch_add(&traceGeneration, 1);
        [events removeAllObjects]; lastState = nil; sequence = 0;
        atomic_store(&dropped, 0); atomic_store(&oversized, 0);
        arc4random_buf(fingerprintSalt, sizeof(fingerprintSalt));
        os_unfair_lock_lock(&snapshotLock); snapshot = @{@"events": @[], @"event_count": @0}; os_unfair_lock_unlock(&snapshotLock);
        atomic_store(&enabled, true);
    });
}
void SAPPlayerTraceReset(void) {
    initialize();
    // Invalidate observations before waiting for the serial queue. Their
    // pending reservations are released by their own completion paths.
    atomic_store(&enabled, false);
    atomic_fetch_add(&traceGeneration, 1);
    syncQueue(^{
        atomic_store(&enabled, false);
        atomic_fetch_add(&traceGeneration, 1);
        [events removeAllObjects]; lastState = nil; sequence = 0;
        atomic_store(&dropped, 0); atomic_store(&oversized, 0);
        memset(fingerprintSalt, 0, sizeof(fingerprintSalt));
        os_unfair_lock_lock(&snapshotLock);
        snapshot = @{@"events": @[], @"event_count": @0};
        os_unfair_lock_unlock(&snapshotLock);
    });
}
void SAPObservePlayerRequest(id service, id method, id payload) {
    if (!atomic_load(&enabled)) return;
    if (![service isKindOfClass:NSString.class] || ![service isEqual:@"spotify.player.esperanto.proto.ContextPlayer"] ||
        ![method isKindOfClass:NSString.class] ||
        !([method isEqual:@"Play"] || [method isEqual:@"PreparePlay"] || [method isEqual:@"PlayPrepared"] || [method isEqual:@"DeleteSession"]) ||
        ![payload isKindOfClass:NSData.class]) return;
    uint64_t generation;
    if (!reserve(&generation)) return;
    NSUInteger length = [payload length];
    BOOL tooLarge = length > maxRequestBytes;
    NSData *copy = tooLarge ? nil : [payload copy];
    NSString *command = [method copy];
    NSTimeInterval at = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
    SAPTraceID operation=SAPTraceCurrentOperation();uint64_t traceSegment=SAPTraceGeneration();
    dispatch_async(traceQueue, ^{
        @try {
            if (!current(generation)) return;
            NSMutableDictionary *event = [@{@"type": @"request", @"method": command, @"at": @(at), @"request_bytes": @(length),@"trace_operation_id":@(operation),@"trace_segment":@(traceSegment)} mutableCopy];
            if (tooLarge) { atomic_fetch_add(&oversized, 1); event[@"parse_skipped_oversize"] = @YES; append(event, generation); return; }
            NSArray *fields = SAPProtoFields(copy);
            if (!fields) { event[@"parse_failed"] = @YES; append(event, generation); return; }
            if ([command isEqual:@"Play"] || [command isEqual:@"PreparePlay"]) {
                NSArray *prepare = [command isEqual:@"Play"] ? SAPProtoFields(SAPProtoData(fields, 1)) : fields;
                if (!prepare) event[@"prepare_request_parse_failed"] = @YES;
                else parsePrepare(event, prepare);
            } else {
                presence(event, @"session_id", fields, 1);
                NSString *session = fingerprint(SAPProtoData(fields, 1));
                if (session) event[@"session_fingerprint"] = session;
            }
            if ([command isEqual:@"Play"] || [command isEqual:@"PlayPrepared"]) {
                NSArray *options = SAPProtoFields(SAPProtoData(fields, 2));
                number(event, @"play_reason", options, 1, NO);
                number(event, @"play_operation", options, 2, NO);
                number(event, @"play_trigger", options, 3, NO);
            }
            append(event, generation);
        } @finally { atomic_fetch_sub(&pending, 1); }
    });
}
static Method getter(id object, NSString *name, SEL *selector, char type[32]) {
    if (!object) return NULL;
    *selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(object_getClass(object), *selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NULL;
    method_getReturnType(method, type, 32);
    return method;
}
static id objectValue(id object, NSString *name) {
    SEL selector; char type[32];
    if (!getter(object, name, &selector, type) || type[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static void boolValue(NSMutableDictionary *out, NSString *key, id object, NSString *name) {
    SEL selector; char type[32];
    if (!getter(object, name, &selector, type) || !(type[0] == 'B' || type[0] == 'c' || type[0] == 'C')) return;
    out[key] = @(((BOOL (*)(id, SEL))objc_msgSend)(object, selector) != NO);
}
void SAPObservePlayerState(id state) {
    uint64_t generation;
    if (!state || !reserve(&generation)) return;
    NSTimeInterval at = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
    SAPTraceID operation=SAPTraceCurrentOperation();uint64_t traceSegment=SAPTraceGeneration();
    NSDictionary *captured;
    @try {
        if (!current(generation)) { atomic_fetch_sub(&pending, 1); return; }
        // SPTPlayerState is mutable. Read it on the subscription's callback
        // thread before Spotify can update or reuse it; do not retain it in
        // the queued work or associate later values with this timestamp.
        NSMutableDictionary *value = [NSMutableDictionary dictionary];
        NSString *uri = safeURI(objectValue(objectValue(state, @"track"), @"URI"));
        if (!current(generation)) { atomic_fetch_sub(&pending, 1); return; }
        NSString *context = safeURI(objectValue(state, @"contextURI"));
        if (uri) value[@"track_uri"] = uri;
        if (context) value[@"context_uri"] = context;
        for (NSArray<NSString *> *field in @[@[@"playing", @"isPlaying"], @[@"paused", @"isPaused"],
                @[@"loading", @"isLoading"], @[@"buffering", @"isBuffering"]]) {
            if (!current(generation)) { atomic_fetch_sub(&pending, 1); return; }
            boolValue(value, field[0], state, field[1]);
        }
        if (!value.count || !current(generation)) { atomic_fetch_sub(&pending, 1); return; }
        captured = [value copy];
    } @catch (__unused NSException *exception) {
        // Unknown future state ABIs remain unobserved; playback is untouched.
        atomic_fetch_sub(&pending, 1); return;
    }
    dispatch_async(traceQueue, ^{
        @try {
            if (!current(generation)) return;
            if ([lastState isEqual:captured]) return;
            lastState = captured;
            NSMutableDictionary *value = [captured mutableCopy];
            value[@"type"] = @"state"; value[@"at"] = @(at);
            value[@"trace_operation_id"]=@(operation);value[@"trace_segment"]=@(traceSegment);
            append(value, generation);
        } @finally { atomic_fetch_sub(&pending, 1); }
    });
}
NSDictionary *SAPPlayerTraceReport(void) {
    initialize();
    os_unfair_lock_lock(&snapshotLock); NSDictionary *value = snapshot; os_unfair_lock_unlock(&snapshotLock);
    NSMutableDictionary *result = [value mutableCopy];
    result[@"active"] = @(atomic_load(&enabled));
    result[@"pending"] = @(atomic_load(&pending));
    result[@"dropped_pending_limit"] = @(atomic_load(&dropped));
    result[@"oversized_requests"] = @(atomic_load(&oversized));
    result[@"max_request_bytes"] = @(maxRequestBytes);
    result[@"max_pending"] = @(maxPending);
    result[@"trace_version"] = @1;
    return [result copy];
}
#ifdef SAP_TESTING
void SAPPlayerTraceDrainForTesting(void) { syncQueue(^{}); }
#endif
