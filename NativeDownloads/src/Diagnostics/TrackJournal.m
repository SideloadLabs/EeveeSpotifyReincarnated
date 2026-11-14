#import "JournalPrivate.h"

SAPJournalState SAPJournalStateStorage={.lock=OS_UNFAIR_LOCK_INIT,.journalKey=&SAPJournalStateStorage.journalKey};

NSString *SAPJournalItemStateName(NSUInteger state) {
    switch (state) {
        case 0: return @"not_downloaded"; case 1: return @"error"; case 2: return @"expired";
        case 3: return @"downloaded"; case 4: return @"awaiting_redownload"; case 5: return @"downloading";
        case 6: return @"waiting"; case 7: return @"waiting_limit_exceeded"; default: return @"unknown";
    }
}
@implementation SAPTrack @end

void SAPJournalSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SAPJournalStateStorage.journal = dispatch_queue_create("SpotifyAudioProbe.track-journal",
            dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        dispatch_queue_set_specific(SAPJournalStateStorage.journal, SAPJournalStateStorage.journalKey, SAPJournalStateStorage.journalKey, NULL);
        SAPJournalStateStorage.tracks = [NSMutableDictionary dictionary]; SAPJournalStateStorage.transitions = [NSMutableArray array];
        SAPJournalStateStorage.errorEvents = [NSMutableArray array]; SAPJournalStateStorage.contextAddedEvents = [NSMutableArray array];
        SAPJournalStateStorage.entityEvents = [NSMutableArray array]; SAPJournalStateStorage.entities = [NSMutableDictionary dictionary];
        SAPJournalStateStorage.snapshots = [NSMutableDictionary dictionary]; SAPJournalStateStorage.methodCalls = [NSMutableDictionary dictionary];
        SAPJournalStateStorage.totalProgressSamples = [NSMutableArray array]; SAPJournalStateStorage.sessionHistory = [NSMutableArray array];
        SAPJournalStateStorage.actionEvents = [NSMutableArray array];
        SAPJournalStateStorage.outstanding = [NSMutableDictionary dictionary]; SAPJournalStateStorage.unanswered = [NSMutableArray array];SAPJournalStateStorage.transportEvents=[NSMutableArray array];
        SAPJournalStateStorage.lifetimes = [NSMutableArray array]; SAPJournalStateStorage.journalStarted = rightNow();
        [NSNotificationCenter.defaultCenter addObserverForName:SAPDiagnosticsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note){SAPJournalDiagnosticsChanged();}];
    });
}
void SAPJournalOnQueue(void (^work)(void)) {
    SAPJournalSetup();SAPTraceID operation=SAPTraceCurrentOperation();uint64_t epoch=SAPTraceGeneration();
    dispatch_async(SAPJournalStateStorage.journal,^{SAPTraceWithOperation(epoch==SAPTraceGeneration()?operation:0,work);});
}
BOOL SAPJournalOnOwnQueue(void) { return dispatch_get_specific(SAPJournalStateStorage.journalKey) != NULL; }


// --- постоянный журнал на диске ------------------------------------------
// Всё, что видит журнал, пишется строкой в Documents/SpotifyAudioProbeJournal.log.
// Файл переживает перезапуск приложения: отчёт показывает текущее состояние,
// а лог — весь путь каждого трека, включая то, что было до перезапуска.

#import "JournalStorage.h"
#import "JournalNames.h"
static NSString *uiStatusName(NSInteger status);
void SAPJournalNoteAction(NSString *name,NSDictionary *facts) {
    if(!SAPDiagnosticsEnabled())return;
    if(![name isKindOfClass:NSString.class] || !name.length || name.length>80 ||
       ![facts isKindOfClass:NSDictionary.class])return;
    NSString *eventName=[name copy];NSDictionary *values=[facts copy];
    // Preserve the observation time before this event reaches the journal queue.
    SAP_TRACE("pixie_action",name.UTF8String,SAPTraceCurrentOperation(),values);
    uint64_t epoch=SAPTraceGeneration();
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled()||epoch!=SAPTraceGeneration())return;
        NSDictionary *entry=@{@"at":stamp(rightNow())?:@0,@"event":eventName,@"facts":values};
        NSData *line=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:NULL];
        if(!line)return;
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);[SAPJournalStateStorage.actionEvents addObject:entry];trimEvents(SAPJournalStateStorage.actionEvents,200);os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalWriterAppendActionData(line);
    });
}
void SAPJournalFlushActions(void) {
    SAPJournalSetup();if(!SAPJournalOnOwnQueue())dispatch_sync(SAPJournalStateStorage.journal, ^{SAPJournalWriterFlushActions();});
}

