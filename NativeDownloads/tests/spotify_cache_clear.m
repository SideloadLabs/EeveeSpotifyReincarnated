#import <Foundation/Foundation.h>
#import "SpotifyCacheClear.h"
#import "WireProto.h"
#import "TrackDownload.h"
#include <assert.h>

// Stats(es_storage.proto): current_size=4, current_locked_size=5.
static NSString *scenario;
static NSMutableArray<NSString *> *calls;
static NSUInteger statsReads,deletes;
static NSData *stats(unsigned long long size,unsigned long long locked){
    NSMutableData *d=[SAPProtoInteger(4,size)mutableCopy];[d appendData:SAPProtoInteger(5,locked)];return d;
}
void SAPCallReadOnlyService(NSString *service,NSString *method,NSData *payload,void (^done)(NSData *,NSString *)){
    assert(NSThread.isMainThread);
    [calls addObject:[service stringByAppendingFormat:@"/%@",method]];
    assert([service isEqual:@"spotify.storage.esperanto.proto.Storage"]&&[method isEqual:@"GetStats"]&&payload.length==0);
    NSUInteger n=statsReads++;
    NSData *response=n==0?stats(1000,400):stats(deletes?700:1000,400);NSString *error=nil;
    if([scenario isEqual:@"stats_unreadable"]){response=nil;error=@"no stats";}
    dispatch_async(dispatch_get_main_queue(),^{done(response,error);});
}
void SAPInvokeServiceOnce(NSString *service,NSString *method,NSData *payload,void (^reply)(NSData *,NSString *,SAPCommandInvocationDisposition)){
    [calls addObject:[service stringByAppendingFormat:@"/%@",method]];
    // The only mutation allowed: Spotify's own Clear cache, with its empty request.
    assert([service isEqual:@"spotify.storage.esperanto.proto.Storage"]&&[method isEqual:@"DeleteUnlockedItems"]&&payload.length==0);
    deletes++;
    NSString *error=[scenario isEqual:@"error"]?@"timeout":nil;SAPCommandInvocationDisposition d=[scenario isEqual:@"not_invoked"]?SAPCommandNotInvoked:SAPCommandInvoked;
    dispatch_async(dispatch_get_main_queue(),^{reply(NSData.data,error,d);});
}
static void run(void (^check)(NSDictionary *,NSString *)){
    __block BOOL finished=NO;
    SAPClearSpotifyCache(^(NSDictionary *result,NSString *error){assert(NSThread.isMainThread&&!finished);finished=YES;check(result,error);});
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!finished&&until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
    assert(finished);
}
int main(int argc,const char **argv){@autoreleasepool{
    scenario=argc>1?@(argv[1]):@"normal";calls=NSMutableArray.array;
    if([scenario isEqual:@"normal"]){
        run(^(NSDictionary *r,NSString *e){assert(!e&&[r[@"freed_bytes"]unsignedLongLongValue]==300&&[r[@"locked_before"]isEqual:r[@"locked_after"]]&&[r[@"locked_after"]unsignedLongLongValue]==400);});
        assert(deletes==1&&statsReads==2);
        NSArray *expected=@[@"spotify.storage.esperanto.proto.Storage/GetStats",@"spotify.storage.esperanto.proto.Storage/DeleteUnlockedItems",@"spotify.storage.esperanto.proto.Storage/GetStats"];
        assert([calls isEqualToArray:expected]);
        puts("PASS clear cache sends exactly one empty Storage.DeleteUnlockedItems and reports the freed bytes; locked (downloaded) bytes unchanged");
    }else if([scenario isEqual:@"stats_unreadable"]){
        run(^(NSDictionary *r,NSString *e){assert(!e&&r.count==0);});assert(deletes==1);
        puts("PASS unreadable storage stats do not block or fake a result");
    }else if([scenario isEqual:@"error"]||[scenario isEqual:@"not_invoked"]){
        run(^(NSDictionary *r,NSString *e){assert(e.length&&!r);});assert(deletes==1&&statsReads==1);
        puts("PASS failed or uninvoked command is reported and never replayed");
    }else if([scenario isEqual:@"busy"]){
        __block BOOL first=NO,second=NO;
        SAPClearSpotifyCache(^(NSDictionary *r,NSString *e){first=!e;});
        SAPClearSpotifyCache(^(NSDictionary *r,NSString *e){second=e.length>0;});
        NSDate *until=[NSDate dateWithTimeIntervalSinceNow:2];while(!(first&&second)&&until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
        assert(first&&second&&deletes==1);
        puts("PASS a second tap while clearing is rejected without sending another command");
    }else assert(!"unknown scenario");
}return 0;}
