#include "Diagnostics.h"
#import "Localization.h"
#import <Foundation/Foundation.h>
#import "TrackJournal.h"
#import "NativeErrorLog.h"
#import "WireProto.h"
#include <assert.h>

// Построение настоящих байтов сервиса Offline (номера полей — из дескриптора,
// analysis/offline-esperanto-service.md), чтобы журнал разбирал ровно тот формат,
// который приходит с устройства.
static NSData *join(NSArray<NSData *> *parts) {
    NSMutableData *data = [NSMutableData data];
    for (NSData *part in parts) [data appendData:part];
    return data;
}
static NSData *text(NSString *value) { return [value dataUsingEncoding:NSUTF8StringEncoding]; }
static NSData *floatField(unsigned number, float value) {
    uint32_t bits = 0; memcpy(&bits, &value, 4);
    NSMutableData *data = [NSMutableData data];
    uint8_t tag = (uint8_t)((number << 3) | 5);
    [data appendBytes:&tag length:1];
    for (unsigned i = 0; i < 4; i++) { uint8_t byte = (bits >> (i * 8)) & 0xff; [data appendBytes:&byte length:1]; }
    return data;
}
static NSData *item(NSString *uri, NSUInteger state, NSUInteger progress) {
    return SAPProtoBytes(1, join(@[SAPProtoBytes(1, text(uri)), SAPProtoInteger(2, state), SAPProtoInteger(4, progress)]));
}
static NSData *itemsResponse(NSArray<NSData *> *items) { return join(items); }
static NSData *contextResponse(NSString *entity, NSUInteger state, float percent, NSArray<NSData *> *items) {
    NSData *context = SAPProtoBytes(1, join(@[SAPProtoBytes(1, text(entity)), SAPProtoInteger(2, state), floatField(3, percent)]));
    NSMutableData *info = [context mutableCopy];
    for (NSData *value in items) [info appendData:SAPProtoBytes(2, [value subdataWithRange:NSMakeRange(2, value.length - 2)])];
    return SAPProtoBytes(1, info);
}
static NSData *progressResponse(uint64_t queued, uint64_t downloaded, uint64_t total, uint64_t speed, float percent) {
    return SAPProtoBytes(1, join(@[SAPProtoInteger(1, queued), SAPProtoInteger(3, downloaded), SAPProtoInteger(5, total),
        SAPProtoInteger(8, speed), floatField(9, percent), SAPProtoInteger(10, 120), SAPProtoInteger(7, 1)]));
}

static NSString *const trackA = @"spotify:track:aaaaaaaaaaaaaaaaaaaaaa";
static NSString *const trackB = @"spotify:track:bbbbbbbbbbbbbbbbbbbbbb";
static NSString *const trackC = @"spotify:track:cccccccccccccccccccccc";
static NSString *const playlist = @"spotify:playlist:dddddddddddddddddddddd";

@interface FakeLifetime : NSObject
@property(nonatomic) BOOL cancelled;
- (void)cancel;
@end
@implementation FakeLifetime
- (void)cancel { self.cancelled = YES; }
@end

static NSMutableArray *sent;
static NSMutableArray *streams;
static NSMutableArray *reads;

static NSDictionary *trackIn(NSDictionary *report, NSString *uri) {
    for (NSDictionary *value in report[@"tracks"]) if ([value[@"uri"] isEqual:uri]) return value;
    return nil;
}
static BOOL sentMethod(NSString *method) {
    for (NSString *value in sent) if ([value isEqual:method]) return YES;
    return NO;
}