// --- учёт состояний -------------------------------------------------------

SAPTrack *SAPJournalRecordFor(NSString *uri) { // вызывать под stateLock
    SAPTrack *record = SAPJournalStateStorage.tracks[uri];
    if (record) return record;
    if (SAPJournalStateStorage.tracks.count >= maximumTracks) {
        NSArray *oldest = [SAPJournalStateStorage.tracks.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPTrack *a, SAPTrack *b) {
            return a->lastSeen < b->lastSeen ? NSOrderedAscending : a->lastSeen > b->lastSeen ? NSOrderedDescending : NSOrderedSame;
        }];
        for (NSUInteger i = 0; i < oldest.count / 10 + 1; i++) [SAPJournalStateStorage.tracks removeObjectForKey:((SAPTrack *)oldest[i])->uri];
    }
    record = [SAPTrack new];
    record->uri = [uri copy]; record->firstSeen = rightNow(); record->uiStatus = -1; record->legacyState = -1;
    record->history = [NSMutableArray array]; record->errors = [NSMutableArray array];
    record->nativeEvents = [NSMutableArray array];
    record->timeInState = [NSMutableDictionary dictionary];
    SAPJournalStateStorage.tracks[uri] = record;
    return record;
}
static void traceComparison(SAPTrack *record) {
    if(!SAPTraceIsActive())return;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    NSDictionary *facts=@{@"uri":record->uri,@"wire_observed":@(record->seen),@"wire_state":@(record->state),
        @"wire_journal_decoded_at":stamp(record->wireAt)?:NSNull.null,@"wire_source":record->lastSource?:@"unavailable",
        @"icon_observed":@(record->uiStatus>=0),@"icon_status":@(record->uiStatus),@"icon_captured_at":stamp(record->iconAt)?:NSNull.null,
        @"downloaded_states_agree":record->seen&&record->uiStatus>=0?@((record->state==3)==(record->uiStatus==3)):NSNull.null,
        @"correlation":@"same URI, independent observations; not a simultaneous snapshot",@"file_verified":@NO};
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    SAP_TRACE("comparison","wire_and_icon",SAPTraceCurrentOperation(),facts);
}

