#import <Foundation/Foundation.h>
#import "DiagnosticTrace.h"
#import "NativeKeyTrace.h"
#import "WireProto.h"
#import "../src/Generated/ExportSites.h"
#include <assert.h>

static NSData *join(NSData *a,NSData *b){NSMutableData *v=[a mutableCopy];[v appendData:b];return v;}
static void waitFor(BOOL (^condition)(void)) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!condition()&&until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
    assert(condition());
}
static NSUInteger count(NSArray *events,NSString *category,NSString *stage) {
    NSUInteger n=0;for(NSDictionary *e in events)if([e[@"category"]isEqual:category]&&[e[@"stage"]isEqual:stage])n++;return n;
}
@interface FakeEndpoint : NSObject @end
@implementation FakeEndpoint @end
@interface InspectionData:NSData
@property(nonatomic) NSUInteger inspections;
@end
@implementation InspectionData
- (NSUInteger)length {self.inspections++;return 0;}
- (const void *)bytes {self.inspections++;return NULL;}
@end
@interface FakeTraceLifetime:NSObject
@property(nonatomic) NSUInteger acquisitions,cancellations;
- (void)acquire;
- (void)cancel;
@end
@implementation FakeTraceLifetime
- (void)acquire {self.acquisitions++;}
- (void)cancel {self.cancellations++;}
@end
@interface DerivedTraceLifetime:FakeTraceLifetime @end
@implementation DerivedTraceLifetime
- (void)acquire {[super acquire];}
- (void)cancel {[super cancel];}
@end
int main(int argc,const char **argv){@autoreleasepool{
    NSString *scenario=argc>1?@(argv[1]):@"normal";
    NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    if([scenario isEqual:@"write_error"]){[NSFileManager.defaultManager removeItemAtURL:directory error:nil];[@"file, not directory"writeToURL:directory atomically:YES encoding:NSUTF8StringEncoding error:nil];}
    SAPTraceTestConfigure(directory,[scenario isEqual:@"rotation"]?2048:1024*1024,[scenario isEqual:@"loss"]?1:512,0.02);
    assert(!SAPTraceIsActive()&&![SAPTraceReport()[@"initialized"]boolValue]);
    SAP_TRACE("test","must_not_exist",0,@{@"value":@1});assert(SAPTraceRPCBegin(@"service",@"method",NSData.data,@"test",FakeEndpoint.new,NO)==nil);
    assert(![SAPTraceReport()[@"initialized"]boolValue]);
    if([scenario isEqual:@"off_reset"]){
        [@"old history"writeToURL:[directory URLByAppendingPathComponent:@"PixieTrace.jsonl"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSError *error=nil;assert(SAPTraceReset(&error)&&!error&&!SAPTraceIsActive()&&![SAPTraceReport()[@"initialized"]boolValue]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"PixieTrace.jsonl"].path]);
        __block NSUInteger evaluations=0;SAP_TRACE("test","off",0,@{@"value":@(evaluations++)});assert(evaluations==0);
        puts("PASS reset while OFF deletes old files without enabling or creating the trace queue");return 0;
    }
    SAPTraceSetEnabled(true,"test_start");
    if([scenario isEqual:@"noise"]){
        FakeEndpoint *endpoint=FakeEndpoint.new;NSString *offline=@"spotify.offline_esperanto.proto.Offline";
        for(unsigned i=0;i<5;i++)assert(SAPTraceRPCBegin(@"spotify.connectivity.traffic.esperanto.proto.TrafficAdapter",i?@"listenToTrafficEvents":@"notifyTrafficEvent",NSData.data,@"spotify",endpoint,i!=0)==nil);
        assert([SAPTraceReport()[@"suppressed_traffic_adapter_calls"]unsignedLongLongValue]==5&&[SAPTraceReport()[@"rpc_slots_in_use"]unsignedIntValue]==0);
        NSData *a=SAPProtoInteger(1,5),*b=SAPProtoInteger(1,6);
        SAPTraceRPC *progress=SAPTraceRPCBegin(offline,@"SubscribeContextsProgress",NSData.data,@"spotify",endpoint,YES);
        SAPTraceRPC *other=SAPTraceRPCBegin(offline,@"SubscribeContextsProgress",NSData.data,@"spotify",endpoint,YES);
        SAPTraceRPC *plain=SAPTraceRPCBegin(offline,@"SubscribeItems",NSData.data,@"spotify",endpoint,YES);
        for(NSData *d in @[a,a,b,b,a])SAPTraceRPCReply(progress,d);          // written: a,b,a
        SAPTraceRPCReply(other,a);SAPTraceRPCReply(other,a);                  // other stream owns its own baseline: a, then repeat
        SAPTraceRPCReply(plain,a);SAPTraceRPCReply(plain,a);                  // non-progress streams are never deduplicated
        SAPTraceTestDrain();
        NSArray *events=SAPTraceExport()[@"events"];
        NSUInteger progressCallbacks=0,otherCallbacks=0,plainCallbacks=0;
        for(NSDictionary *e in events){if(![e[@"stage"]isEqual:@"callback"])continue;
            if([e[@"operation_id"]isEqual:@(progress.identifier)])progressCallbacks++;
            if([e[@"operation_id"]isEqual:@(other.identifier)])otherCallbacks++;
            if([e[@"operation_id"]isEqual:@(plain.identifier)])plainCallbacks++;}
        assert(progressCallbacks==3&&otherCallbacks==1&&plainCallbacks==2);
        assert([SAPTraceReport()[@"suppressed_identical_progress_callbacks"]unsignedLongLongValue]==3);
        assert(!SAPTraceRepeatedProgressPayload(@"observation",@"SubscribeTotalProgress",7,a)&&SAPTraceRepeatedProgressPayload(@"observation",@"SubscribeTotalProgress",7,a));
        assert(!SAPTraceRepeatedProgressPayload(@"observation",@"SubscribeTotalProgress",7,b)&&!SAPTraceRepeatedProgressPayload(@"observation",@"SubscribeTotalProgress",8,b));
        assert(!SAPTraceRepeatedProgressPayload(@"observation",@"GetItems",7,a)&&!SAPTraceRepeatedProgressPayload(@"observation",@"GetItems",7,a));
        NSError *error=nil;assert(SAPTraceReset(&error)&&SAPTraceIsActive()&&[SAPTraceReport()[@"suppressed_identical_progress_callbacks"]unsignedLongLongValue]==0);
        assert(!SAPTraceRepeatedProgressPayload(@"observation",@"SubscribeTotalProgress",7,b)); // a new log segment never inherits an old baseline
        SAPTraceSetEnabled(false,"test_end");SAPTraceTestDrain();assert(!SAPTraceRepeatedProgressPayload(@"observation",@"SubscribeTotalProgress",7,b));
        puts("PASS TrafficAdapter calls and byte-identical progress repeats are counted, not written; any changed byte, other streams, other methods and new segments are still recorded");return 0;
    }
    if([scenario isEqual:@"reset"]){
        uint64_t oldSegment=SAPTraceGeneration();
        SAPTraceRPC *old=SAPTraceRPCBegin(@"old.service",@"Subscribe",NSData.data,@"test",FakeEndpoint.new,YES);
        for(unsigned i=0;i<100;i++)SAP_TRACE("test","old_history",0,@{@"i":@(i)});
        NSError *error=nil;assert(SAPTraceReset(&error)&&!error&&SAPTraceIsActive());
        SAPTraceEventAtGeneration("test","stale_inspection",0,@{@"stale":@YES},oldSegment);
        SAPTraceRPCReply(old,NSData.data);SAP_TRACE("test","fresh_history",0,@{@"fresh":@YES});SAPTraceTestDrain();
        NSArray *fresh=SAPTraceExport()[@"events"];assert(fresh.count==2&&count(fresh,@"session",@"log_reset")==1&&count(fresh,@"test",@"fresh_history")==1);
        for(NSDictionary *event in fresh)assert([event[@"segment"]unsignedLongLongValue]>oldSegment);
        SAPTraceSetEnabled(false,"test_end");SAPTraceTestDrain();assert(SAPTraceReset(&error)&&!SAPTraceIsActive());
        assert([NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil].count==0);
        SAPTraceSetEnabled(true,"before_concurrent_toggle");
        SAPTraceTestSetResetObserver(^{SAPTraceSetEnabled(false,"user_disabled_during_reset");});
        assert(SAPTraceReset(&error)&&!SAPTraceIsActive());
        SAPTraceTestSetResetObserver(^{SAPTraceSetEnabled(true,"user_enabled_during_reset");});
        assert(SAPTraceReset(&error)&&SAPTraceIsActive());
        SAPTraceTestSetResetObserver(nil);SAPTraceSetEnabled(false,"end");SAPTraceTestDrain();
        puts("PASS reset clears retained/in-flight history and RPC wrappers; old callbacks cannot reappear; ON/OFF state preserved");return 0;
    }
    if([scenario isEqual:@"rotation"]||[scenario isEqual:@"loss"]||[scenario isEqual:@"write_error"]){
        for(NSUInteger i=0;i<300;i++)SAP_TRACE("test","burst",0,@{@"index":@(i),@"padding":[@"x"stringByPaddingToLength:512 withString:@"x" startingAtIndex:0]});
        SAPTraceTestDrain();NSDictionary *r=SAPTraceReport();
        if([scenario isEqual:@"rotation"]){assert([r[@"rotations"]unsignedLongLongValue]>0 && [r[@"evicted_bytes"]unsignedLongLongValue]>0);
            for(NSURL *u in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil])assert([[NSFileManager.defaultManager attributesOfItemAtPath:u.path error:nil][NSFileSize]unsignedLongLongValue]<=2048);}
        if([scenario isEqual:@"loss"])assert([r[@"dropped_before_enqueue"]unsignedLongLongValue]>0);
        if([scenario isEqual:@"write_error"])assert([r[@"write_failures"]unsignedLongLongValue]>0 && [r[@"last_write_errno"]intValue]!=0);
        SAPTraceSetEnabled(false,"test_end");SAPTraceTestDrain();NSLog(@"PASS %@: %@",scenario,r);return 0;
    }
    NSMutableString *mutable=[@"captured"mutableCopy];
    SAPTraceID op=SAPTraceBegin(@"download_album",@"test_ui",@{@"uri":@"spotify:album:1234567890123456789012"});
    SAPTraceWithOperation(op,^{SAP_TRACE("test","snapshot",op,@{@"value":mutable,@"Authorization":@"Bearer HIDDEN_TOKEN",@"key_bytes":@"HIDDEN_KEY",@"unknown_native":NSData.data});});
    [mutable setString:@"changed after capture"];
    FakeEndpoint *endpoint=FakeEndpoint.new;__block SAPTraceRPC *call;
    SAPTraceWithOperation(op,^{call=SAPTraceRPCBegin(@"spotify.offline_esperanto.proto.Offline",@"AddDownload",SAPProtoBytes(2,[@"spotify:album:1234567890123456789012"dataUsingEncoding:NSUTF8StringEncoding]),@"pixie",endpoint,NO);});
    assert(call);SAPTraceRPCReply(call,NSData.data);SAPTraceRPCReturned(call,nil);
    SAPTraceRPC *silent=SAPTraceRPCBegin(@"spotify.offline_esperanto.proto.Offline",@"LicenseStatus",NSData.data,@"spotify",endpoint,NO);
    SAPTraceTestDrain();
    waitFor(^BOOL{SAPTraceTestDrain();return [SAPTraceReport()[@"rpc_slots_in_use"]unsignedIntValue]==0;});
    SAPTraceRPCReply(silent,SAPProtoInteger(1,5));SAPTraceRPCReply(silent,NSData.data);
    SAPTraceRPC *stream=SAPTraceRPCBegin(@"unknown.service",@"Subscribe",SAPProtoBytes(1,[@"Bearer HIDDEN_PAYLOAD"dataUsingEncoding:NSUTF8StringEncoding]),@"spotify",endpoint,YES);
    SAPTraceRPCReply(stream,NSData.data);SAPTraceRPCStreamEnd(stream,@"callback_returned_false");
    SAPTraceRPC *exception=SAPTraceRPCBegin(@"unknown.service",@"Get",NSData.data,@"spotify",endpoint,NO);
    SAPTraceRPCException(exception,[NSException exceptionWithName:@"NativeException" reason:@"not serialized" userInfo:nil]);
    SAPTraceRPC *canceled=SAPTraceRPCBegin(@"unknown.service",@"Subscribe",NSData.data,@"spotify",endpoint,YES);
    FakeTraceLifetime *lifetime=FakeTraceLifetime.new;SAPTraceRPCReturned(canceled,lifetime);[lifetime acquire];[lifetime cancel];
    assert(lifetime.acquisitions==1&&lifetime.cancellations==1);SAPTraceRPCReply(canceled,NSData.data);
    SAPTraceRPC *derivedCall=SAPTraceRPCBegin(@"unknown.service",@"Subscribe",NSData.data,@"spotify",endpoint,YES);
    DerivedTraceLifetime *derived=DerivedTraceLifetime.new;SAPTraceRPCReturned(derivedCall,derived);[derived acquire];[derived cancel];
    assert(derived.acquisitions==1&&derived.cancellations==1);
    // Metadata descriptors were read from this exact 9.1.90 executable:
    // GetEntityResponse.item(1), MetadataItem.track(4), Track.file(12), AudioFile.file_id(1).
    uint8_t fileID[20];memset(fileID,0x42,20);NSString *trackURI=@"spotify:track:1234567890123456789012";
    NSData *track=join(SAPProtoBytes(36,[trackURI dataUsingEncoding:NSUTF8StringEncoding]),SAPProtoBytes(12,SAPProtoBytes(1,[NSData dataWithBytes:fileID length:20])));
    SAPNativeKeyTraceObserveMetadata(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",trackURI,SAPProtoBytes(1,SAPProtoBytes(4,track)));
    uintptr_t success=0x100,failure=0x200;uint64_t frame[20]={0};frame[1]=(uintptr_t)fileID;frame[2]=0;frame[4]=(uintptr_t)&success;frame[5]=(uintptr_t)&failure;
    SAPTraceNativeBoundaryForTesting(0,frame);
    frame[0]=(uintptr_t)&success;frame[1]=1; // Poison pointer: a success observer must never read result/key bytes.
    SAPTraceNativeBoundaryForTesting(1,frame);
    success=0x300;failure=0x400;frame[1]=(uintptr_t)fileID;SAPTraceNativeBoundaryForTesting(0,frame);
    frame[0]=(uintptr_t)&failure;frame[1]=8001;frame[2]=0;SAPTraceNativeBoundaryForTesting(2,frame);
    // Native std::function copies retain their wrapper/owner and file ID.
    uint8_t owner[SAPExportOwnerDescriptorOffset+0x40]={0},descriptor[24]={0};memcpy(descriptor+4,fileID,20);
    uintptr_t descriptorPointer=(uintptr_t)descriptor;memcpy(owner+SAPExportOwnerDescriptorOffset,&descriptorPointer,8);
    uintptr_t wrapper[2]={0,(uintptr_t)owner},originalSuccess[1]={(uintptr_t)wrapper},originalFailure[1]={(uintptr_t)wrapper},copiedSuccess[1]={(uintptr_t)wrapper};
    success=(uintptr_t)originalSuccess;failure=(uintptr_t)originalFailure;
    frame[1]=(uintptr_t)fileID;SAPTraceNativeBoundaryForTesting(0,frame);
    uintptr_t copied=(uintptr_t)copiedSuccess;frame[0]=(uintptr_t)&copied;frame[1]=1;SAPTraceNativeBoundaryForTesting(1,frame);
    frame[1]=(uintptr_t)fileID;SAPTraceNativeBoundaryForTesting(0,frame);SAPTraceNativeBoundaryForTesting(0,frame);
    frame[0]=(uintptr_t)&copied;frame[1]=1;SAPTraceNativeBoundaryForTesting(1,frame);
    NSDictionary *wire=SAPTraceWireSummary(@"spotify.offline_esperanto.proto.Offline",@"GetTotalProgress",SAPProtoBytes(1,join(SAPProtoInteger(1,4),SAPProtoInteger(3,2))),YES);
    assert([wire[@"progress"][@"queued_tracks"]intValue]==4&&[wire[@"progress"][@"downloaded_tracks"]intValue]==2);
    uint8_t invalid[]={0xff};assert(![SAPTraceWireSummary(@"spotify.offline_esperanto.proto.Offline",@"LicenseStatus",[NSData dataWithBytes:invalid length:1],YES)[@"valid_protobuf"]boolValue]);
    SAPTraceTestDrain();NSDictionary *export=SAPTraceExport();NSArray *events=export[@"events"];
    assert(count(events,@"rpc",@"invocation")==6);
    assert(count(events,@"rpc",@"lifetime_cancel_invoked")==2 && count(events,@"rpc",@"lifetime_acquire_invoked")==2 && count(events,@"rpc",@"callback_after_observation_end")==1);
    assert(count(events,@"rpc",@"reply_not_observed")==1);
    assert(count(events,@"rpc",@"late_callback")==2);
    assert(count(events,@"rpc",@"exception")==1);
    assert(count(events,@"native_key",@"success_callback_invoked")==3 && count(events,@"native_key",@"failure_callback_invoked")==1);
    BOOL immutable=NO,linked=NO,copiedLinked=NO,ambiguous=NO;
    for(NSDictionary *e in events){assert([e[@"captured_epoch_seconds"]doubleValue]<=[e[@"written_epoch_seconds"]doubleValue]);assert([e[@"queue_delay_ms"]doubleValue]>=0);
        if([e[@"stage"]isEqual:@"snapshot"]){immutable=[e[@"facts"][@"value"]isEqual:@"captured"];}
        if([e[@"stage"]isEqual:@"success_callback_invoked"]){
            NSString *link=e[@"facts"][@"request_link"];
            if([link isEqual:@"exact_original_functor_identity"])linked=[e[@"facts"][@"track_uri"]isEqual:trackURI];
            if([link isEqual:@"unique_captured_owner_and_file_identifier"])copiedLinked=[e[@"facts"][@"track_uri"]isEqual:trackURI];
            if([link isEqual:@"ambiguous"]){ambiguous=YES;assert(e[@"operation_id"]==NSNull.null&&[e[@"facts"][@"candidate_operation_ids"]count]==2);}
        }}
    assert(immutable&&linked&&copiedLinked&&ambiguous);
    NSString *json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:export options:0 error:nil] encoding:NSUTF8StringEncoding];
    assert(![json containsString:@"HIDDEN_TOKEN"] && ![json containsString:@"HIDDEN_KEY"] && ![json containsString:@"HIDDEN_PAYLOAD"]);
    SAPTraceSetEnabled(false,"test_end");SAPTraceTestDrain();uint64_t before=[SAPTraceReport()[@"captured_events"]unsignedLongLongValue];
    InspectionData *offData=[InspectionData new];
    SAP_TRACE("test","off",0,@{@"value":@0});SAPTraceRPCReply(stream,offData);assert(offData.inspections==0);
    SAPTraceTestDrain();assert([SAPTraceReport()[@"captured_events"]unsignedLongLongValue]==before && [SAPTraceReport()[@"rpc_slots_in_use"]unsignedIntValue]==0);
    for(unsigned i=0;i<6;i++){SAPTraceSetEnabled(true,"rapid_on");SAPTraceRPCBegin(@"test",@"Subscribe",NSData.data,@"test",endpoint,YES);SAPTraceSetEnabled(false,"rapid_off");}
    SAPTraceSetEnabled(true,"last_segment");
    SAPTraceRPC *last=SAPTraceRPCBegin(@"test",@"Subscribe",NSData.data,@"test",endpoint,YES);
    SAPTraceTestDrain();assert([SAPTraceReport()[@"rpc_slots_in_use"]unsignedIntValue]==1);
    frame[0]=(uintptr_t)&copied;frame[1]=1;SAPTraceNativeBoundaryForTesting(1,frame);SAPTraceTestDrain();
    NSDictionary *lastEvent=[SAPTraceExport()[@"events"]lastObject];
    assert([lastEvent[@"facts"][@"request_link"]isEqual:@"unavailable"]&&lastEvent[@"facts"][@"track_uri"]==NSNull.null);
    SAPTraceRPCStreamEnd(last,@"test_end");SAPTraceSetEnabled(false,"test_end");SAPTraceTestDrain();
    NSLog(@"PASS disabled path creates no logger; immutable capture times, RPC/late replies, exact native callback correlation, metadata file/track links and secret exclusion");
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
}return 0;}