int main(void) {
    @autoreleasepool {
    SAPDiagnosticsSetEnabled(true);

        sent = [NSMutableArray array]; streams = [NSMutableArray array];reads=[NSMutableArray array];
        SAPJournalSetCaller(^id(NSString *method, NSData *payload, BOOL stream, NSUInteger attempt, void (^response)(NSData *)) {
            assert(payload != nil);
            [sent addObject:method];
            if (!stream) {
                FakeLifetime *lifetime=[FakeLifetime new];
                [reads addObject:@{@"method":method,@"payload":payload,@"attempt":@(attempt),@"response":[response copy],@"lifetime":lifetime}];
                return lifetime;
            }
            FakeLifetime *lifetime = [FakeLifetime new]; [streams addObject:lifetime]; return lifetime;
        });
        SAPJournalDrainForTesting();

        // 1. Обычный ответ GetItems: три трека в разных состояниях.
        SAPJournalObserveCall(@"GetItems", SAPProtoBytes(1, text(trackA)),
            itemsResponse(@[item(trackA, 6, 0), item(trackB, 5, 42), item(trackC, 3, 100)]), @"app");
        SAPJournalDrainForTesting();
        NSDictionary *report = SAPJournalReport();
        assert([report[@"tracked_tracks"] unsignedIntegerValue] == 3);
        assert([report[@"state_counts"][@"waiting"] unsignedIntegerValue] == 1);
        assert([report[@"state_counts"][@"downloading"] unsignedIntegerValue] == 1);
        assert([report[@"state_counts"][@"downloaded"] unsignedIntegerValue] == 1);
        assert([report[@"pending_tracks"] unsignedIntegerValue] == 2);
        assert([trackIn(report, trackB)[@"progress"] unsignedIntegerValue] == 42);
        // Очередь незавершённых треков открывает сессию и сама опрашивает ядро.
        assert([report[@"session"] count] > 0);
        assert(sentMethod(@"SubscribeError") && sentMethod(@"SubscribeTotalProgress"));
        assert(sentMethod(@"LicenseStatus") && sentMethod(@"BulkRedownloadPreflight") && sentMethod(@"GetItems"));
        assert(streams.count >= 3);

        // 2. Ошибка ядра, затем переход трека в error: ошибка привязывается по времени.
        SAPJournalObserveCall(@"SubscribeError", NSData.data, SAPProtoInteger(1, 19), @"app");
        SAPJournalObserveCall(@"GetItems", SAPProtoBytes(1, text(trackB)),
            itemsResponse(@[item(trackB, 1, 42), item(trackA, 5, 7)]), @"app");
        SAPJournalDrainForTesting();
        report = SAPJournalReport();
        NSDictionary *failed = trackIn(report, trackB);
        assert([failed[@"state"] isEqual:@"error"]);
        NSDictionary *failure = [failed[@"errors"] lastObject];
        assert([failure[@"previous_state"] isEqual:@"downloading"]);
        assert([failure[@"core_error_name"] isEqual:@"TOO_MANY_TRACKS"] && [failure[@"correlated"] boolValue]);
        assert([[report[@"core_errors"] lastObject][@"code"] unsignedLongLongValue] == 19);
        NSDictionary *moving = trackIn(report, trackA);
        assert([moving[@"state"] isEqual:@"downloading"] && [moving[@"progress"] unsignedIntegerValue] == 7);
        assert([moving[@"transitions"] count] == 2);
        assert([[moving[@"transitions"] lastObject][@"from"] isEqual:@"waiting"]);
        assert([moving[@"time_in_state"][@"waiting"] doubleValue] >= 0);

        // 3. Команда загрузки и её реальный код ответа.
        SAPJournalObserveCall(@"AddDownload", SAPProtoBytes(2, text(trackC)), SAPProtoInteger(1, 19), @"app");
        SAPJournalDrainForTesting();
        report = SAPJournalReport();
        assert([trackIn(report, trackC)[@"add_response"] unsignedLongLongValue] == 19);
        assert([trackIn(report, trackC)[@"add_response_name"] isEqual:@"TOO_MANY_TRACKS"]);
        assert([trackIn(report, trackC)[@"add_requests"] unsignedIntegerValue] == 1);
        assert([report[@"add_errors"] unsignedIntegerValue] == 1);
        assert([report[@"method_calls"][@"AddDownload"] unsignedLongLongValue] == 1);

        // 4. Нажатие «Скачать» на плейлисте: полный список треков и их принадлежность.
        SAPJournalNoteEntityRequest(playlist, @[trackA, [NSURL URLWithString:trackB]]);
        SAPJournalDrainForTesting();
        report = SAPJournalReport();
        assert([report[@"entities"][playlist][@"requested_tracks"] unsignedIntegerValue] == 2);
        assert([trackIn(report, trackA)[@"entity"] isEqual:playlist]);
        assert([report[@"requested_tracks"] unsignedIntegerValue] == 3);

        // 5. GetContexts: состояние плейлиста и состояние каждого трека в нём.
        SAPJournalObserveCall(@"GetContexts", NSData.data,
            contextResponse(playlist, 4, 37.5f, @[item(trackA, 3, 100)]), @"probe");
        SAPJournalDrainForTesting();
        report = SAPJournalReport();
        assert([report[@"entities"][playlist][@"state"] isEqual:@"downloading"]);
        assert(fabs([report[@"entities"][playlist][@"percent_complete"] doubleValue] - 37.5) < 0.2);
        assert([trackIn(report, trackA)[@"state"] isEqual:@"downloaded"]);

        // 6. Снимки, объясняющие остановку: лицензии, место, сотовая сеть, общая очередь.
        SAPJournalObserveCall(@"LicenseStatus", NSData.data,
            join(@[SAPProtoInteger(1, 3333), SAPProtoInteger(2, 0), SAPProtoInteger(3, 0)]), @"probe");
        SAPJournalObserveCall(@"BulkRedownloadPreflight", NSData.data,
            join(@[SAPProtoInteger(1, 1048576), SAPProtoInteger(2, 120), SAPProtoInteger(3, 1),
                   SAPProtoInteger(4, 0), SAPProtoInteger(5, 0), SAPProtoInteger(6, 4)]), @"probe");
        SAPJournalObserveCall(@"GetTotalProgress", NSData.data, progressResponse(118, 2, 120, 65536, 1.7f), @"probe");
        SAPJournalObserveCall(@"GetOfflinePlaybackStatus", NSData.data, SAPProtoInteger(1, 1), @"probe");
        SAPJournalDrainForTesting();
        report = SAPJournalReport();
        assert([report[@"snapshots"][@"license_status"][@"free_licenses"] unsignedIntegerValue] == 0);
        assert([report[@"snapshots"][@"license_status"][@"max_licenses"] unsignedIntegerValue] == 3333);
        assert([report[@"snapshots"][@"bulk_preflight"][@"has_sufficient_storage"] boolValue] == NO);
        assert([report[@"snapshots"][@"bulk_preflight"][@"sync_over_cellular_allowed"] boolValue] == NO);
        assert([report[@"snapshots"][@"bulk_preflight"][@"is_on_cellular"] boolValue] == YES);
        assert([report[@"total_progress"][@"queued_tracks"] unsignedIntegerValue] == 118);
        assert([report[@"total_progress"][@"download_speed"] unsignedIntegerValue] == 65536);
        assert([report[@"snapshots"][@"offline_playback"][@"allowed"] boolValue] == YES);

        // 7. Значок строки: ровно то, что видит пользователь.
        SAPJournalNoteUIStatus(trackB, 4);
        SAPJournalObserveCall(@"GetItems",SAPProtoBytes(1,text(trackC)),item(trackC,7,0),@"app");
        SAPJournalNoteRowState(trackC,4);
        SAPJournalNoteQuota(@{@"current_tracks": @4, @"music_limit": @10000});
        SAPJournalDrainForTesting();
        report = SAPJournalReport();
        assert([trackIn(report, trackB)[@"ui_status"] isEqual:@"failed"]);
        assert([trackIn(report, trackC)[@"state"] isEqual:@"waiting_limit_exceeded"]);
        assert([report[@"snapshots"][@"quota"][@"music_limit"] unsignedIntegerValue] == 10000);
        assert([report[@"state_counts"][@"waiting_limit_exceeded"] unsignedIntegerValue] == 1);

        // 8. Отчёт должен сериализоваться и доезжать файлами.
        assert([NSJSONSerialization isValidJSONObject:report]);
        NSURL *json = SAPJournalWriteReport(); assert(json);
        NSURL *table = SAPJournalWriteTable(); assert(table);
        NSString *written = [NSString stringWithContentsOfURL:table encoding:NSUTF8StringEncoding error:NULL];
        assert([written containsString:@"waiting_limit_exceeded"] && [written containsString:@"TOO_MANY_TRACKS"]);
        NSString *summary = SAPJournalSummaryText();
        assert([summary containsString:@"Device licenses"] && [summary containsString:SAPL(@"Очередь ядра",@"Core queue")]);
        assert([summary containsString:SAPL(@"Проблемные треки",@"Tracks with issues")]);

        // 9. Постоянный лог на диске: весь путь треков, переживает перезапуск.
        NSString *log = [NSString stringWithContentsOfURL:[NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:@"SpotifyAudioProbeJournal.log"]] encoding:NSUTF8StringEncoding error:NULL];
        assert([log containsString:@"state"] && [log containsString:@"failed"]);
        assert([log containsString:@"rejected"] && [log containsString:@"icon"]);
        assert([log containsString:@"TOO_MANY_TRACKS"] && [log containsString:@"session"]);

        // 10. Сброс чистит журнал и снимает наши подписки.
        SAPJournalReset();
        SAPJournalDrainForTesting();
        report = SAPJournalReport();
        assert([report[@"tracked_tracks"] unsignedIntegerValue] == 0);
        assert([report[@"core_errors"] count] == 0 && [report[@"entities"] count] == 0);
        for (FakeLifetime *lifetime in streams) assert(lifetime.cancelled);

        // 11. Legacy GLUE enum and wire enum are distinct. Pending is not ERROR;
        // UI observations never overwrite a confirmed wire status.
        SAPJournalObserveCall(@"GetItems",SAPProtoBytes(1,text(trackA)),item(trackA,6,0),@"app");
        SAPJournalNoteRowState(trackA,1);SAPJournalNoteUIStatus(trackA,3);
        SAPJournalDrainForTesting();report=SAPJournalReport();
        NSDictionary *verified=trackIn(report,trackA);
        assert([verified[@"state"] isEqual:@"waiting"]);
        assert([verified[@"legacy_state"] isEqual:@"pending"]);
        assert([verified[@"ui_downloaded_matches_wire"] isEqual:@NO]);
        assert(![report[@"state_counts"][@"error"] unsignedIntegerValue]);
        assert([verified[@"ui_status"] isEqual:@"synced"]); // no fake icon correction

        // 12. SUCCESS(0) is not a core error and cannot explain a failed track.
        SAPJournalObserveCall(@"SubscribeError",NSData.data,NSData.data,@"app");
        SAPJournalObserveCall(@"GetItems",SAPProtoBytes(1,text(trackB)),item(trackB,1,0),@"app");
        SAPJournalDrainForTesting();report=SAPJournalReport();
        assert([report[@"core_errors"] count]==0);
        assert(![trackIn(report,trackB)[@"errors"] lastObject][@"core_error"]);

        // 13. Two independent same-method reads: one reply must not acknowledge
        // the other, nor may an unrelated subscription update acknowledge it.
        SAPJournalReset();SAPJournalDrainForTesting();[reads removeAllObjects];
        SAPJournalNoteUIStatus(trackA,3);SAPJournalNoteUIStatus(trackB,3);
        SAPJournalDrainForTesting();assert(reads.count==2);
        NSDictionary *first=reads[0],*second=reads[1];
        void (^replyA)(NSData *)=first[@"response"], (^replyB)(NSData *)=second[@"response"];
        replyA(item(trackA,3,100));SAPJournalDrainForTesting();
        assert([SAPJournalReport()[@"outstanding_calls"] count]==1);
        SAPJournalObserveCall(@"SubscribeItems",NSData.data,item(trackB,6,0),@"app");
        SAPJournalDrainForTesting();
        // It may start a diagnostic session, but the independent B query is still pending.
        NSUInteger beforeRetry=reads.count;SAPJournalTimeoutsForTesting();SAPJournalDrainForTesting();
        BOOL retriedB=NO;
        for(NSDictionary *read in [reads subarrayWithRange:NSMakeRange(beforeRetry,reads.count-beforeRetry)])
            if([read[@"payload"] isEqual:second[@"payload"]] && [read[@"attempt"] unsignedIntegerValue]==1)retriedB=YES;
        assert(retriedB);assert([(FakeLifetime *)second[@"lifetime"] cancelled]);
        // A late response from the timed-out route must not replace the retry result.
        replyB(item(trackB,3,100));SAPJournalDrainForTesting();
        assert([trackIn(SAPJournalReport(),trackB)[@"state"] isEqual:@"waiting"]);
        NSDictionary *retryB=nil;
        for(NSDictionary *read in reads)
            if([read[@"payload"] isEqual:second[@"payload"]] && [read[@"attempt"] unsignedIntegerValue]==1)retryB=read;
        ((void(^)(NSData *))retryB[@"response"])(item(trackB,0,0));SAPJournalDrainForTesting();
        assert([trackIn(SAPJournalReport(),trackB)[@"state"] isEqual:@"not_downloaded"]);
        SAPJournalReset();SAPJournalDrainForTesting();
        NSUInteger cancelledReadCount=reads.count;
        SAPJournalTimeoutsForTesting();SAPJournalDrainForTesting();assert(reads.count==cancelledReadCount);

        // 14. A pending read owns its lifetime until its exact reply. A reply
        // containing another URI must not turn a previous cached status into proof.
        __block __weak FakeLifetime *weakLifetime;
        __block void (^pendingRead)(NSData *);
        SAPJournalSetCaller(^id(NSString *method,NSData *payload,BOOL stream,NSUInteger attempt,void (^response)(NSData *)) {
            if(stream)return nil;
            pendingRead=response;
            FakeLifetime *lifetime=[FakeLifetime new];weakLifetime=lifetime;return lifetime;
        });
        SAPJournalDrainForTesting();
        __block BOOL verifiedDone=NO;__block NSDictionary *verifiedResult;
        SAPJournalVerifyTrack(trackA,^(NSDictionary *track){verifiedResult=track;verifiedDone=YES;});
        SAPJournalDrainForTesting();assert(weakLifetime!=nil);
        pendingRead(item(trackB,3,100));SAPJournalDrainForTesting();
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1];
        while(!verifiedDone && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        assert(verifiedDone && verifiedResult==nil && weakLifetime==nil);
        assert([SAPJournalReport()[@"focused_uri"] isEqual:trackA]);
        verifiedDone=NO;
        SAPJournalVerifyTrack(trackA,^(NSDictionary *track){verifiedResult=track;verifiedDone=YES;});
        SAPJournalDrainForTesting();pendingRead(item(trackA,3,100));SAPJournalDrainForTesting();
        deadline=[NSDate dateWithTimeIntervalSinceNow:1];
        while(!verifiedDone && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        assert(verifiedDone && [verifiedResult[@"uri"] isEqual:trackA] && [verifiedResult[@"state"] isEqual:@"downloaded"]);
        SAPJournalReset();SAPJournalDrainForTesting();pendingRead=nil;

        // URI-specific native error is authoritative evidence, not temporal
        // correlation with the global SubscribeError SUCCESS response.
        SAPNativeErrorLogParseForTesting([NSString stringWithFormat:@"Track %@: Key failed: key_denied",trackA]);
        SAPNativeErrorLogParseForTesting([NSString stringWithFormat:@"Offline track error: sync_error_offline_key_failed (7004) (%@) ()",trackA]);
        SAPJournalDrainForTesting();
        NSDictionary *nativeError=SAPJournalNativeErrorForURI(trackA);
        assert([nativeError[@"code"] integerValue]==7004);
        assert([nativeError[@"name"] isEqual:@"sync_error_offline_key_failed"]);
        assert(!SAPJournalNativeErrorForURI(trackB));
        assert([trackIn(SAPJournalReport(),trackA)[@"native_error"][@"code"] integerValue]==7004);
        NSString *nul=[NSString stringWithCharacters:(unichar[]){0} length:1];
        SAPNativeErrorLogParseForTesting([[NSString stringWithFormat:@"Track %@: Got key",trackA] stringByAppendingString:nul]);
        SAPJournalDrainForTesting();
        NSDictionary *recovery=trackIn(SAPJournalReport(),trackA);
        assert([recovery[@"key_received_after_native_error"] boolValue]);
        assert(![recovery[@"downloaded_after_native_error"] boolValue]);
        SAPNativeErrorLogParseForTesting([NSString stringWithFormat:@"Track %@ downloaded",trackA]);
        SAPJournalDrainForTesting();
        recovery=trackIn(SAPJournalReport(),trackA);
        assert([recovery[@"downloaded_after_native_error"] boolValue]);
        assert([recovery[@"native_events"] count]==4);
        // A completion from another URI cannot recover this track's error.
        SAPNativeErrorLogParseForTesting([NSString stringWithFormat:@"Track %@: Key failed: key_denied",trackB]);
        SAPJournalDrainForTesting();
        assert(![trackIn(SAPJournalReport(),trackB)[@"downloaded_after_native_error"] boolValue]);
        SAPJournalReset();SAPJournalDrainForTesting();

        // Diagnostics OFF must be quiet. Explicit verification still returns
        // the exact GetItems response without starting a collection session.
        SAPJournalRefresh(@"enable cancellation test");SAPJournalDrainForTesting();
        SAPDiagnosticsSetEnabled(false);SAPJournalDrainForTesting();
        NSUInteger oldReads=reads.count,oldSent=sent.count;
        SAPJournalNoteEntityRequest(playlist,@[[NSURL URLWithString:trackA]]);
        SAPJournalNoteRowState(trackA,3);SAPJournalNoteUIStatus(trackA,3);
        SAPJournalObserveCall(@"GetItems",nil,item(trackA,3,100),@"off");SAPJournalRefresh(@"off");
        SAPJournalDrainForTesting();assert(reads.count==oldReads && sent.count==oldSent);
        NSDictionary *quietReport=SAPJournalReport();assert(![quietReport[@"diagnostics_enabled"] boolValue]);
        NSUInteger oldActions=[quietReport[@"action_events"]count];
        NSString *actionPath=[NSTemporaryDirectory()stringByAppendingPathComponent:@"PixieActions.log"];
        NSData *beforeActions=[NSData dataWithContentsOfFile:actionPath];
        for(unsigned i=0;i<100;i++)SAPJournalNoteAction(@"must_not_log_while_off",@{@"i":@(i)});
        SAPJournalDrainForTesting();
        NSData *afterActions=[NSData dataWithContentsOfFile:actionPath];
        assert([SAPJournalReport()[@"action_events"]count]==oldActions&&((!beforeActions&&!afterActions)||[beforeActions isEqual:afterActions]));
        assert(![quietReport[@"subscribed"] boolValue] && [quietReport[@"session"] count]==0);
        assert(![SAPNativeErrorLogReport()[@"requested"] boolValue]);
        verifiedDone=NO;pendingRead=nil;
        SAPJournalVerifyTrack(trackA,^(NSDictionary *track){verifiedResult=track;verifiedDone=YES;});
        SAPJournalDrainForTesting();assert(pendingRead);
        pendingRead(item(trackA,3,100));SAPJournalDrainForTesting();
        deadline=[NSDate dateWithTimeIntervalSinceNow:1];
        while(!verifiedDone && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        assert(verifiedDone && [verifiedResult[@"state"] isEqual:@"downloaded"]);
        assert([verifiedResult[@"source"] isEqual:@"manual:GetItems"]);
        assert([SAPJournalReport()[@"session"] count]==0 && ![SAPJournalReport()[@"subscribed"] boolValue]);
        SAPDiagnosticsSetEnabled(true);SAPJournalDrainForTesting();SAPJournalReset();SAPJournalDrainForTesting();
        puts("PASS: diagnostics OFF stops journal subscriptions and collection; manual verification remains independent");
        SAPJournalObserveCall(@"GetItems",nil,item(trackA,3,100),@"snapshot test");SAPJournalDrainForTesting();
        NSDictionary *saved=SAPJournalReport();
        SAPJournalObserveCall(@"GetItems",nil,item(trackB,1,0),@"snapshot test");SAPJournalDrainForTesting();
        NSURL *savedJSON=SAPJournalWriteReportSnapshot(saved),*savedTable=SAPJournalWriteTableSnapshot(saved);
        NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:savedJSON] options:0 error:NULL];
        assert([decoded[@"generated_at"] isEqual:saved[@"generated_at"]]);
        assert([decoded[@"tracked_tracks"] unsignedIntegerValue]==1 && [SAPJournalReport()[@"tracked_tracks"] unsignedIntegerValue]==2);
        NSString *savedTableText=[NSString stringWithContentsOfURL:savedTable encoding:NSUTF8StringEncoding error:NULL];
        assert([savedTableText containsString:SAPL(@"Треков в журнале: 1",@"Tracks in log: 1")]);
        SAPJournalNoteNativeError(trackB,@7004,@"immediate_flush_test");SAPJournalDrainForTesting();
        NSString *flushedLog=[NSString stringWithContentsOfFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"SpotifyAudioProbeJournal.log"] encoding:NSUTF8StringEncoding error:NULL];
        assert([flushedLog containsString:@"immediate_flush_test"]);
        puts("PASS: TXT/JSON reuse the same immutable snapshot and error lines are immediately readable");
        SAPJournalNoteAction(@"before_manual_reset",@{@"old":@YES});SAPJournalDrainForTesting();
        NSError *resetError=nil;assert(SAPJournalResetLogFiles(&resetError)&&!resetError);
        assert([SAPJournalReport()[@"tracked_tracks"]unsignedIntegerValue]==0&&[SAPJournalReport()[@"action_events"]count]==0);
        assert(![NSFileManager.defaultManager fileExistsAtPath:actionPath]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:[NSTemporaryDirectory()stringByAppendingPathComponent:@"SpotifyAudioProbeJournal.log"]]);
        SAPJournalNoteAction(@"after_manual_reset",@{@"fresh":@YES});SAPJournalDrainForTesting();
        NSString *newActions=[NSString stringWithContentsOfFile:actionPath encoding:NSUTF8StringEncoding error:nil];
        assert([newActions containsString:@"after_manual_reset"]&&![newActions containsString:@"before_manual_reset"]);
        puts("PASS: action audit stays silent while OFF; manual reset removes old files and memory and permits fresh recording");
        printf("PASS: track journal records per-track state, progress, errors and core snapshots\n");
    }
    return 0;
}