void SAPJournalApplyState(NSString *uri, NSUInteger state, NSUInteger videoState, NSUInteger progress, BOOL hasProgress, NSString *source) {
    if (![uri isKindOfClass:NSString.class] || !uri.length || uri.length > 256) return;
    double moment = rightNow();
    NSString *logLine = nil, *progressLine = nil, *errorLine = nil;
    BOOL startSession = NO;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    SAPTrack *record = SAPJournalRecordFor(uri);
    record->observations++; record->lastSeen = moment; record->lastSource = source;
    record->videoState = videoState; record->wireAt = moment;
    BOOL changed = !record->seen || record->state != state;
    if (changed) {
        NSString *from = record->seen ? SAPJournalItemStateName(record->state) : @"unseen";
        double held = record->seen && record->enteredState > 0 ? moment - record->enteredState : 0;
        if (held > 0) {
            NSNumber *spent = record->timeInState[from];
            record->timeInState[from] = @(round((spent.doubleValue + held) * 10) / 10);
        }
        record->state = state; record->seen = YES; record->enteredState = moment; record->lastChange = moment;
        NSDictionary *entry = @{@"track_uri": uri, @"from": from, @"to": SAPJournalItemStateName(state),
            @"progress": @(progress), @"at": stamp(moment) ?: @0, @"source": source ?: @""};
        [record->history addObject:entry];
        while (record->history.count > maximumTrackTransitions) [record->history removeObjectAtIndex:0];
        [SAPJournalStateStorage.transitions addObject:entry]; trimEvents(SAPJournalStateStorage.transitions, maximumTransitions);
        logLine = [NSString stringWithFormat:@"%@ %@ -> %@ %lu%% held=%@ source=%@ obs=%lu",
            shortIdentifier(uri), from, SAPJournalItemStateName(state), (unsigned long)progress,
            held > 0 ? [NSString stringWithFormat:@"%.1fs", held] : @"-", source ?: @"", (unsigned long)record->observations];
        // Error ядра приходит без URI, поэтому ошибку привязываем по времени и помечаем correlated.
        if (failedState(state)) {
            NSDictionary *recent = SAPJournalStateStorage.errorEvents.lastObject;
            double errorAge = recent ? moment - [recent[@"absolute"] doubleValue] : -1;
            NSMutableDictionary *failure = [@{@"at": stamp(moment) ?: @0, @"state": SAPJournalItemStateName(state),
                @"progress": @(record->progress), @"previous_state": from,
                @"attempts": @(record->addRequests)} mutableCopy];
            if (record->requestError) {
                failure[@"add_response"] = record->requestError;
                failure[@"add_response_name"] = SAPJournalErrorName(record->requestError.unsignedLongLongValue);
            }
            if ([recent[@"code"] unsignedLongLongValue] && errorAge >= -0.01 && errorAge <= 15) {
                failure[@"core_error"] = recent[@"code"]; failure[@"core_error_name"] = recent[@"name"];
                failure[@"core_error_age_seconds"] = @(MAX(0, round(errorAge * 10) / 10));
                failure[@"correlated"] = @YES;
            }
            [record->errors addObject:failure];
            while (record->errors.count > 8) [record->errors removeObjectAtIndex:0];
            errorLine = [NSString stringWithFormat:@"%@ %@ after %@ at %lu%%%@%@", shortIdentifier(uri),
                SAPJournalItemStateName(state), from, (unsigned long)record->progress,
                failure[@"core_error_name"] ? [NSString stringWithFormat:@" core=%@(%@) %@s ago", failure[@"core_error_name"], failure[@"core_error"], failure[@"core_error_age_seconds"]] : @"",
                failure[@"add_response_name"] ? [NSString stringWithFormat:@" add=%@", failure[@"add_response_name"]] : @""];
        }
        startSession = pendingState(state) && !SAPJournalStateStorage.session;
    }
    if (hasProgress && progress != record->progress) {
        NSUInteger previous = record->progress;
        record->progress = progress; record->lastProgressAt = moment;
        if (progress > record->maxProgress) record->maxProgress = progress;
        progressLine = [NSString stringWithFormat:@"%@ %@ %lu%% -> %lu%% source=%@", shortIdentifier(uri),
            SAPJournalItemStateName(record->state), (unsigned long)previous, (unsigned long)progress, source ?: @""];
    }
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    if (logLine) { NSLog(@"[SpotifyAudioProbe] state %@", logLine); SAPJournalWriterWrite(@"state", logLine); }
    if(changed && state==3 && record->nativeError)
        SAPJournalWriterLog(@"recovered",@"%@ downloaded after previous native error %@; historical error does not override current state",uri,record->nativeError[@"name"]);
    if (errorLine) { NSLog(@"[SpotifyAudioProbe] FAILED %@", errorLine); SAPJournalWriterWrite(@"failed", errorLine); }
    if (progressLine) SAPJournalWriterWrite(@"progress", progressLine);
    if(logLine && record->uiStatus>=0)
        SAPJournalWriterLog(@"compare",@"%@ wire=%@ icon=%@ legacy=%@",shortIdentifier(uri),SAPJournalItemStateName(state),
            uiStatusName(record->uiStatus),record->legacyState>=0?uiStatusName(record->legacyState):@"unseen");
    if((logLine||progressLine)&&record->uiStatus>=0)traceComparison(record);
    if (startSession) SAPJournalBeginSession(@"item_state", nil);
}
// Статус значка, который реально рисует строка плейлиста
// (SPTFreeTierOfflineStatusUpdatingContentOperation.offlineSyncStatusForURL:).
void SAPJournalNoteUIStatus(NSString *uri, NSInteger status) {
    if(!SAPDiagnosticsEnabled())return;
    if (![uri isKindOfClass:NSString.class] || !uri.length || uri.length > 256) return;
    SAP_TRACE("ui","download_icon_observed",SAPTraceCurrentOperation(),@{@"uri":uri,@"status":@(status),@"state_domain":@"GLUEOfflineSyncStatus",@"file_or_audio_verified":@NO});
    NSString *copied = [uri copy];double capturedAt=rightNow();
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        NSString *line = nil;
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        SAPTrack *record = SAPJournalRecordFor(copied);
        if (record->uiStatus != status) {
            NSString *from = record->uiStatus >= 0 ? uiStatusName(record->uiStatus) : @"unseen";
            record->uiStatus = status;
            line = [NSString stringWithFormat:@"%@ icon %@ -> %@ (state %@)", shortIdentifier(copied), from,
                uiStatusName(status), record->seen ? SAPJournalItemStateName(record->state) : @"unseen"];
        }
        record->iconAt=capturedAt;
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        if(line)traceComparison(record);
        if (line) { SAPJournalWriterWrite(@"icon", line); SAPJournalRequestReconciliation(copied); }
    });
}

