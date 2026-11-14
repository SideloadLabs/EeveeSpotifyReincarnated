#import "Localization.h"
#import "TrackExport.h"
#import "ExportArtwork.h"
#import "SupportLogExporter.h"
#import "DownloadCompatibility.h"
#import "OfflineDevices.h"
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <dlfcn.h>
#import "AudioProbe.h"
#import "SourceGraph.h"
#import "OfflineFlags.h"
#import "TrackDownload.h"
#import "OfflineConfig.h"
#import "NativeOffline.h"
#import "TrackJournal.h"
#import "AudioProbeUI.h"
#import "Diagnostics.h"
#import "DiagnosticTrace.h"
#import "TracePlatform.h"
#import "NativeKeyTrace.h"
#import "PlayerTrace.h"
#import "NativeErrorLog.h"
#import "BuildIdentity.h"
#import "ProcessScope.h"
#if SAP_JAILBREAK
#import "JailbreakSupport.h"
#endif

static NSURL *SAPDocuments(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}

static UIViewController *SAPTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
            if (candidate.isKeyWindow && candidate.windowLevel == UIWindowLevelNormal) window = candidate;
    }
    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) controller = controller.presentedViewController;
        else if ([controller isKindOfClass:UINavigationController.class]) controller = ((UINavigationController *)controller).visibleViewController;
        else if ([controller isKindOfClass:UITabBarController.class]) controller = ((UITabBarController *)controller).selectedViewController;
        else break;
    }
    return controller;
}

static void SAPPresent(UIViewController *modal) {
    UIViewController *host = SAPTopController();
    id<UIViewControllerTransitionCoordinator> transition = host.transitionCoordinator;
    if (transition) {
        BOOL registered = [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            dispatch_async(dispatch_get_main_queue(), ^{ SAPPresent(modal); });
        }];
        if (registered) return;
    }
    [host presentViewController:modal animated:YES completion:nil];
}

static void SAPMessage(NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SAPL(@"Менеджер загрузок Pixie",@"Pixie Download Manager") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[NSNotificationCenter.defaultCenter postNotificationName:@"SAPDownloadSettingsChanged" object:nil];}]];
    SAPPresent(alert);
}

static __weak UIAlertController *SAPDownloadAlert;
static void SAPDownloadMessage(NSString *message) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIAlertController *current = SAPDownloadAlert;
    if (current && !current.isBeingDismissed) { current.message = message; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SAPL(@"Скачать текущий трек",@"Download current track") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[NSNotificationCenter.defaultCenter postNotificationName:@"SAPDownloadSettingsChanged" object:nil];}]];
    SAPDownloadAlert = alert;
    SAPPresent(alert);
}

static void SAPShareItems(NSArray *items) {
    if (!items.count) return;
    UIViewController *controller = SAPTopController();
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = controller.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), CGRectGetMidY(controller.view.bounds), 1, 1);
    SAPPresent(share);
}

static void SAPShare(NSURL *url) {
    if (!url) return;
    UIViewController *controller = SAPTopController();
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = controller.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), CGRectGetMidY(controller.view.bounds), 1, 1);
    SAPPresent(share);
}

static NSString *fourcc(uint32_t value) {
    char text[5] = {(char)(value >> 24), (char)(value >> 16), (char)(value >> 8), (char)value, 0};
    for (unsigned i = 0; i < 4; ++i) if (text[i] < 32 || text[i] > 126) text[i] = '?';
    return [NSString stringWithUTF8String:text];
}

static NSDictionary *SAPLocationReport(const SAPCodeLocation *location) {
    return @{@"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)location->address],
        @"image_base": [NSString stringWithFormat:@"0x%llx", (unsigned long long)location->imageBase],
        @"preferred_address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)location->preferredAddress],
        @"image": [NSString stringWithUTF8String:location->image] ?: @"",
        @"symbol": [NSString stringWithUTF8String:location->symbol] ?: @""};
}
static NSDictionary *SAPSourceReport(void) {
    SAPSourceGraph graph; SAPReadSourceGraph(&graph);
    NSMutableArray *methods = [NSMutableArray arrayWithCapacity:8];
    for (unsigned i = 0; i < 8; ++i) [methods addObject:SAPLocationReport(&graph.methods[i])];
    return @{@"status": @(graph.status), @"callback": SAPLocationReport(&graph.callback),
        @"owner": [NSString stringWithFormat:@"0x%llx", (unsigned long long)graph.owner],
        @"source": [NSString stringWithFormat:@"0x%llx", (unsigned long long)graph.source],
        @"vtable": [NSString stringWithFormat:@"0x%llx", (unsigned long long)graph.vtable],
        @"methods": methods};
}

