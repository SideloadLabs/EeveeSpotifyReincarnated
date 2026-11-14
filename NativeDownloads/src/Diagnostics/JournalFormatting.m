#import "TrackJournal.h"
#import "JournalStorage.h"
#import "JournalNames.h"
#import "Localization.h"
#import "Diagnostics.h"
#include <math.h>

static NSString *shortIdentifier(NSString *uri) {
    NSRange range = [uri rangeOfString:@":" options:NSBackwardsSearch];
    return range.location == NSNotFound ? uri : [uri substringFromIndex:range.location + 1];
}


static NSString *durationText(double seconds) {
    if (seconds <= 0) return SAPL(@"0с",@"0s");
    unsigned total = (unsigned)round(seconds);
    if (total < 60) return [NSString stringWithFormat:SAPL(@"%uс",@"%us"), total];
    if (total < 3600) return [NSString stringWithFormat:SAPL(@"%uм %02uс",@"%um %02us"), total / 60, total % 60];
    return [NSString stringWithFormat:SAPL(@"%uч %02uм",@"%uh %02um"), total / 3600, (total / 60) % 60];
}
static NSString *bytesText(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:SAPL(@"%llu Б",@"%llu B"), bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:SAPL(@"%.1f КБ",@"%.1f KB"), bytes / 1024.0];
    if (bytes < 1024ULL * 1024 * 1024) return [NSString stringWithFormat:SAPL(@"%.1f МБ",@"%.1f MB"), bytes / 1048576.0];
    return [NSString stringWithFormat:SAPL(@"%.2f ГБ",@"%.2f GB"), bytes / 1073741824.0];
}
NSString *SAPJournalSummaryText(void) {
    if(!SAPDiagnosticsEnabled())return SAPL(@"Диагностика выключена. Журнал не обновляется. Включи её в разделе «Диагностика», чтобы собрать состояние загрузок. Проверка текущего трека доступна отдельно.",@"Diagnostics are off. The log is not updated. Enable Diagnostics to collect download status. You can still check the current track separately.");
    return SAPJournalSummaryForReport(SAPJournalReport());
}
NSString *SAPJournalSummaryForReport(NSDictionary *report) {
    if(![report[@"diagnostics_enabled"] boolValue])return SAPL(@"Диагностика выключена. Журнал не обновляется. Включи её в разделе «Диагностика», чтобы собрать состояние загрузок. Проверка текущего трека доступна отдельно.",@"Diagnostics are off. The log is not updated. Enable Diagnostics to collect download status. You can still check the current track separately.");
    NSDictionary *counts = report[@"state_counts"], *progress = report[@"total_progress"];
    NSDictionary *license = report[@"snapshots"][@"license_status"], *preflight = report[@"snapshots"][@"bulk_preflight"];
    NSDictionary *quota = report[@"snapshots"][@"quota"], *playback = report[@"snapshots"][@"offline_playback"];
    NSMutableString *text = [NSMutableString string];
    NSDictionary *core=report[@"snapshots"][@"core_status"];
    if([core[@"code"]unsignedLongLongValue]) {
        [text appendFormat:@"Last offline-core response: %@ (%@), %@ ago. Source: in-process API; server origin unverified.\n",
            SAPJournalErrorName([core[@"code"]unsignedLongLongValue]),core[@"code"],durationText([report[@"generated_at"]doubleValue]-[core[@"at"]doubleValue])];
    }
    if(playback.count && ![playback[@"allowed"]boolValue])
        [text appendFormat:@"Last Spotify offline playback response: NOT ALLOWED, %@ ago. Local quota changes do not confirm authorization.\n",
            durationText([report[@"generated_at"]doubleValue]-[playback[@"at"]doubleValue])];
    [text appendFormat:SAPL(@"Треков в журнале: %@ · запрошено: %@\n",@"Tracks in log: %@ · requested: %@\n"), report[@"tracked_tracks"], report[@"requested_tracks"]];
    [text appendFormat:@"✅ %@ · ⏬ %@ · ⌛ %@ · ⏸ %@\n",
        counts[@"downloaded"] ?: @0, counts[@"downloading"] ?: @0, counts[@"waiting"] ?: @0, counts[@"awaiting_redownload"] ?: @0];
    [text appendFormat:SAPL(@"❌ error: %@ · 🚫 лимит: %@ · ⚪️ не скачан: %@ · ⏱ истёк: %@\n",@"❌ error: %@ · 🚫 limit: %@ · ⚪️ not downloaded: %@ · ⏱ expired: %@\n"),
        counts[@"error"] ?: @0, counts[@"waiting_limit_exceeded"] ?: @0, counts[@"not_downloaded"] ?: @0, counts[@"expired"] ?: @0];
    if ([report[@"stalled_tracks"] count]) [text appendFormat:SAPL(@"Застряли без прогресса: %lu\n",@"Stalled without progress: %lu\n"), (unsigned long)[report[@"stalled_tracks"] count]];
    if ([report[@"add_errors"] unsignedIntegerValue]) [text appendFormat:SAPL(@"AddDownload с ошибкой: %@\n",@"AddDownload errors: %@\n"), report[@"add_errors"]];
    if (progress.count) {
        [text appendFormat:SAPL(@"Очередь ядра: %@/%@ треков, %@ из %@, %@/с, осталось %@\n",@"Core queue: %@/%@ tracks, %@ of %@, %@/s, %@ remaining\n"),
            progress[@"downloaded_tracks"], progress[@"total_tracks"],
            bytesText([progress[@"downloaded_bytes"] unsignedLongLongValue]),
            bytesText([progress[@"total_bytes"] unsignedLongLongValue]),
            bytesText([progress[@"download_speed"] unsignedLongLongValue]),
            durationText([progress[@"seconds_left"] doubleValue])];
    }
    if (license.count) [text appendFormat:SAPL(@"Лицензии: свободно %@ из %@%@\n",@"Device licenses (last response): %@ of %@ free%@\n"), license[@"free_licenses"], license[@"max_licenses"],
        [license[@"error"] unsignedLongLongValue] ? [NSString stringWithFormat:@" (%@)", license[@"error_name"]] : @""];
    if (preflight.count) [text appendFormat:SAPL(@"Места хватает: %@ · сотовая сеть: %@ · грузится сейчас: %@\n",@"Enough storage: %@ · cellular: %@ · downloading now: %@\n"),
        [preflight[@"has_sufficient_storage"] boolValue] ? SAPL(@"да",@"yes") : SAPL(@"НЕТ",@"NO"),
        [preflight[@"is_on_cellular"] boolValue] ? ([preflight[@"sync_over_cellular_allowed"] boolValue] ? SAPL(@"разрешена",@"allowed") : SAPL(@"ЗАПРЕЩЕНА",@"BLOCKED")) : SAPL(@"не используется",@"not in use"),
        preflight[@"downloads_in_progress"]];
    if (quota.count) [text appendFormat:SAPL(@"Квота менеджера: %@/%@ треков\n",@"Local manager quota: %@/%@ tracks (does not confirm device licensing)\n"), quota[@"current_tracks"] ?: @"?", quota[@"music_limit"] ?: @"?"];
    if (playback.count) [text appendFormat:SAPL(@"Офлайн-воспроизведение: %@\n",@"Offline playback: %@\n"), [playback[@"allowed"] boolValue] ? SAPL(@"разрешено",@"allowed") : SAPL(@"ЗАПРЕЩЕНО",@"BLOCKED")];
    NSDictionary *lastError = [report[@"core_errors"] lastObject];
    if (lastError) [text appendFormat:SAPL(@"Последняя ошибка ядра: %@ (%@), %@ назад\n",@"Last core error: %@ (%@), %@ ago\n"), lastError[@"name"], lastError[@"code"],
        durationText([report[@"generated_at"] doubleValue] - [lastError[@"at"] doubleValue])];
    for (NSDictionary *entity in [report[@"entities"] allValues]) {
        [text appendFormat:SAPL(@"Плейлист %@: %@ %@%%%@\n",@"Playlist %@: %@ %@%%%@\n"), shortIdentifier(entity[@"uri"]), entity[@"state"] ?: @"?",
            entity[@"percent_complete"] ?: @0,
            entity[@"requested_tracks"] ? [NSString stringWithFormat:SAPL(@", запрошено %@",@", requested %@"), entity[@"requested_tracks"]] : @""];
    }
    NSArray *problems = report[@"tracks"];
    NSUInteger shown = 0;
    for (NSDictionary *track in problems) {
        if (shown >= 6) break;
        NSString *state = track[@"state"];
        if (![state isEqual:@"error"] && ![state isEqual:@"waiting_limit_exceeded"] && ![track[@"stalled"] boolValue]) continue;
        if (!shown) [text appendString:SAPL(@"\nПроблемные треки:\n",@"\nTracks with issues:\n")];
        [text appendFormat:SAPL(@"• %@ — %@ %@%%, в состоянии %@%@\n",@"• %@ — %@ %@%%, in this state for %@%@\n"), track[@"id"], state, track[@"progress"],
            durationText([track[@"in_state_seconds"] doubleValue]),
            track[@"native_error"] ? [NSString stringWithFormat:@", %@ (%@)",track[@"native_error"][@"name"],track[@"native_error"][@"code"]?:@"code unavailable"] :
                track[@"add_response_name"] && ![track[@"add_response_name"] isEqual:@"SUCCESS"] ?
                [NSString stringWithFormat:@", AddDownload: %@", track[@"add_response_name"]] : @""];
        shown++;
    }
    if (!report[@"caller_available"] || ![report[@"caller_available"] boolValue])
        [text appendString:SAPL(@"\nКанал к ядру ещё не получен: запусти воспроизведение, чтобы журнал мог опрашивать состояние сам.\n",@"\nThe core transport is not available yet: start playback so the log can query the status.\n")];
    return text;
}
static NSString *tableText(NSDictionary *report) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:SAPL(@"SpotifyAudioProbe — состояние офлайн-загрузки, %@\n",@"SpotifyAudioProbe — offline download status, %@\n"), [NSDate dateWithTimeIntervalSince1970:[report[@"generated_at"] doubleValue]]];
    [text appendString:SAPJournalSummaryForReport(report)];
    [text appendString:@"\n"];
    [text appendFormat:@"%-24s %-22s %5s %8s %6s %s\n", [SAPL(@"ТРЕК",@"TRACK") UTF8String], [SAPL(@"СОСТОЯНИЕ",@"STATE") UTF8String], "%", [SAPL(@"В СОСТ.",@"IN STATE") UTF8String], "UI", [SAPL(@"ПЕРЕХОДЫ",@"TRANSITIONS") UTF8String]];
    for (NSDictionary *track in report[@"tracks"]) {
        NSMutableArray *path = [NSMutableArray array];
        for (NSDictionary *step in track[@"transitions"]) [path addObject:step[@"to"]];
        NSString *chain = [path componentsJoinedByString:@" → "];
        if (!chain.length) chain = @"—";
        [text appendFormat:@"%-24s %-22s %5lu %8s %6s %@%@\n",
            [track[@"id"] UTF8String], [track[@"state"] UTF8String],
            (unsigned long)[track[@"progress"] unsignedIntegerValue],
            [durationText([track[@"in_state_seconds"] doubleValue]) UTF8String],
            [(track[@"ui_status"] ?: @"—") UTF8String], chain,
            track[@"add_response_name"] && ![track[@"add_response_name"] isEqual:@"SUCCESS"] ?
                [NSString stringWithFormat:@"  AddDownload=%@", track[@"add_response_name"]] : @""];
    }
    [text appendString:SAPL(@"\nПереходы (последние):\n",@"\nRecent transitions:\n")];
    for (NSDictionary *step in report[@"recent_transitions"])
        [text appendFormat:@"%@  %@  %@ → %@  %@%%  %@\n", step[@"at"], shortIdentifier(step[@"track_uri"]),
            step[@"from"], step[@"to"], step[@"progress"], step[@"source"]];
    [text appendString:SAPL(@"\nОшибки ядра:\n",@"\nCore errors:\n")];
    for (NSDictionary *event in report[@"core_errors"])
        [text appendFormat:@"%@  %@ (%@)\n", event[@"at"], event[@"name"], event[@"code"]];
    return text;
}
NSURL *SAPJournalWriteReport(void) {return SAPJournalWriteReportSnapshot(SAPJournalReport());}
NSURL *SAPJournalWriteReportSnapshot(NSDictionary *report) {
    NSURL *url = SAPJournalDocumentsURL(@"SpotifyAudioProbeTracks.json");
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
    return json && [json writeToURL:url atomically:YES] ? url : nil;
}
NSURL *SAPJournalWriteTable(void) {return SAPJournalWriteTableSnapshot(SAPJournalReport());}
NSURL *SAPJournalWriteTableSnapshot(NSDictionary *report) {
    NSURL *url = SAPJournalDocumentsURL(@"SpotifyAudioProbeTracks.txt");
    NSData *data = [tableText(report) dataUsingEncoding:NSUTF8StringEncoding];
    return data && [data writeToURL:url atomically:YES] ? url : nil;
}