void SAPJournalNoteRowState(NSString *uri, NSUInteger state) {
    if(!SAPDiagnosticsEnabled())return;
    if (![uri isKindOfClass:NSString.class] || !uri.length) return;
    SAP_TRACE("ui","row_state_observed",SAPTraceCurrentOperation(),@{@"uri":uri,@"state":@(state),@"state_domain":@"GLUEOfflineSyncStatus"});
    NSString *copied = [uri copy];
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        SAPTrack *record=SAPJournalRecordFor(copied); record->rowQueries++;
        BOOL changed=record->legacyState!=(NSInteger)state;
        record->legacyState=(NSInteger)state; record->legacyAt=rightNow();
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        // This API uses GLUEOfflineSyncStatus (0..4), not protobuf Item.State (0..7).
        // A row observation must never overwrite the authoritative wire state.
        if(changed) {
            SAPJournalWriterLog(@"row", @"%@ legacy=%@", shortIdentifier(copied), uiStatusName((NSInteger)state));
            SAPJournalRequestReconciliation(copied);
        }
    });
}
void SAPJournalNoteNativeError(NSString *uri,NSNumber *code,NSString *name) {
    if(!SAPDiagnosticsEnabled())return;
    if(![uri hasPrefix:@"spotify:track:"] || uri.length!=36 || !name.length)return;
    SAP_TRACE("native_log","track_error",SAPTraceCurrentOperation(),@{@"uri":uri,@"name":name,@"code_present_in_line":code?:NSNull.null,@"source":@"native_log_exact_uri",@"server_rejection_reason_proven":@NO});
    double moment=rightNow();
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);SAPTrack *record=SAPJournalRecordFor(uri);
        NSMutableDictionary *error=[@{@"name":name,@"uri":uri,@"at":@(moment+kCFAbsoluteTimeIntervalSince1970),@"source":@"native_log_exact_uri"} mutableCopy];
        if(code)error[@"code"]=code;
        else if([record->nativeError[@"code"] integerValue]==7004 && [name isEqual:@"key_denied"])error[@"code"]=@7004;
        error[@"code_present_in_this_line"]=code?:NSNull.null;
        error[@"code_copied_from_previous_record"]=@(!code&&error[@"code"]!=nil);
        record->nativeError=[error copy];
        [record->nativeEvents addObject:record->nativeError];trimEvents(record->nativeEvents,12);
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalWriterLog(@"native_error",@"%@ %@ code=%@",uri,name,code?:@"not present in this line");
    });
}
void SAPJournalNoteNativeSuccess(NSString *uri,NSString *event) {
    if(!SAPDiagnosticsEnabled())return;
    if(![uri hasPrefix:@"spotify:track:"] || uri.length!=36 ||
       (![event isEqual:@"key_received"] && ![event isEqual:@"downloaded"]))return;
    SAP_TRACE("native_log",event.UTF8String,SAPTraceCurrentOperation(),@{@"uri":uri,@"source":@"native_log_exact_uri",@"native_request_link":@"not_proven_by_this_log_line",@"audio_playback_tested":@NO});
    double moment=rightNow();
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);SAPTrack *record=SAPJournalRecordFor(uri);
        if([event isEqual:@"key_received"])record->nativeKeyAt=moment;else record->nativeDownloadAt=moment;
        NSDictionary *value=@{@"name":event,@"uri":uri,@"at":@(moment+kCFAbsoluteTimeIntervalSince1970),@"source":@"native_log_exact_uri"};
        [record->nativeEvents addObject:value];trimEvents(record->nativeEvents,12);
        NSDictionary *priorError=record->nativeError;os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalWriterLog(@"native_success",@"%@ %@ previous_error=%@",uri,event,priorError[@"name"]?:@"none observed");
    });
}
NSDictionary *SAPJournalNativeErrorForURI(NSString *uri) {
    if(!SAPDiagnosticsEnabled())return nil;
    SAPJournalSetup();os_unfair_lock_lock(&SAPJournalStateStorage.lock);SAPTrack *record=SAPJournalStateStorage.tracks[uri];NSDictionary *error=record?record->nativeError:nil;os_unfair_lock_unlock(&SAPJournalStateStorage.lock);return error;
}
void SAPJournalNoteQuota(NSDictionary *quota) {
    if(!SAPDiagnosticsEnabled())return;
    if (![quota isKindOfClass:NSDictionary.class]) return;
    SAP_TRACE("queue","native_manager_snapshot",SAPTraceCurrentOperation(),quota);
    NSDictionary *copied = [quota copy];
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        NSMutableDictionary *value = [copied mutableCopy];
        value[@"at"] = stamp(rightNow());
        os_unfair_lock_lock(&SAPJournalStateStorage.lock); SAPJournalStateStorage.snapshots[@"quota"] = value; os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalWriterLog(@"quota", @"tracks %@/%@ episodes %@/%@ duration %@s local_prepared=%@ online=%@ connection_allows=%@ license_expired=%@ sync_level=%@ allow_tracks=%@ reason=%@",
            copied[@"current_tracks"] ?: @"?", copied[@"music_limit"] ?: @"?",
            copied[@"current_episodes"] ?: @"?", copied[@"episode_limit"] ?: @"?",
            copied[@"music_duration_seconds"] ?: @"?", copied[@"local_prepared"] ?: @"?",
            copied[@"online"] ?: @"?", copied[@"connection_allows_offlining"] ?: @"?",
            copied[@"track_license_expired"] ?: @"?", copied[@"sync_level"] ?: @"?",
            copied[@"allow_spotify_tracks"] ?: @"?", copied[@"reason"] ?: @"");
    });
}
void SAPJournalNoteEntityReset(NSString *entity) {
    if(!SAPDiagnosticsEnabled())return;
    if (![entity isKindOfClass:NSString.class] || !entity.length) return;
    NSString *copied = [entity copy];
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        [SAPJournalStateStorage.entityEvents addObject:@{@"entity": copied, @"action": @"reset", @"at": stamp(rightNow()) ?: @0}];
        trimEvents(SAPJournalStateStorage.entityEvents, maximumEvents);
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        NSLog(@"[SpotifyAudioProbe] offline reset requested for %@", copied);
        SAPJournalWriterLog(@"entity", @"reset %@", copied);
    });
}
void SAPJournalNoteEntityRequest(NSString *entity, NSArray *trackURLs) {
    if(!SAPDiagnosticsEnabled())return;
    if (![entity isKindOfClass:NSString.class] || !entity.length) return;
    NSString *copiedEntity = [entity copy];
    NSMutableArray *uris = [NSMutableArray array];
    if ([trackURLs isKindOfClass:NSArray.class]) for (id value in trackURLs) {
        NSString *text = [value isKindOfClass:NSURL.class] ? [value absoluteString] : [value isKindOfClass:NSString.class] ? value : nil;
        if (text.length && text.length <= 256) [uris addObject:text];
        if (uris.count >= maximumTracks) break;
    }
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        double moment = rightNow();
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        for (NSString *uri in uris) {
            SAPTrack *record = SAPJournalRecordFor(uri);
            if (!record->entity) record->entity = copiedEntity;
            if (!record->requestedAt) record->requestedAt = moment;
        }
        NSMutableDictionary *entry = SAPJournalStateStorage.entities[copiedEntity];
        if (!entry) {
            if (SAPJournalStateStorage.entities.count >= maximumEntities) [SAPJournalStateStorage.entities removeAllObjects];
            entry = [NSMutableDictionary dictionary]; SAPJournalStateStorage.entities[copiedEntity] = entry;
        }
        entry[@"uri"] = copiedEntity; entry[@"requested_at"] = stamp(moment);
        entry[@"requested_tracks"] = @(uris.count);
        [SAPJournalStateStorage.entityEvents addObject:@{@"entity": copiedEntity, @"action": @"download", @"tracks": @(uris.count), @"at": stamp(moment) ?: @0}];
        trimEvents(SAPJournalStateStorage.entityEvents, maximumEvents);
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        NSLog(@"[SpotifyAudioProbe] offline download requested for %@ with %lu tracks", copiedEntity, (unsigned long)uris.count);
        SAPJournalWriterLog(@"entity", @"download %@ tracks=%lu", copiedEntity, (unsigned long)uris.count);
        SAPJournalBeginSession(@"entity_download", copiedEntity);
    });
}