@implementation SAPSettingsActions
+ (NSDictionary *)snapshot {
    NSMutableDictionary *value=[@{@"diagnostics_enabled":@(SAPDiagnosticsEnabled()),
        @"diagnostics":SAPL(@"Диагностика выключена. Включи переключатель «Диагностика» для сбора данных.",@"Diagnostics are off. Enable Diagnostics to collect data."),
        @"journal_summary":SAPL(@"Диагностика выключена. Журнал не обновляется. Проверка текущего трека доступна отдельно.",@"Diagnostics are off. The log is not updated. You can still check the current track separately."),
        @"download_active":@(SAPTrackDownloadActive()),@"key_request_mode":SAPKeyRequestModeReport()}mutableCopy];
#if SAP_JAILBREAK
    value[@"jailbreak_bootstrap"]=SAPJailbreakSupportReport();
#endif
    return value;
}
+ (NSDictionary *)snapshotForDetails:(BOOL)journal {
    if(!SAPDiagnosticsEnabled())return [self snapshot];
    if(!journal)return SAPCompleteDiagnosticSnapshot([self diagnosticSnapshot]);
    NSMutableDictionary *value=[[self snapshot]mutableCopy];value[@"journal_summary"]=SAPJournalSummaryText();return value;
}
+ (void)loadDetails:(BOOL)journal completion:(void (^)(NSDictionary *))completion {
    if(!SAPDiagnosticsEnabled()){if(completion)completion([self snapshot]);return;}
    // Native/UI objects are read on the calling main thread; only immutable
    // values and the journal's own snapshot cross to the report queue.
    NSDictionary *native=journal?[self snapshot]:[self diagnosticSnapshot];
    dispatch_async(SAPReportQueue(),^{
        NSDictionary *value;
        if(journal){NSMutableDictionary *copy=[native mutableCopy];copy[@"journal_summary"]=SAPJournalSummaryForReport(SAPJournalReport());value=copy;}
        else value=SAPCompleteDiagnosticSnapshot(native);
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(value);});
    });
}
+ (NSDictionary *)diagnosticSnapshot {
    SAPSnapshot s; SpotifyAudioProbeReadSnapshot(&s);
    NSString *source = [NSString stringWithUTF8String:s.callbackImage] ?: @"";
    NSArray *ports = [AVAudioSession.sharedInstance.currentRoute.outputs valueForKey:@"portName"];
    NSString *route = [ports componentsJoinedByString:@", "];
    NSDictionary *report = @{
        @"probe_version": @91,@"pixie_build":@SAP_BUILD_LABEL,@"audio_export":SAPTrackExportReport(),@"pixie_revision":@SAP_BUILD_REVISION,@"vitrine_source_commit":@SAP_VITRINE_SOURCE_COMMIT,
        @"diagnostics_enabled":@(SAPDiagnosticsEnabled()), @"backend_ready": @(s.backendReady), @"pcm_confirmed": @(s.pcmConfirmed),
        @"au_set_calls": @(s.setPropertyCalls), @"au_callback_attempts": @(s.callbackAttempts),
        @"au_last_scope": @(s.lastCallbackScope), @"au_last_type": fourcc(s.lastComponentType),
        @"au_last_element": @(s.lastCallbackElement), @"au_last_subtype": fourcc(s.lastComponentSubtype),
        @"au_last_status": @(s.lastSetStatus), @"objc_hooks": @(s.objcHooks),
        @"sample_buffer_calls": @(s.sampleBufferCalls), @"player_buffer_calls": @(s.playerBufferCalls),
        @"compressed_buffers": @(s.compressedBuffers), @"extraction_errors": @(s.extractionErrors),
        @"last_sample_format": fourcc(s.lastSampleFormat),
        @"registrations": @(s.registrations), @"output_starts": @(s.outputStarts), @"callbacks": @(s.callbacks),
        @"frames": @(s.frames), @"pcm_bytes": @(s.pcmBytes), @"nonzero_callbacks": @(s.nonzeroCallbacks),
        @"callback_errors": @(s.callbackErrors),
        @"sample_rate": @(s.sampleRate), @"channels": @(s.channels), @"format": fourcc(s.formatID),
        @"format_flags": @(s.formatFlags), @"bits_per_channel": @(s.bitsPerChannel),
        @"source_image": source, @"source_callback": [NSString stringWithFormat:@"0x%llx", (unsigned long long)s.procAddress],
        @"unit": [NSString stringWithFormat:@"0x%llx", (unsigned long long)s.unitAddress],
        @"track_source": SAPSourceReport(), @"offline_flags": SAPOfflineFlagsReport(), @"offline_config": SAPOfflineConfigReport() ,
        @"key_request_mode":SAPKeyRequestModeReport(),@"compatibility_check":SAPDownloadCompatibilityReport(),
        @"trace_coverage":SAPTraceReport(),@"native_key_trace":SAPNativeKeyTraceReport(),@"settings_integration":SAPDownloadSettingsInstallReport(),
        @"route": route ?: @"", @"pool_exhausted": @(s.poolExhausted), @"retired": @(s.retired),
        @"last_callback_age_seconds": @(s.lastCallbackAgeSeconds)
    };
#if SAP_JAILBREAK
    NSMutableDictionary *withBootstrap=[report mutableCopy];withBootstrap[@"jailbreak_bootstrap"]=SAPJailbreakSupportReport();report=withBootstrap;
#endif
    NSString *message = [NSString stringWithFormat:SAPL(@"%@\nCallback: %llu · Кадров: %llu\nPCM: %llu байт · Ненулевых блоков: %llu\n%.0f Hz · %u ch · %u bit · %@\nИсточник: %@\nВыход: %@",@"%@\nCallbacks: %llu · Frames: %llu\nPCM: %llu bytes · Nonzero buffers: %llu\n%.0f Hz · %u ch · %u bit · %@\nSource: %@\nOutput: %@"),
        [NSString stringWithFormat:SAPL(@"v26 · %@ · Хуков AV: %u\nAU вызовов: %u · Запусков: %u\nКолбэки: %u → %u · %@\nSampleBuffer: %llu · PlayerNode: %llu\nСжатых: %llu (%@) · Ошибок: %llu\n%@",@"v26 · %@ · AV hooks: %u\nAU calls: %u · Starts: %u\nCallbacks: %u → %u · %@\nSampleBuffer: %llu · PlayerNode: %llu\nCompressed: %llu (%@) · Errors: %llu\n%@"),
            s.backendReady ? SAPL(@"библиотека готова",@"library ready") : SAPL(@"ошибка AudioToolbox",@"AudioToolbox error"), s.objcHooks,
            s.setPropertyCalls, s.outputStarts, s.callbackAttempts, s.registrations, fourcc(s.lastComponentType),
            (unsigned long long)s.sampleBufferCalls,
            (unsigned long long)s.playerBufferCalls, (unsigned long long)s.compressedBuffers,
            fourcc(s.lastSampleFormat), (unsigned long long)s.extractionErrors,
            s.pcmConfirmed ? SAPL(@"PCM получен",@"PCM confirmed") : SAPL(@"PCM пока не подтверждён",@"PCM not confirmed yet")],
        (unsigned long long)s.callbacks, (unsigned long long)s.frames, (unsigned long long)s.pcmBytes,
        (unsigned long long)s.nonzeroCallbacks, s.sampleRate, s.channels, s.bitsPerChannel, fourcc(s.formatID),
        source.lastPathComponent.length ? source.lastPathComponent : SAPL(@"не зарегистрирован",@"not registered"), route];
    return @{ @"report":report, @"diagnostics":message, @"journal_summary":@"",
        @"download_active":@(SAPTrackDownloadActive()), @"key_request_mode":SAPKeyRequestModeReport() };
}
+ (void)setKeyRequestMode:(NSInteger)mode completion:(void (^)(BOOL,NSString *))completion {
    SAPSetKeyRequestMode(mode,completion);
}
+ (void)refreshDownloadCompatibility:(void (^)(NSDictionary *))completion {
    SAPRefreshDownloadCompatibility(completion);
}
+ (void)previewOfflineDeviceSlots:(void (^)(NSDictionary *,NSString *))completion {SAPPreviewOfflineDeviceSlots(completion);}
+ (void)releaseOfflineDeviceSlots:(NSString *)planID cacheIDs:(NSArray *)cacheIDs completion:(void (^)(NSDictionary *,NSString *))completion {SAPReleaseOfflineDeviceSlots(planID,cacheIDs,completion);}
+ (void)enableOfflineOnCurrentDevice:(void (^)(NSDictionary *,NSString *))completion {SAPEnableOfflineOnCurrentDevice(completion);}
+ (void)perform:(SAPSettingsAction)action {
    if(!SAPTraceIsActive()){[self performObserved:action];return;}
    SAPTraceID operation=SAPTraceBegin(@"settings_action",@"pixie_ui",@{@"action_number":@(action)});
    SAPTraceWithOperation(operation,^{[self performObserved:action];});
    SAP_TRACE("ui","action_handler_returned",operation,@{@"action_number":@(action),@"asynchronous_completion_proven":@NO});
}
+ (void)performObserved:(SAPSettingsAction)action {
#if SAP_JAILBREAK
    NSDictionary *startup=SAPJailbreakSupportReport();
    if((action==SAPSettingsDownload||action==SAPSettingsDownloadAlbum)&&![startup[@"native_patches_ready"]boolValue]) {
        SAPMessage([NSString stringWithFormat:@"Pixie downloads could not initialize (%@). This DEB requires the verified Spotify 9.1.92 executable. Detected version: %@.",startup[@"reason"],startup[@"detected_spotify_version"]]);return;
    }
#endif
    switch(action) {
        case SAPSettingsExportTrackAudio:
        case SAPSettingsExportAlbumAudio: {
            UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"Audio export" message:@"Preparing audio export… Large albums may take a moment." preferredStyle:UIAlertControllerStyleAlert];
            [progress addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){SAPCancelAudioExport();}]];
            SAPDownloadAlert=progress;SAPPresent(progress);
            __weak UIAlertController *exportProgress=progress;
            SAPExportCurrentAudioWithKeyRefresh(action==SAPSettingsExportAlbumAudio,^(NSString *text){
                UIAlertController *progress=exportProgress;
                if(progress.presentingViewController && !progress.isBeingDismissed)progress.message=text;
            },^(NSUInteger count,void (^decide)(BOOL)){
                UIAlertController *progress=exportProgress;
                void (^ask)(void)=^{
                    NSString *body=[NSString stringWithFormat:SAPL(@"Полный аудиофайл для %lu трек(ов) не прочитан. Скачать трек заново? Потребуется интернет.",@"Complete audio could not be read for %lu track(s). Download the track again? Internet is required."),(unsigned long)count];
                    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:SAPL(@"Скачать заново трек?",@"Download track again?") message:body preferredStyle:UIAlertControllerStyleAlert];
                    [confirm addAction:[UIAlertAction actionWithTitle:SAPL(@"Да",@"Yes") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
                        SAPDownloadAlert=progress;SAPPresent(progress);
                        decide(YES);
                    }]];
                    [confirm addAction:[UIAlertAction actionWithTitle:SAPL(@"Нет",@"No") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){decide(NO);}]];
                    [confirm addAction:[UIAlertAction actionWithTitle:SAPL(@"Отмена",@"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){decide(NO);}]];
                    SAPPresent(confirm);
                };
                if(progress.presentingViewController){[progress dismissViewControllerAnimated:YES completion:ask];}else ask();
            },^(NSArray<NSURL *> *files,NSString *error){
                BOOL cancelled=[error isEqualToString:@"Audio export cancelled."];
                void (^show)(void)=^{if(cancelled)return;if(files.count){SAPPrepareAudioExportShareItems(files,action==SAPSettingsExportAlbumAudio,^(NSArray *items,NSString *shareError){if(items.count)SAPShareItems(items);else SAPMessage(shareError?:@"Could not prepare the album folder. The exported files remain in Pixie Exports.");});}else SAPMessage(error?:@"No audio files were exported.");};
                UIAlertController *progress=exportProgress;
                if(progress.presentingViewController){if(SAPDownloadAlert==progress)SAPDownloadAlert=nil;[progress dismissViewControllerAnimated:YES completion:show];}else show();
            });break;
        }

        case SAPSettingsDownload: SAPDownloadCurrentTrack(^(NSString *text){SAPDownloadMessage(text);});break;
        case SAPSettingsDownloadAlbum: SAPDownloadCurrentAlbum(^(NSString *text){SAPDownloadMessage(text);});break;
        case SAPSettingsVerify: SAPVerifyCurrentTrack(^(NSString *text){SAPDownloadMessage(text);});break;
        case SAPSettingsCancelDownload: SAPCancelTrackDownload();break;
        case SAPSettingsRefreshJournal: SAPJournalRefresh(@"settings");break;
        case SAPSettingsExportJournal: {
            dispatch_async(SAPReportQueue(),^{
                NSDictionary *report=SAPJournalReport();NSMutableArray *items=[NSMutableArray array];
                NSURL *table=SAPJournalWriteTableSnapshot(report);if(table)[items addObject:table];
                NSURL *json=SAPJournalWriteReportSnapshot(report);if(json)[items addObject:json];
                NSURL *log=[SAPDocuments() URLByAppendingPathComponent:report[@"log_file"]?:@"SpotifyAudioProbeJournal.log"];
                if([NSFileManager.defaultManager fileExistsAtPath:log.path])[items addObject:log];
                dispatch_async(dispatch_get_main_queue(),^{if(items.count)SAPShareItems(items);else SAPMessage(SAPL(@"Журнал пока пуст.",@"The log is empty."));});
            });break;
        }
        case SAPSettingsResetJournal: {
            UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"Reset log?" message:@"Clear the previous Pixie log?" preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"No" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){
                dispatch_async(SAPReportQueue(),^{
                    NSError *journalError=nil,*traceError=nil;
                    BOOL journalCleared=SAPJournalResetLogFiles(&journalError),traceCleared=SAPTraceReset(&traceError);
                    SAPPlayerTraceReset();if(SAPDiagnosticsEnabled())SAPPlayerTraceSetActive(YES);
                    dispatch_async(dispatch_get_main_queue(),^{
                        SAPTracePlatformSetActive(SAPDiagnosticsEnabled());
                        if(!journalCleared||!traceCleared){SAPMessage([NSString stringWithFormat:@"Log reset was not fully completed: %@",(journalError?:traceError).localizedDescription?:@"unknown file error"]);return;}
                        SAP_JOURNAL_ACTION(@"log_reset",@{@"previous_pixie_history_removed":@YES,@"diagnostics_enabled":@(SAPDiagnosticsEnabled())});
                        if(SAPDiagnosticsEnabled()){SAPTraceCaptureRuntimeManifest("manual_log_reset");SAPJournalRefresh(@"manual log reset");}
                        SAPMessage(SAPDiagnosticsEnabled()?@"Previous Pixie logs cleared. A fresh log is now recording.":@"Previous Pixie logs cleared. Diagnostics remains off; enable it to record a new log.");
                    });
                });
            }]];
            SAPPresent(confirm);break;
        }
        case SAPSettingsExportReport: {
            NSDictionary *native=[self diagnosticSnapshot];
            dispatch_async(SAPReportQueue(),^{
                NSDictionary *report=SAPCompleteDiagnosticSnapshot(native)[@"report"];
                NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
                NSURL *url=[SAPDocuments() URLByAppendingPathComponent:@"SpotifyAudioProbe.json"];
                BOOL saved=json && [json writeToURL:url atomically:YES];
                dispatch_async(dispatch_get_main_queue(),^{if(saved)SAPShare(url);else SAPMessage(SAPL(@"Не удалось сохранить отчёт.",@"Could not save the report."));});
            });break;
        }
        case SAPSettingsSendLog: {
            SAP_JOURNAL_ACTION(@"send_log_requested",@{@"diagnostics_enabled":@(SAPDiagnosticsEnabled())});
            NSDictionary *native=[self diagnosticSnapshot];
            SAPExportSupportLog(native,^(NSURL *url,NSError *error){
                if(url)SAPShare(url);else SAPMessage([NSString stringWithFormat:@"Could not save the support log: %@",error.localizedDescription?:@"unknown error"]);
            });break;
        }
    }
}
@end

