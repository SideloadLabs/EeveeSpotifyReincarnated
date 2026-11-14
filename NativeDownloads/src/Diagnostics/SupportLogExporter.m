#import "SupportLogExporter.h"
#import "SupportLog.h"
#import "TrackDownload.h"
#import "TrackJournal.h"
#import "DiagnosticTrace.h"
#import "TracePlatform.h"
#import <dlfcn.h>

static NSURL *SAPDocuments(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}

// В общий отчёт идёт компактная версия журнала: подробности лежат в своих файлах.
static NSDictionary *SAPJournalCompact(NSDictionary *report,NSString *currentURI) {
    NSMutableDictionary *value = [report mutableCopy];
    NSArray *tracks=value[@"tracks"];
    NSMutableArray *samples=[NSMutableArray array];
    NSString *current=value[@"focused_uri"];
    if(!current.length)current=currentURI;
    for(NSDictionary *track in tracks)
        if([track[@"uri"] isEqual:current]) {[samples addObject:track];break;}
    for(NSDictionary *track in tracks) {
        if(samples.count>=16)break;
        if(![samples containsObject:track] && ([track[@"state"] isEqual:@"error"] ||
            (track[@"ui_downloaded_matches_wire"] && ![track[@"ui_downloaded_matches_wire"] boolValue]))) [samples addObject:track];
    }
    value[@"comparison_samples"]=samples;
    for (NSString *key in @[@"tracks", @"recent_transitions", @"total_progress_samples", @"note"]) [value removeObjectForKey:key];
    return value;
}

dispatch_queue_t SAPReportQueue(void) {
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("SpotifyAudioProbe.reports",dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));});return queue;
}
NSDictionary *SAPCompleteDiagnosticSnapshotWithJournal(NSDictionary *native,NSDictionary *journal) {
    NSDictionary *download=SAPTrackDownloadReportWithJournal(journal);
    NSMutableDictionary *report=[native[@"report"] mutableCopy];
    report[@"track_download"]=download;report[@"track_journal"]=SAPJournalCompact(journal,download[@"track_uri"]);
    NSMutableDictionary *result=[native mutableCopy];result[@"report"]=report;result[@"journal_summary"]=download[@"journal_summary"];return result;
}
NSDictionary *SAPCompleteDiagnosticSnapshot(NSDictionary *native) {
    return SAPCompleteDiagnosticSnapshotWithJournal(native,SAPJournalReport());
}

void SAPExportSupportLog(NSDictionary *native,void (^completion)(NSURL *,NSError *)) {
            SAPTraceCaptureRuntimeManifest("support_log_export");
            dispatch_async(SAPReportQueue(),^{
                SAPJournalFlushActions();
                NSDictionary *journal=SAPJournalReport();
                NSMutableDictionary *report=[SAPCompleteDiagnosticSnapshotWithJournal(native,journal)[@"report"] mutableCopy];
                report[@"observation_note"]=[native[@"report"][@"diagnostics_enabled"] boolValue]?@"Passive diagnostic events were enabled when this package was exported.":@"Passive diagnostic events were disabled when this package was exported; their absence does not prove that no event occurred.";
                report[@"diagnostic_trace"]=SAPTraceExport();
                NSURL *summary=[SAPDocuments() URLByAppendingPathComponent:@"PixieSupportLog.json"];
                NSMutableArray *files=[NSMutableArray array];
                for(NSString *name in @[@"SpotifyAudioProbeJournal.log",@"SpotifyAudioProbeJournal.1.log",@"PixieActions.log",@"PixieActions.1.log"]) {
                    NSURL *url=[SAPDocuments() URLByAppendingPathComponent:name];
                    [files addObject:SAPSupportLogReadFile(url)];
                }
                NSURL *(*vitrineReport)(void)=dlsym(RTLD_DEFAULT,"SGWriteDiagnosticsFile");
                if(vitrineReport) {
                    NSURL *url=vitrineReport();
                    if([url isKindOfClass:NSURL.class])[files addObject:SAPSupportLogReadFile(url)];
                    else [files addObject:@{@"name":@"vitrine-diagnostics.txt",@"read_status":@"unavailable",@"error":@"Vitrine did not produce a diagnostics file"}];
                }else [files addObject:@{@"name":@"vitrine-diagnostics.txt",@"read_status":@"unavailable",@"error":@"Vitrine diagnostics exporter is not loaded"}];
                NSURL *eeveeLog=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"]];
                [files addObject:SAPSupportLogReadFile(eeveeLog)];
                NSError *error=nil;
                BOOL saved=SAPSupportLogWrite(summary,report,journal,SAPJournalSummaryForReport(journal),files,&error);
                dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(saved?summary:nil,error);});
            });
}
