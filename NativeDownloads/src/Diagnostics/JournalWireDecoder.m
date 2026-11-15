#import "JournalPrivate.h"

// --- разбор трафика сервиса Offline --------------------------------------

NSArray *SAPJournalSubMessages(NSArray *fields, unsigned number) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] != number || [field[@"wire"] unsignedIntValue] != 2) continue;
        NSArray *parsed = SAPProtoFields(field[@"value"]);
        if (parsed) [result addObject:parsed];
        if (result.count >= maximumTracks) break;
    }
    return result;
}
NSArray *SAPJournalStringList(NSArray *fields, unsigned number) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] != number || [field[@"wire"] unsignedIntValue] != 2) continue;
        NSString *text = [[NSString alloc] initWithData:field[@"value"] encoding:NSUTF8StringEncoding];
        if (text.length) [result addObject:text];
        if (result.count >= maximumTracks) break;
    }
    return result;
}
static double floatField(NSArray *fields, unsigned number) {
    for (NSDictionary *field in fields.reverseObjectEnumerator) {
        if ([field[@"number"] unsignedIntValue] != number || [field[@"wire"] unsignedIntValue] != 5) continue;
        NSData *data = field[@"value"]; if (data.length != 4) continue;
        uint32_t bits = 0; memcpy(&bits, data.bytes, 4); float value = 0; memcpy(&value, &bits, 4);
        return isfinite(value) ? value : 0;
    }
    return 0;
}
// Progress: analysis/offline-esperanto-service.md
static NSDictionary *progressDictionary(NSArray *fields) {
    return @{@"queued_tracks": @(SAPProtoNumber(fields, 1, 0)), @"queued_bytes": @(SAPProtoNumber(fields, 2, 0)),
        @"downloaded_tracks": @(SAPProtoNumber(fields, 3, 0)), @"downloaded_bytes": @(SAPProtoNumber(fields, 4, 0)),
        @"total_tracks": @(SAPProtoNumber(fields, 5, 0)), @"total_bytes": @(SAPProtoNumber(fields, 6, 0)),
        @"downloading": @(SAPProtoNumber(fields, 7, 0) != 0), @"download_speed": @(SAPProtoNumber(fields, 8, 0)),
        @"percent_complete": @(round(floatField(fields, 9) * 10) / 10), @"seconds_left": @(SAPProtoNumber(fields, 10, 0)),
        @"track_totals_state": @(SAPProtoNumber(fields, 11, 0)), @"at": stamp(rightNow()) ?: @0};
}
static void readItems(NSArray *fields, unsigned number, NSString *source) {
    for (NSArray *item in SAPJournalSubMessages(fields, number)) {
        NSString *uri = SAPProtoString(item, 1);
        if (!uri.length) continue;
        SAPJournalApplyState(uri, (NSUInteger)SAPProtoNumber(item, 2, 0), (NSUInteger)SAPProtoNumber(item, 3, 0),
            (NSUInteger)SAPProtoNumber(item, 4, 0), YES, source);
    }
}
static void noteDownloadRequest(NSString *method, NSArray *request, NSString *source) {
    NSString *uri = SAPProtoString(request, 2);
    if (!uri.length) return;
    double moment = rightNow();
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    SAPTrack *record = SAPJournalRecordFor(uri);
    if ([method isEqual:@"AddDownload"]) { record->addRequests++; record->requestedAt = moment; }
    else record->removeRequests++;
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    NSLog(@"[SpotifyAudioProbe] %@ %@ (%@)", method, shortIdentifier(uri), source ?: @"");
    SAPJournalWriterLog(@"request", @"%@ %@ source=%@", method, shortIdentifier(uri), source ?: @"");
}
static void noteDownloadResponse(NSString *method, NSArray *request, NSArray *response) {
    NSString *uri = SAPProtoString(request, 2);
    uint64_t code = SAPProtoNumber(response, 1, 0);
    if (!uri.length) return;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    SAPTrack *record = SAPJournalRecordFor(uri);
    if ([method isEqual:@"AddDownload"]) record->requestError = @(code);
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    SAPJournalWriterLog(code ? @"rejected" : @"accepted", @"%@ %@ -> %@ (%llu)", method, shortIdentifier(uri), SAPJournalErrorName(code), (unsigned long long)code);
    if (code) NSLog(@"[SpotifyAudioProbe] %@ %@ rejected: %@ (%llu)", method, shortIdentifier(uri), SAPJournalErrorName(code), (unsigned long long)code);
}
static void noteContexts(NSArray *response, NSString *source) {
    for (NSArray *info in SAPJournalSubMessages(response, 1)) {
        NSArray *contexts = SAPJournalSubMessages(info, 1);
        NSArray *context = contexts.firstObject;
        NSString *uri = context ? SAPProtoString(context, 1) : nil;
        if (uri.length) {
            NSUInteger state = (NSUInteger)SAPProtoNumber(context, 2, 0);
            double percent = round(floatField(context, 3) * 10) / 10;
            os_unfair_lock_lock(&SAPJournalStateStorage.lock);
            NSMutableDictionary *entry = SAPJournalStateStorage.entities[uri];
            if (!entry) {
                if (SAPJournalStateStorage.entities.count >= maximumEntities) [SAPJournalStateStorage.entities removeAllObjects];
                entry = [NSMutableDictionary dictionary]; SAPJournalStateStorage.entities[uri] = entry;
            }
            NSString *previousState = entry[@"state"] ?: @"";
            double previousPercent = [entry[@"percent_complete"] doubleValue];
            entry[@"uri"] = uri; entry[@"state"] = contextStateName(state); entry[@"state_code"] = @(state);
            entry[@"percent_complete"] = @(percent); entry[@"updated_at"] = stamp(rightNow());
            BOOL interesting = ![previousState isEqual:contextStateName(state)] || fabs(previousPercent - percent) >= 1;
            os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
            if (interesting) SAPJournalWriterLog(@"context", @"%@ %@ %.1f%%", shortIdentifier(uri), contextStateName(state), percent);
        }
        readItems(info, 2, source);
    }
}
static void noteContextsProgress(NSArray *response) {
    for (NSArray *entry in SAPJournalSubMessages(response, 1)) {
        NSString *uri = SAPProtoString(entry, 1);
        NSArray *progress = SAPJournalSubMessages(entry, 2).firstObject;
        if (!uri.length || !progress) continue;
        NSDictionary *value = progressDictionary(progress);
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        NSMutableDictionary *stored = SAPJournalStateStorage.entities[uri];
        if (!stored) {
            if (SAPJournalStateStorage.entities.count >= maximumEntities) [SAPJournalStateStorage.entities removeAllObjects];
            stored = [NSMutableDictionary dictionary]; SAPJournalStateStorage.entities[uri] = stored;
        }
        NSMutableDictionary *previous=[stored[@"progress"] mutableCopy]; [previous removeObjectForKey:@"at"];
        NSMutableDictionary *comparable=[value mutableCopy]; [comparable removeObjectForKey:@"at"];
        BOOL changed=![previous isEqual:comparable];
        stored[@"uri"] = uri; stored[@"progress"] = value;
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        if(changed) SAPJournalWriterLog(@"queue", @"%@ %@/%@ tracks, %@/%@ bytes, %@ B/s, left %@s, downloading=%@",
            shortIdentifier(uri), value[@"downloaded_tracks"], value[@"total_tracks"],
            value[@"downloaded_bytes"], value[@"total_bytes"], value[@"download_speed"],
            value[@"seconds_left"], value[@"downloading"]);
    }
}
void SAPJournalDecodeCall(NSString *method, NSData *request, NSData *response, NSString *source) {
    if(!SAPDiagnosticsEnabled())return;
    NSArray *requestFields = request.length ? SAPProtoFields(request) : @[];
    NSArray *responseFields = response ? SAPProtoFields(response) : nil;
    os_unfair_lock_lock(&SAPJournalStateStorage.lock);
    SAPJournalStateStorage.methodCalls[method] = @([SAPJournalStateStorage.methodCalls[method] unsignedLongLongValue] + 1);
    os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
    if (!responseFields) { SAPJournalWriterLog(@"silent", @"%@ answered with no body (%@)", method, source ?: @""); return; }
    NSString *label = [NSString stringWithFormat:@"%@/%@", method, source ?: @"app"];
    if ([method isEqual:@"GetItems"] || [method isEqual:@"SubscribeItems"]) {
        if (requestFields.count) {
            NSArray *asked = SAPJournalStringList(requestFields, 1);
            os_unfair_lock_lock(&SAPJournalStateStorage.lock);
            for (NSString *uri in asked) SAPJournalRecordFor(uri);
            os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        }
        readItems(responseFields, 1, label);
    } else if ([method isEqual:@"GetContexts"] || [method isEqual:@"SubscribeContexts"]) {
        noteContexts(responseFields, label);
    } else if ([method isEqual:@"GetContextsProgress"] || [method isEqual:@"SubscribeContextsProgress"]) {
        noteContextsProgress(responseFields);
    } else if ([method isEqual:@"GetTotalProgress"] || [method isEqual:@"SubscribeTotalProgress"]) {
        NSArray *progress = SAPJournalSubMessages(responseFields, 1).firstObject;
        if (progress) {
            NSDictionary *value = progressDictionary(progress);
            BOOL changedTotal = NO;
            os_unfair_lock_lock(&SAPJournalStateStorage.lock);
            SAPJournalStateStorage.totalProgress = value;
            NSDictionary *previous = SAPJournalStateStorage.totalProgressSamples.lastObject;
            if (![previous[@"queued_tracks"] isEqual:value[@"queued_tracks"]] ||
                ![previous[@"downloaded_tracks"] isEqual:value[@"downloaded_tracks"]] ||
                ![previous[@"percent_complete"] isEqual:value[@"percent_complete"]]) {
                [SAPJournalStateStorage.totalProgressSamples addObject:value]; trimEvents(SAPJournalStateStorage.totalProgressSamples, maximumEvents);
                changedTotal = YES;
            }
            os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
            if (changedTotal) SAPJournalWriterLog(@"total", @"queued=%@ downloaded=%@/%@ bytes=%@/%@ speed=%@ left=%@s percent=%@ downloading=%@ totals=%@",
                value[@"queued_tracks"], value[@"downloaded_tracks"], value[@"total_tracks"],
                value[@"downloaded_bytes"], value[@"total_bytes"], value[@"download_speed"],
                value[@"seconds_left"], value[@"percent_complete"], value[@"downloading"], value[@"track_totals_state"]);
        }
    } else if ([method isEqual:@"AddDownload"] || [method isEqual:@"RemoveDownload"]) {
        noteDownloadRequest(method, requestFields, label);
        noteDownloadResponse(method, requestFields, responseFields);
    } else if ([method isEqual:@"SubscribeError"]) {
        uint64_t code = SAPProtoNumber(responseFields, 1, 0);
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        double seen = rightNow();
        SAPJournalStateStorage.snapshots[@"core_status"]=@{@"code":@(code), @"at":stamp(seen)?:@0};
        if(code) {
            [SAPJournalStateStorage.errorEvents addObject:@{@"code": @(code), @"name": SAPJournalErrorName(code), @"at": stamp(seen) ?: @0, @"absolute": @(seen)}];
            trimEvents(SAPJournalStateStorage.errorEvents, maximumEvents);
        }
        os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        if(code) SAPJournalWriterLog(@"core", @"error %@ (%llu) source=%@", SAPJournalErrorName(code), (unsigned long long)code, label);
    } else if ([method isEqual:@"SubscribeContextAdded"]) {
        NSString *uri = SAPProtoString(responseFields, 1);
        uint64_t reason = SAPProtoNumber(responseFields, 2, 0);
        if (uri.length) {
            os_unfair_lock_lock(&SAPJournalStateStorage.lock);
            [SAPJournalStateStorage.contextAddedEvents addObject:@{@"uri": uri, @"reason": reasonName(reason), @"at": stamp(rightNow()) ?: @0}];
            trimEvents(SAPJournalStateStorage.contextAddedEvents, maximumEvents);
            os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
            SAPJournalWriterLog(@"context", @"added %@ reason=%@", shortIdentifier(uri), reasonName(reason));
        }
    } else if ([method isEqual:@"LicenseStatus"]) {
        NSDictionary *value = @{@"max_licenses": @(SAPProtoNumber(responseFields, 1, 0)),
            @"free_licenses": @(SAPProtoNumber(responseFields, 2, 0)),
            @"error": @(SAPProtoNumber(responseFields, 3, 0)),
            @"error_name": SAPJournalErrorName(SAPProtoNumber(responseFields, 3, 0)), @"at": stamp(rightNow()) ?: @0};
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        BOOL changedLicense = ![SAPJournalStateStorage.snapshots[@"license_status"][@"free_licenses"] isEqual:value[@"free_licenses"]] ||
            ![SAPJournalStateStorage.snapshots[@"license_status"][@"max_licenses"] isEqual:value[@"max_licenses"]];
        SAPJournalStateStorage.snapshots[@"license_status"] = value; os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        if (changedLicense) SAPJournalWriterLog(@"license", @"free=%@ max=%@ error=%@", value[@"free_licenses"], value[@"max_licenses"], value[@"error_name"]);
    } else if ([method isEqual:@"BulkRedownloadPreflight"]) {
        NSDictionary *value = @{@"total_download_bytes": @(SAPProtoNumber(responseFields, 1, 0)),
            @"total_tracks": @(SAPProtoNumber(responseFields, 2, 0)),
            @"is_on_cellular": @(SAPProtoNumber(responseFields, 3, 0) != 0),
            @"sync_over_cellular_allowed": @(SAPProtoNumber(responseFields, 4, 0) != 0),
            @"has_sufficient_storage": @(SAPProtoNumber(responseFields, 5, 0) != 0),
            @"downloads_in_progress": @(SAPProtoNumber(responseFields, 6, 0)),
            @"current_downloaded_bytes": @(SAPProtoNumber(responseFields, 7, 0)), @"at": stamp(rightNow()) ?: @0};
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        BOOL changedPreflight = ![SAPJournalStateStorage.snapshots[@"bulk_preflight"][@"has_sufficient_storage"] isEqual:value[@"has_sufficient_storage"]] ||
            ![SAPJournalStateStorage.snapshots[@"bulk_preflight"][@"downloads_in_progress"] isEqual:value[@"downloads_in_progress"]] ||
            ![SAPJournalStateStorage.snapshots[@"bulk_preflight"][@"sync_over_cellular_allowed"] isEqual:value[@"sync_over_cellular_allowed"]];
        SAPJournalStateStorage.snapshots[@"bulk_preflight"] = value; os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        if (changedPreflight) SAPJournalWriterLog(@"storage", @"sufficient=%@ cellular=%@ cellular_allowed=%@ in_progress=%@ pending_bytes=%@",
            value[@"has_sufficient_storage"], value[@"is_on_cellular"], value[@"sync_over_cellular_allowed"],
            value[@"downloads_in_progress"], value[@"total_download_bytes"]);
    } else if ([method isEqual:@"GetOfflinePlaybackStatus"] || [method isEqual:@"SubscribeOfflinePlaybackStatus"]) {
        NSDictionary *value = @{@"allowed": @(SAPProtoNumber(responseFields, 1, 0) != 0),
            @"explicitly_enabled": @(SAPProtoNumber(responseFields, 2, 0) != 0),
            @"implicitly_enabled": @(SAPProtoNumber(responseFields, 3, 0) != 0), @"at": stamp(rightNow()) ?: @0};
        os_unfair_lock_lock(&SAPJournalStateStorage.lock);
        BOOL changedPlayback = ![SAPJournalStateStorage.snapshots[@"offline_playback"][@"allowed"] isEqual:value[@"allowed"]];
        SAPJournalStateStorage.snapshots[@"offline_playback"] = value; os_unfair_lock_unlock(&SAPJournalStateStorage.lock);
        if (changedPlayback) SAPJournalWriterLog(@"playback", @"allowed=%@ explicit=%@ implicit=%@",
            value[@"allowed"], value[@"explicitly_enabled"], value[@"implicitly_enabled"]);
    }
}
void SAPJournalObserveCall(NSString *method, NSData *request, NSData *response, NSString *source) {
    if(!SAPDiagnosticsEnabled())return;
    if (![method isKindOfClass:NSString.class] || method.length > 64) return;
    if (response && ![response isKindOfClass:NSData.class]) return;
    if(!SAPTraceRepeatedProgressPayload(@"observation",method,SAPTraceCurrentOperation(),response))
    SAP_TRACE("offline_observation","response_decoded_at_journal_boundary",SAPTraceCurrentOperation(),@{@"method":method,@"source":source?:@"unknown",
        @"response":SAPTraceWireSummary(@"spotify.offline_esperanto.proto.Offline",method,response,YES),@"rpc_parent_link":SAPTraceCurrentOperation()?@"callback_context":@"unavailable"});
    NSString *copiedMethod = [method copy], *copiedSource = [source copy];
    NSData *copiedRequest = [request isKindOfClass:NSData.class] && request.length <= 1048576 ? [request copy] : nil;
    NSData *copiedResponse = response.length <= 4 * 1024 * 1024 ? [response copy] : nil;
    SAPJournalOnQueue(^{
        if(!SAPDiagnosticsEnabled())return;
        @try { SAPJournalDecodeCall(copiedMethod, copiedRequest, copiedResponse, copiedSource); }
        @catch (NSException *exception) {
            NSLog(@"[SpotifyAudioProbe] journal decode failed for %@: %@", copiedMethod, exception.name);
            SAPJournalWriterLog(@"decode", @"%@ failed: %@", copiedMethod, exception.name);
        }
        SAPJournalEndSessionIfIdle();
    });
}