NSDictionary *SAPJournalStateCountsLocked(NSUInteger *pendingOut) { // под stateLock
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSUInteger pending = 0;
    for (SAPTrack *record in SAPJournalStateStorage.tracks.allValues) {
        NSString *name = record->seen ? SAPJournalItemStateName(record->state) : @"unseen";
        counts[name] = @([counts[name] unsignedIntegerValue] + 1);
        if (record->seen && pendingState(record->state)) pending++;
    }
    if (pendingOut) *pendingOut = pending;
    return counts;
}
static void resetJournalState(void) {
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        [SAPJournalStateStorage.tracks removeAllObjects]; [SAPJournalStateStorage.transitions removeAllObjects]; [SAPJournalStateStorage.errorEvents removeAllObjects];
        [SAPJournalStateStorage.contextAddedEvents removeAllObjects]; [SAPJournalStateStorage.entityEvents removeAllObjects]; [SAPJournalStateStorage.entities removeAllObjects];
        [SAPJournalStateStorage.snapshots removeAllObjects]; [SAPJournalStateStorage.methodCalls removeAllObjects]; [SAPJournalStateStorage.totalProgressSamples removeAllObjects];
        [SAPJournalStateStorage.sessionHistory removeAllObjects]; [SAPJournalStateStorage.unanswered removeAllObjects];[SAPJournalStateStorage.transportEvents removeAllObjects];SAPJournalStateStorage.focusedURI=nil;
        SAPJournalStateStorage.totalProgress = nil; SAPJournalStateStorage.journalStarted = rightNow();
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        SAPJournalStateStorage.session = nil; SAPJournalStateStorage.pollTicks = 0;SAPJournalStateStorage.lastQuotaSample=0; SAPJournalStopPolling(); SAPJournalCancelLifetimes();[SAPJournalStateStorage.reconciliationTimes removeAllObjects];
        SAPPlayerTraceReset();
        if(SAPTraceIsActive())SAPPlayerTraceSetActive(YES);
        if(SAPDiagnosticsEnabled())NSLog(@"[SpotifyAudioProbe] journal reset");
        SAPJournalWriterWrite(@"reset", @"journal cleared by user");
}
void SAPJournalReset(void) {SAPJournalOnQueue(^{resetJournalState();});}
BOOL SAPJournalResetLogFiles(NSError **error) {
    SAPJournalSetup();__block NSError *failure=nil;
    dispatch_block_t clear=^{
        resetJournalState();
        SAPJournalWriterClose(YES);
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);[SAPJournalStateStorage.actionEvents removeAllObjects];os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        for(NSString *name in @[@"SpotifyAudioProbeJournal.log",@"SpotifyAudioProbeJournal.1.log",@"PixieActions.log",@"PixieActions.1.log",
            @"PixieSupportLog.json",@"SpotifyAudioProbe.json",@"SpotifyAudioProbeTracks.json",@"SpotifyAudioProbeTracks.txt"]) {
            NSURL *url=SAPJournalDocumentsURL(name);NSError *e=nil;
            if([NSFileManager.defaultManager fileExistsAtPath:url.path]&&![NSFileManager.defaultManager removeItemAtURL:url error:&e]&&!failure)failure=e;
        }
        SAPJournalStateStorage.lastRefresh=0;SAPJournalStateStorage.lastQuotaSample=0;
    };
    if(SAPJournalOnOwnQueue())clear();else dispatch_sync(SAPJournalStateStorage.journal,clear);
    if(error)*error=failure;return failure==nil;
}

