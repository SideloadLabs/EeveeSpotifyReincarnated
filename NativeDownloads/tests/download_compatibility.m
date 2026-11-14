#import <Foundation/Foundation.h>
#import "DownloadCompatibility.h"
#import "WireProto.h"
#include <assert.h>
static BOOL active;
static NSUInteger calls;
static BOOL offlineNoSlots,missingReply,silentReply,invalidLocal;
static void (^lateReply)(NSData *,NSString *);
void SAPJournalNoteAction(NSString *name,NSDictionary *facts) {}
BOOL SAPTrackDownloadActive(void) {return active;}
void SAPReadNativeOfflineQuota(void (^reply)(NSDictionary *)) {
    reply(@{@"read_status":@"received",@"current_tracks":@0,@"music_limit":@1000000,@"online":@YES,@"connection_allows_offlining":@YES});
}
static NSData *join(NSData *a,NSData *b) {NSMutableData *out=[a mutableCopy];[out appendData:b];return out;}
void SAPCallReadOnlyService(NSString *service,NSString *method,NSData *payload,void (^reply)(NSData *,NSString *)) {
    assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);assert(payload.length==0);calls++;
    if([method isEqual:@"LicenseStatus"])reply(join(SAPProtoInteger(1,5),SAPProtoInteger(2,offlineNoSlots?0:4)),nil);
    else if([method isEqual:@"GetOfflinePlaybackStatus"])reply(SAPProtoInteger(1,1),nil);
    else if([method isEqual:@"BulkRedownloadPreflight"]) {
        if(silentReply)lateReply=[reply copy];
        else reply(missingReply?nil:SAPProtoInteger(5,1),missingReply?@"timeout":nil);
    }
    else if([method isEqual:@"GetLocalDevice"]&&!invalidLocal)reply(join(SAPProtoBytes(1,[@"exact-device" dataUsingEncoding:NSUTF8StringEncoding]),SAPProtoBytes(2,[@"exact-cache" dataUsingEncoding:NSUTF8StringEncoding])),nil);
    else reply(NSData.data,nil);
}
int main(void) {@autoreleasepool {
    __block NSDictionary *result;
    SAPRefreshDownloadCompatibility(^(NSDictionary *value){result=value;});
    assert(result && calls==6);assert(SAPModeChangeBlockReason(result)==nil);
    assert([result[@"sources"][@"local_device"][@"read_status"]isEqual:@"received"]);
    assert([result[@"sources"][@"local_device"][@"device"][@"device_id"]isEqual:@"exact-device"]);
    invalidLocal=YES;SAPRefreshDownloadCompatibility(^(NSDictionary *value){result=value;});
    assert([result[@"sources"][@"local_device"][@"read_status"]isEqual:@"invalid_response"]&& !result[@"sources"][@"local_device"][@"device"]);invalidLocal=NO;
    active=YES;assert([SAPModeChangeBlockReason(result)containsString:@"active"]);active=NO;
    offlineNoSlots=YES;
    SAPRefreshDownloadCompatibility(^(NSDictionary *value){result=value;});
    assert([SAPModeChangeBlockReason(result)containsString:@"0 free"]);
    assert([SAPDownloadCompatibilityText(result)containsString:@"0 of 5"]);
    assert([result[@"server_response_observed"]isEqual:@NO]);
    offlineNoSlots=NO;missingReply=YES;
    SAPRefreshDownloadCompatibility(^(NSDictionary *value){result=value;});
    assert([result[@"status"]isEqual:@"partial"]);assert(SAPModeChangeBlockReason(result));
    NSMutableDictionary *stale=[result mutableCopy];stale[@"status"]=@"complete";stale[@"finished_at"]=@(NSDate.date.timeIntervalSince1970-11);
    assert([SAPModeChangeBlockReason(stale)containsString:@"stale"]);
    missingReply=NO;silentReply=YES;__block NSUInteger completed=0;
    SAPRefreshDownloadCompatibility(^(NSDictionary *value){result=value;completed++;});
    NSUInteger reads=calls;
    SAPRefreshDownloadCompatibility(^(NSDictionary *value){assert([value isEqual:result]);completed++;});
    assert(calls==reads);
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.3];
    while(completed<2 && until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(completed==2 && [result[@"status"]isEqual:@"partial"] && SAPModeChangeBlockReason(result));
    NSDictionary *before=SAPDownloadCompatibilityReport();lateReply(SAPProtoInteger(5,1),nil);
    assert([SAPDownloadCompatibilityReport()isEqual:before] && completed==2);
    puts("PASS fresh reads gate mode changes; zero slots, active job, missing responses and stale checks cannot pass; source is not misreported as server");
    puts("PASS concurrent refreshes coalesce; silence times out once; late replies cannot turn an incomplete check into success");
}return 0;}
