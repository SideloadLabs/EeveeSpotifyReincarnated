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
    if (seconds <= 0) return SAPLocalized(@"0s");
    unsigned total = (unsigned)round(seconds);
    if (total < 60) return [NSString stringWithFormat:SAPLocalized(@"%us"), total];
    if (total < 3600) return [NSString stringWithFormat:SAPLocalized(@"m_s"), total / 60, total % 60];
    return [NSString stringWithFormat:SAPLocalized(@"h_m"), total / 3600, (total / 60) % 60];
}
static NSString *bytesText(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:SAPLocalized(@"b"), bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:SAPLocalized(@"kb"), bytes / 1024.0];
    if (bytes < 1024ULL * 1024 * 1024) return [NSString stringWithFormat:SAPLocalized(@"mb"), bytes / 1048576.0];
    return [NSString stringWithFormat:SAPLocalized(@"gb"), bytes / 1073741824.0];
}
NSString *SAPJournalSummaryText(void) {
    if(!SAPDiagnosticsEnabled())return SAPLocalized(@"diagnostics_are_off_the_log_is_not");
    return SAPJournalSummaryForReport(SAPJournalReport());
}
NSString *SAPJournalSummaryForReport(NSDictionary *report) {
    if(![report[@"diagnostics_enabled"] boolValue])return SAPLocalized(@"diagnostics_are_off_the_log_is_not");
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
    [text appendFormat:SAPLocalized(@"tracks_in_log_requested"), report[@"tracked_tracks"], report[@"requested_tracks"]];
    [text appendFormat:@"✅ %@ · ⏬ %@ · ⌛ %@ · ⏸ %@\n",
        counts[@"downloaded"] ?: @0, counts[@"downloading"] ?: @0, counts[@"waiting"] ?: @0, counts[@"awaiting_redownload"] ?: @0];
    [text appendFormat:SAPLocalized(@"error_limit_not_downloaded_expired"),
        counts[@"error"] ?: @0, counts[@"waiting_limit_exceeded"] ?: @0, counts[@"not_downloaded"] ?: @0, counts[@"expired"] ?: @0];
    if ([report[@"stalled_tracks"] count]) [text appendFormat:SAPLocalized(@"stalled_without_progress"), (unsigned long)[report[@"stalled_tracks"] count]];
    if ([report[@"add_errors"] unsignedIntegerValue]) [text appendFormat:SAPLocalized(@"adddownload_errors"), report[@"add_errors"]];
    if (progress.count) {
        [text appendFormat:SAPLocalized(@"core_queue_tracks_of_s_remaining"),
            progress[@"downloaded_tracks"], progress[@"total_tracks"],
            bytesText([progress[@"downloaded_bytes"] unsignedLongLongValue]),
            bytesText([progress[@"total_bytes"] unsignedLongLongValue]),
            bytesText([progress[@"download_speed"] unsignedLongLongValue]),
            durationText([progress[@"seconds_left"] doubleValue])];
    }
    if (license.count) [text appendFormat:SAPLocalized(@"device_licenses_last_response_of_free"), license[@"free_licenses"], license[@"max_licenses"],
        [license[@"error"] unsignedLongLongValue] ? [NSString stringWithFormat:@" (%@)", license[@"error_name"]] : @""];
    if (preflight.count) [text appendFormat:SAPLocalized(@"enough_storage_cellular_downloading_now"),
        [preflight[@"has_sufficient_storage"] boolValue] ? SAPLocalized(@"yes") : SAPLocalized(@"no"),
        [preflight[@"is_on_cellular"] boolValue] ? ([preflight[@"sync_over_cellular_allowed"] boolValue] ? SAPLocalized(@"allowed") : SAPLocalized(@"blocked")) : SAPLocalized(@"not_in_use"),
        preflight[@"downloads_in_progress"]];
    if (quota.count) [text appendFormat:SAPLocalized(@"local_manager_quota_tracks_does_not"), quota[@"current_tracks"] ?: @"?", quota[@"music_limit"] ?: @"?"];
    if (playback.count) [text appendFormat:SAPLocalized(@"offline_playback"), [playback[@"allowed"] boolValue] ? SAPLocalized(@"allowed") : SAPLocalized(@"blocked")];
    NSDictionary *lastError = [report[@"core_errors"] lastObject];
    if (lastError) [text appendFormat:SAPLocalized(@"last_core_error_ago"), lastError[@"name"], lastError[@"code"],
        durationText([report[@"generated_at"] doubleValue] - [lastError[@"at"] doubleValue])];
    for (NSDictionary *entity in [report[@"entities"] allValues]) {
        [text appendFormat:SAPLocalized(@"playlist"), shortIdentifier(entity[@"uri"]), entity[@"state"] ?: @"?",
            entity[@"percent_complete"] ?: @0,
            entity[@"requested_tracks"] ? [NSString stringWithFormat:SAPLocalized(@"requested"), entity[@"requested_tracks"]] : @""];
    }
    NSArray *problems = report[@"tracks"];
    NSUInteger shown = 0;
    for (NSDictionary *track in problems) {
        if (shown >= 6) break;
        NSString *state = track[@"state"];
        if (![state isEqual:@"error"] && ![state isEqual:@"waiting_limit_exceeded"] && ![track[@"stalled"] boolValue]) continue;
        if (!shown) [text appendString:SAPLocalized(@"tracks_with_issues")];
        [text appendFormat:SAPLocalized(@"in_this_state_for"), track[@"id"], state, track[@"progress"],
            durationText([track[@"in_state_seconds"] doubleValue]),
            track[@"native_error"] ? [NSString stringWithFormat:@", %@ (%@)",track[@"native_error"][@"name"],track[@"native_error"][@"code"]?:@"code unavailable"] :
                track[@"add_response_name"] && ![track[@"add_response_name"] isEqual:@"SUCCESS"] ?
                [NSString stringWithFormat:@", AddDownload: %@", track[@"add_response_name"]] : @""];
        shown++;
    }
    if (!report[@"caller_available"] || ![report[@"caller_available"] boolValue])
        [text appendString:SAPLocalized(@"the_core_transport_is_not_available")];
    return text;
}
static NSString *tableText(NSDictionary *report) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:SAPLocalized(@"spotifyaudioprobe_offline_download_status"), [NSDate dateWithTimeIntervalSince1970:[report[@"generated_at"] doubleValue]]];
    [text appendString:SAPJournalSummaryForReport(report)];
    [text appendString:@"\n"];
    [text appendFormat:@"%-24s %-22s %5s %8s %6s %s\n", [SAPLocalized(@"track_2") UTF8String], [SAPLocalized(@"state") UTF8String], "%", [SAPLocalized(@"in_state") UTF8String], "UI", [SAPLocalized(@"transitions") UTF8String]];
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
    [text appendString:SAPLocalized(@"recent_transitions")];
    for (NSDictionary *step in report[@"recent_transitions"])
        [text appendFormat:@"%@  %@  %@ → %@  %@%%  %@\n", step[@"at"], shortIdentifier(step[@"track_uri"]),
            step[@"from"], step[@"to"], step[@"progress"], step[@"source"]];
    [text appendString:SAPLocalized(@"core_errors")];
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