// --- отчёты ---------------------------------------------------------------

static NSString *uiStatusName(NSInteger status) {
    switch (status) {
        case 0: return @"not_synced"; case 1: return @"pending"; case 2: return @"in_progress";
        case 3: return @"synced"; case 4: return @"failed"; default: return @"unknown";
    }
}
// Порядок в отчёте: сначала то, что сломалось, потом то, что висит, потом остальное.
static NSUInteger priorityOf(SAPTrack *record) {
    if (!record->seen) return 3;
    if (failedState(record->state)) return 0;
    if (record->state == 0 || record->state == 2) return 1;
    if (pendingState(record->state)) return 2;
    return 4;
}
NSDictionary *SAPJournalTrackDictionary(SAPTrack *record, double moment) { // под stateLock
    NSString *state = record->seen ? SAPJournalItemStateName(record->state) : @"unseen";
    double inState = record->enteredState > 0 ? moment - record->enteredState : 0;
    BOOL stalled = record->seen && pendingState(record->state) &&
        (record->lastProgressAt > 0 ? moment - record->lastProgressAt : inState) > stalledAfter;
    NSMutableDictionary *value = [@{
        @"uri": record->uri ?: @"", @"id": shortIdentifier(record->uri) ?: @"",
        @"state": state, @"state_code": @(record->state), @"progress": @(record->progress),
        @"max_progress": @(record->maxProgress), @"in_state_seconds": @(round(inState)),
        @"stalled": @(stalled), @"observations": @(record->observations), @"row_queries": @(record->rowQueries),
        @"add_requests": @(record->addRequests), @"remove_requests": @(record->removeRequests),
        @"transitions": [record->history copy], @"time_in_state": [record->timeInState copy],
        @"source": record->lastSource ?: @""} mutableCopy];
    if (record->videoState) value[@"video_state"] = SAPJournalItemStateName(record->videoState);
    if (record->entity) value[@"entity"] = record->entity;
    if (record->requestError) {
        value[@"add_response"] = record->requestError;
        value[@"add_response_name"] = SAPJournalErrorName(record->requestError.unsignedLongLongValue);
    }
    if (record->requestedAt) value[@"requested_age_seconds"] = age(record->requestedAt) ?: @0;
    if (record->firstSeen) value[@"first_seen_age_seconds"] = age(record->firstSeen) ?: @0;
    if (record->lastChange) value[@"last_change_age_seconds"] = age(record->lastChange) ?: @0;
    if (record->lastProgressAt) value[@"last_progress_age_seconds"] = age(record->lastProgressAt) ?: @0;
    if(record->legacyState>=0) {
        value[@"legacy_state_code"]=@(record->legacyState);value[@"legacy_state"]=uiStatusName(record->legacyState);
        value[@"legacy_age_seconds"]=age(record->legacyAt)?:@0;
    }
    if(record->wireAt)value[@"wire_age_seconds"]=age(record->wireAt)?:@0;
    if(record->uiStatus>=0 && record->seen) {
        value[@"ui_downloaded_matches_wire"]=@((record->uiStatus==3)==(record->state==3));
        value[@"comparison_note"]=@"UI and wire are timestamped observations, not an atomic snapshot";
    }
    if (record->uiStatus >= 0) {
        value[@"ui_status"] = uiStatusName(record->uiStatus);
        value[@"ui_status_code"] = @(record->uiStatus);value[@"ui_age_seconds"]=age(record->iconAt)?:@0;
    }
    if(record->nativeError) {
        value[@"native_error"]=record->nativeError;
        double errorAt=[record->nativeError[@"at"] doubleValue]-kCFAbsoluteTimeIntervalSince1970;
        value[@"key_received_after_native_error"]=@(record->nativeKeyAt>errorAt);
        value[@"downloaded_after_native_error"]=@((record->state==3 && record->wireAt>errorAt) || record->nativeDownloadAt>errorAt);
    }
    if(record->nativeEvents.count)value[@"native_events"]=[record->nativeEvents copy];
    if (record->errors.count) value[@"errors"] = [record->errors copy];
    return value;
}
NSDictionary *SAPJournalReport(void) {
    SAPJournalSetup();
    double moment = rightNow();
    NSUInteger pending = 0;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    NSDictionary *counts = SAPJournalStateCountsLocked(&pending);
    NSArray *sorted = [SAPJournalStateStorage.tracks.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPTrack *a, SAPTrack *b) {
        NSUInteger left = priorityOf(a), right = priorityOf(b);
        if (left != right) return left < right ? NSOrderedAscending : NSOrderedDescending;
        return a->lastChange > b->lastChange ? NSOrderedAscending : a->lastChange < b->lastChange ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray *list = [NSMutableArray array];
    NSMutableArray *stalled = [NSMutableArray array];
    NSUInteger requested = 0, withAddError = 0;
    for (SAPTrack *record in sorted) {
        if (record->requestedAt) requested++;
        if (record->requestError.unsignedLongLongValue) withAddError++;
        if (list.count >= maximumReportedTracks) continue;
        NSDictionary *value = SAPJournalTrackDictionary(record, moment);
        [list addObject:value];
        if ([value[@"stalled"] boolValue] && stalled.count < 40) [stalled addObject:value[@"uri"]];
    }
    NSDictionary *report = @{
        @"native_error_observer":SAPNativeErrorLogReport(),
        @"player_trace":SAPPlayerTraceReport(),
        @"player_trace_sink_dropped":@(atomic_load(&SAPJournalStateStorage.playerTraceSinkDropped)),
        @"diagnostics_enabled":@(SAPDiagnosticsEnabled()),
        @"journal_version": @6,@"focused_uri":SAPJournalStateStorage.focusedURI?:@"",@"transport_events":[SAPJournalStateStorage.transportEvents copy],
        @"action_events":[SAPJournalStateStorage.actionEvents copy],@"action_log_file":@"PixieActions.log",
        @"generated_at": stamp(moment) ?: @0,
        @"journal_age_seconds": @(round(moment - SAPJournalStateStorage.journalStarted)),
        @"caller_available": @(atomic_load(&SAPJournalStateStorage.callerAvailable)), @"subscribed": @(SAPJournalStateStorage.subscribed),
        @"tracked_tracks": @(SAPJournalStateStorage.tracks.count), @"reported_tracks": @(list.count),
        @"requested_tracks": @(requested), @"add_errors": @(withAddError),
        @"requested_tracks_scope":@"Unique tracks with an observed entity request or AddDownload in this journal; native synchronization can also occur without these observations",
        @"pending_tracks": @(pending), @"state_counts": counts,
        @"session": SAPJournalStateStorage.session ? [SAPJournalStateStorage.session copy] : @{}, @"session_history": [SAPJournalStateStorage.sessionHistory copy],
        @"entities": [[NSDictionary alloc] initWithDictionary:SAPJournalStateStorage.entities copyItems:YES], @"entity_events": [SAPJournalStateStorage.entityEvents copy],
        @"total_progress": SAPJournalStateStorage.totalProgress ?: @{}, @"total_progress_samples": [SAPJournalStateStorage.totalProgressSamples copy],
        @"snapshots": [SAPJournalStateStorage.snapshots copy], @"core_errors": [SAPJournalStateStorage.errorEvents copy],
        @"context_added": [SAPJournalStateStorage.contextAddedEvents copy], @"method_calls": [SAPJournalStateStorage.methodCalls copy],
        @"stalled_tracks": stalled, @"recent_transitions": [SAPJournalStateStorage.transitions copy],
        @"unanswered_calls": [SAPJournalStateStorage.unanswered copy], @"outstanding_calls": [[SAPJournalStateStorage.outstanding allKeys] copy],
        @"log_file": @"SpotifyAudioProbeJournal.log",
        @"tracks": list,
        @"note": SAPL(@"Error ядра офлайна не содержит URI (Error{code} — analysis/offline-esperanto-service.md), "
                 @"поэтому ошибка привязывается к треку по времени и помечается как correlated.",
                 @"Offline core errors contain no URI (Error{code}; see analysis/offline-esperanto-service.md), so errors are associated with tracks by timestamp and marked as correlated.")
    };
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    return report;
}
#ifdef SAP_TESTING
void SAPJournalDrainForTesting(void) { SAPJournalSetup(); dispatch_sync(SAPJournalStateStorage.journal, ^{}); }
#endif
