#import "DownloadCompatibility.h"
#import "NativeOffline.h"
#import "TrackDownload.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#import <os/lock.h>

static os_unfair_lock compatibilityLock=OS_UNFAIR_LOCK_INIT;
static NSDictionary *latestCompatibility;
static NSMutableArray *waiting;
static NSMutableDictionary *currentRead;
static dispatch_source_t deadline;
static NSUInteger remaining;
static SAPTraceID traceOperation;
static NSString *const offlineService=@"spotify.offline_esperanto.proto.Offline";
static NSDictionary *deviceFields(NSArray *fields) {
    NSString *identifier=SAPProtoString(fields,1),*cache=SAPProtoString(fields,2);
    if(!identifier.length||!cache.length||identifier.length>512||cache.length>512)return nil;
    return @{@"device_id":SAPProtoString(fields,1)?:@"",@"cache_id":SAPProtoString(fields,2)?:@"",
        @"name":SAPProtoString(fields,3)?:@"",@"type":@(SAPProtoNumber(fields,4,0)),
        @"platform":@(SAPProtoNumber(fields,5,0)),@"is_local":@(SAPProtoNumber(fields,7,0)!=0),
        @"offline_enabled":@(SAPProtoNumber(fields,10,0)!=0)};
}

NSDictionary *SAPDownloadCompatibilityReport(void) {
    os_unfair_lock_lock(&compatibilityLock);NSDictionary *value=latestCompatibility;os_unfair_lock_unlock(&compatibilityLock);
    return value?:@{@"status":@"not_checked",@"detail":@"No explicit quota and license check has completed this launch."};
}
NSString *SAPModeChangeBlockReason(NSDictionary *report) {
    if(![report[@"status"]isEqual:@"complete"])return @"The quota and license check is incomplete. Mode was not changed.";
    double age=NSDate.date.timeIntervalSince1970-[report[@"finished_at"]doubleValue];
    if(age<0 || age>10)return @"The quota and license check is stale. Refresh it before changing mode.";
    NSDictionary *sources=report[@"sources"],*license=sources[@"licenses"],*playback=sources[@"playback"],*native=sources[@"native"],*preflight=sources[@"preflight"];
    if([license[@"error"]unsignedLongLongValue])return [NSString stringWithFormat:@"LicenseStatus returned error %@. Mode was not changed.",license[@"error"]];
    if([license[@"max_licenses"]longLongValue]<=0 || [license[@"free_licenses"]longLongValue]<0 ||
       [license[@"free_licenses"]longLongValue]>[license[@"max_licenses"]longLongValue])return @"Spotify did not report a usable device-license quota. Mode was not changed.";
    if([license[@"free_licenses"]unsignedLongLongValue]==0)return @"Spotify reports 0 free device-license slots. Mode was not changed. This response does not identify where the slots are registered or whether this device already has a valid license.";
    if(![playback[@"allowed"]boolValue])return @"Spotify currently reports offline playback as not allowed. Mode was not changed.";
    if(![preflight[@"has_sufficient_storage"]boolValue] || [native[@"disk_full"]boolValue])return @"The storage check does not confirm enough space. Mode was not changed.";
    if([preflight[@"downloads_in_progress"]unsignedLongLongValue] || SAPTrackDownloadActive())return @"A download is active. Stop it before changing mode.";
    if([native[@"music_limit"]longLongValue]<=[native[@"current_tracks"]longLongValue])return @"The observed local track quota has no free capacity. Mode was not changed.";
    if(![native[@"online"]boolValue] || ![native[@"connection_allows_offlining"]boolValue])return @"The native manager does not currently allow offline downloads on this connection. Mode was not changed.";
    return nil;
}
NSString *SAPDownloadCompatibilityText(NSDictionary *report) {
    if(![report[@"status"]isEqual:@"complete"] && ![report[@"status"]isEqual:@"partial"])
        return report[@"detail"]?:@"Not checked.";
    NSDictionary *s=report[@"sources"],*l=s[@"licenses"],*p=s[@"playback"],*n=s[@"native"];
    NSString *when=[[NSISO8601DateFormatter new]stringFromDate:[NSDate dateWithTimeIntervalSince1970:[report[@"finished_at"]doubleValue]]];
    return [NSString stringWithFormat:@"Last explicit check: %@\nDevice licenses: %@ of %@ free\nOffline playback reported by Spotify: %@\nLocal track quota: %@/%@\n%@\nResponse source: Spotify's in-process offline API. A direct server response was not observed.",when,
        l[@"free_licenses"]?:@"unknown",l[@"max_licenses"]?:@"unknown",p[@"allowed"]?([p[@"allowed"]boolValue]?@"allowed":@"not allowed"):@"unknown",
        n[@"current_tracks"]?:@"unknown",n[@"music_limit"]?:@"unknown",SAPModeChangeBlockReason(report)?:@"The checks permit changing the configured mode; downloading is not guaranteed."];
}
static void finishCompatibility(void) {
    if(!currentRead)return;
    if(deadline){dispatch_source_cancel(deadline);deadline=nil;}
    NSDictionary *sources=currentRead[@"sources"];BOOL complete=YES;
    for(NSString *name in @[@"licenses",@"playback",@"preflight",@"native"])
        if(![sources[name][@"read_status"]isEqual:@"received"])complete=NO;
    currentRead[@"status"]=complete?@"complete":@"partial";
    currentRead[@"finished_at"]=@(NSDate.date.timeIntervalSince1970);
    NSDictionary *value=[currentRead copy];currentRead=nil;
    os_unfair_lock_lock(&compatibilityLock);latestCompatibility=value;os_unfair_lock_unlock(&compatibilityLock);
    SAP_JOURNAL_ACTION(@"quota_license_check_finished",value);
    SAP_TRACE("compatibility","fresh_check_finished",traceOperation,value);
    NSArray *callbacks=[waiting copy];waiting=nil;
    for(void (^callback)(NSDictionary *) in callbacks)callback(value);
}
static void receiveCompatibility(NSString *identifier,NSString *name,NSDictionary *result) {
    if(![currentRead[@"id"]isEqual:identifier])return;
    NSMutableDictionary *sources=currentRead[@"sources"];
    if(sources[name])return;
    sources[name]=result;
    SAP_TRACE("compatibility","source_observed",traceOperation,@{@"check_id":identifier,@"source":name,@"result":result,@"server_origin_proven":@NO});
    if(remaining && --remaining==0)finishCompatibility();
}
void SAPRefreshDownloadCompatibility(void (^completion)(NSDictionary *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPRefreshDownloadCompatibility(completion);});return;}
    if(currentRead){if(completion)[waiting addObject:[completion copy]];return;}
    waiting=[NSMutableArray array];if(completion)[waiting addObject:[completion copy]];
    NSString *identifier=NSUUID.UUID.UUIDString;
    traceOperation=SAPTraceCurrentOperation();
    if(!traceOperation&&SAPTraceIsActive())traceOperation=SAPTraceBegin(@"quota_license_refresh",@"pixie",@{@"check_id":identifier,@"read_only":@YES});
    currentRead=[@{@"id":identifier,@"started_at":@(NSDate.date.timeIntervalSince1970),
        @"source":@"in_process_offline_api",@"server_response_observed":@NO,@"read_only":@YES,
        @"sources":[NSMutableDictionary dictionary]}mutableCopy];
    remaining=7;
    SAP_JOURNAL_ACTION(@"quota_license_check_started",@{@"id":identifier,@"read_only":@YES});
#ifdef SAP_TESTING
    const double checkTimeout=0.04;
#else
    const double checkTimeout=10;
#endif
    deadline=SAPScheduleDeadline(dispatch_get_main_queue(),checkTimeout,^{
        if(![currentRead[@"id"]isEqual:identifier])return;
        NSMutableDictionary *sources=currentRead[@"sources"];
        for(NSString *name in @[@"licenses",@"playback",@"preflight",@"native",@"devices",@"local_device",@"license_info"])
            if(!sources[name])sources[name]=@{@"read_status":@"timeout",@"error":@"No response within 10 seconds"};
        finishCompatibility();
    });
    SAPReadNativeOfflineQuota(^(NSDictionary *state){receiveCompatibility(identifier,@"native",state);});
    NSDictionary *methods=@{@"licenses":@"LicenseStatus",@"playback":@"GetOfflinePlaybackStatus",@"preflight":@"BulkRedownloadPreflight",
        @"devices":@"GetDevices",@"local_device":@"GetLocalDevice",@"license_info":@"GetOfflineLicenseInfo"};
    for(NSString *name in methods) {
        NSString *method=methods[name];
        SAPTraceWithOperation(traceOperation,^{SAPCallReadOnlyService(offlineService,method,NSData.data,^(NSData *data,NSString *error){
            NSArray *fields=[data isKindOfClass:NSData.class]?SAPProtoFields(data):nil;
            NSMutableDictionary *value=[@{@"method":method,@"observed_at":@(NSDate.date.timeIntervalSince1970),
                @"read_status":fields?@"received":@"failed",@"response_bytes":@(data.length)}mutableCopy];
            if(data)value[@"response_base64"]=[data base64EncodedStringWithOptions:0];
            if(!fields) {
                value[@"error"]=error?:@"Invalid protobuf response";
                if([error localizedCaseInsensitiveContainsString:@"timeout"]||[error localizedCaseInsensitiveContainsString:@"timed out"])value[@"read_status"]=@"timeout";
                else if([error localizedCaseInsensitiveContainsString:@"unavailable"]||[error localizedCaseInsensitiveContainsString:@"not prepared"])value[@"read_status"]=@"unavailable";
            }
            else if([name isEqual:@"licenses"]) {
                value[@"max_licenses"]=@((int32_t)SAPProtoNumber(fields,1,0));value[@"free_licenses"]=@((int32_t)SAPProtoNumber(fields,2,0));value[@"error"]=@(SAPProtoNumber(fields,3,0));
            }else if([name isEqual:@"playback"])value[@"allowed"]=@(SAPProtoNumber(fields,1,0)!=0);
            else if([name isEqual:@"preflight"]) {value[@"has_sufficient_storage"]=@(SAPProtoNumber(fields,5,0)!=0);value[@"downloads_in_progress"]=@(SAPProtoNumber(fields,6,0));}
            else if([name isEqual:@"local_device"]) {
                NSDictionary *device=deviceFields(fields);
                if(device)value[@"device"]=device;
                else {value[@"read_status"]=@"invalid_response";value[@"error"]=@"GetLocalDevice did not return a valid exact device_id and cache_id. Play one track online on this device, then refresh.";}
            }
            else if([name isEqual:@"devices"]) {
                NSMutableArray *devices=[NSMutableArray array];
                for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2) {
                    NSArray *fields=SAPProtoFields(field[@"value"]);NSDictionary *device=deviceFields(fields);
                    if(device)[devices addObject:device];
                    else {value[@"read_status"]=@"invalid_response";value[@"error_detail"]=@"GetDevices returned an invalid exact identity.";}
                }
                value[@"devices"]=devices;value[@"error"]=@(SAPProtoNumber(fields,2,0));
            }else if([name isEqual:@"license_info"]) {
                NSArray *expiry=SAPProtoFields(SAPProtoData(fields,1));
                for(NSString *type in @[@"track",@"episode"]) {
                    NSData *timestamp=SAPProtoData(expiry,[type isEqual:@"track"]?1:2);
                    if(timestamp) {
                        NSArray *time=SAPProtoFields(timestamp);
                        value[[type stringByAppendingString:@"_expiry_epoch_seconds"]]=@(SAPProtoNumber(time,1,0));
                    }
                }
            }
            receiveCompatibility(identifier,name,value);
        });});
    }
}
