#import <Foundation/Foundation.h>
#import "TemporaryOfflineExport.h"
#import "SpotifyTransport.h"
#import "ExportNativeAdapters.h"
#import "WireProto.h"
#include <assert.h>
static NSString *const track=@"spotify:track:0123456789012345678901";
static NSString *const album=@"spotify:album:0123456789012345678901";
static NSUInteger offlineState,offlineRemovals,collectionRemovals,nativeRemovals,containsReads;
static NSMutableDictionary *membership;
static BOOL failedBaseline,missingMembership,stuckOffline,stuckLibrary,mutationTimeout,omitDefaultContext,missingOffline,badStatus;
static NSString *lastTarget;
static NSData *stringField(unsigned n,NSString *s){return SAPProtoBytes(n,[s dataUsingEncoding:NSUTF8StringEncoding]);}
void SAPCallReadOnlyService(NSString *service,NSString *method,NSData *payload,void (^reply)(NSData *,NSString *)) {
    if(failedBaseline){reply(nil,@"synthetic read failure");return;}
    if([method isEqual:@"Contains"]) {
        assert([service isEqual:@"spotify.your_library_esperanto.proto.YourLibraryService"]);containsReads++;
        NSMutableData *response=[SAPProtoInteger(98,badStatus?500:200)mutableCopy];
        for(NSDictionary *f in SAPProtoFields(payload)) {
            assert([f[@"number"]intValue]==3);
            NSString *uri=[[NSString alloc]initWithData:f[@"value"] encoding:NSUTF8StringEncoding];
            if(missingMembership&&[uri isEqual:album])continue;
            NSMutableData *entry=[stringField(1,uri)mutableCopy];[entry appendData:SAPProtoInteger(2,[membership[uri]boolValue])];
            [response appendData:SAPProtoBytes(2,entry)];
        }
        reply(response,nil);return;
    }
    assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);
    if(missingOffline){reply([NSData data],nil);return;}
    BOOL context=[method isEqual:@"GetContexts"];
    NSString *uri=SAPProtoString(SAPProtoFields(payload),context?3:1);
    assert([uri isEqual:context?album:track]);
    if(context)assert(SAPProtoNumber(SAPProtoFields(SAPProtoData(SAPProtoFields(payload),1)),1,0)==1);
    NSMutableData *entry=[stringField(1,uri)mutableCopy];
    if(!(context&&omitDefaultContext&&offlineState==0))[entry appendData:SAPProtoInteger(2,offlineState)];
    reply(SAPProtoBytes(1,context?SAPProtoBytes(1,entry):entry),nil);
}
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void (^reply)(NSData *,NSString *)) {
    assert([method isEqual:@"RemoveDownload"]);offlineRemovals++;lastTarget=SAPProtoString(SAPProtoFields(payload),2);assert([lastTarget isEqual:track]);
    if(!stuckOffline)offlineState=1;
    reply(mutationTimeout?nil:SAPProtoInteger(1,0),mutationTimeout?@"synthetic timeout":nil);
}
void SAPResetEntityOffline(NSString *uri,void (^reply)(BOOL,NSString *)) {
    assert([uri isEqual:album]);nativeRemovals++;if(!stuckOffline)offlineState=0;reply(YES,nil);
}
void SAPInvokeServiceOnce(NSString *service,NSString *method,NSData *payload,void (^reply)(NSData *,NSString *,SAPCommandInvocationDisposition)) {
    assert([service isEqual:@"spotify.collection_esperanto.proto.CollectionService"]&&[method isEqual:@"Remove"]);collectionRemovals++;
    for(NSDictionary *f in SAPProtoFields(payload)) {
        assert([f[@"number"]intValue]==2);NSString *uri=SAPProtoString(SAPProtoFields(f[@"value"]),1);
        assert([uri isEqual:track]||[uri isEqual:album]);if(!stuckLibrary)membership[uri]=@NO;
    }
    reply(mutationTimeout?nil:SAPProtoInteger(98,200),mutationTimeout?@"synthetic timeout":nil,SAPCommandInvoked);
}
static void waitUntil(BOOL (^done)(void)) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!done()&&until.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(done());
}
static NSDictionary *capture(NSString *uri,NSString **error) {
    __block NSDictionary *token;__block NSString *failure;__block BOOL done=NO;
    SAPCaptureTemporaryOfflineExport(uri,@[@{@"uri":track,@"album_uri":album}],^(NSDictionary *t,NSString *e){token=t;failure=e;done=YES;});
    waitUntil(^BOOL{return done;});if(error)*error=failure;return token;
}
static NSString *cleanup(NSDictionary *token,BOOL accepted) {
    __block BOOL done=NO;__block NSString *error;
    SAPCleanupTemporaryOfflineExport(token,accepted,^(NSString *e){error=e;done=YES;});waitUntil(^BOOL{return done;});return error;
}
static void reset(NSUInteger state) {
    offlineState=state;offlineRemovals=collectionRemovals=nativeRemovals=containsReads=0;
    membership=[@{track:@NO,album:@NO}mutableCopy];failedBaseline=missingMembership=stuckOffline=stuckLibrary=mutationTimeout=omitDefaultContext=missingOffline=badStatus=NO;lastTarget=nil;
}
int main(void){@autoreleasepool {
    NSString *error=nil;reset(3);membership[track]=@YES;membership[album]=@YES;
    NSDictionary *token=capture(track,&error);assert(token&&!error);assert(!cleanup(token,YES));
    assert(!offlineRemovals&&!collectionRemovals&&[membership[track]boolValue]);
    for(NSNumber *active in @[@2,@4,@5,@6]){reset(active.unsignedIntegerValue);token=capture(track,&error);assert(token&&!error);assert(!cleanup(token,YES));assert(!offlineRemovals&&!collectionRemovals);}
    reset(1);membership[album]=@YES;token=capture(track,&error);assert(token&&!error);
    offlineState=3;membership[track]=@YES;assert(!cleanup(token,YES));
    assert(offlineRemovals==1&&collectionRemovals==1&&![membership[track]boolValue]&&[membership[album]boolValue]);
    assert(!cleanup(token,YES));assert(offlineRemovals==1&&collectionRemovals==1);
    reset(1);token=capture(track,&error);offlineState=3;assert(!cleanup(token,YES));assert(offlineRemovals==1&&!collectionRemovals);
    reset(1);token=capture(track,&error);offlineState=3;assert(!cleanup(token,NO));assert(!offlineRemovals&&!collectionRemovals);
    reset(1);failedBaseline=YES;assert(!capture(track,&error)&&error.length);assert(!offlineRemovals&&!collectionRemovals);
    reset(1);missingMembership=YES;assert(!capture(track,&error)&&error.length);assert(!offlineRemovals&&!collectionRemovals);
    reset(1);token=capture(track,&error);offlineState=3;membership[track]=@YES;stuckOffline=YES;
    assert(cleanup(token,YES).length);assert(offlineRemovals==1&&!collectionRemovals);assert(cleanup(token,YES).length);assert(offlineRemovals==1);
    reset(1);token=capture(track,&error);offlineState=3;membership[track]=@YES;stuckLibrary=YES;mutationTimeout=YES;
    assert(cleanup(token,YES).length);assert(offlineRemovals==1&&collectionRemovals==1);assert(cleanup(token,YES).length);assert(collectionRemovals==1);
    reset(1);missingOffline=YES;assert(!capture(track,&error)&&error.length);assert(!offlineRemovals&&!collectionRemovals);
    reset(0);token=capture(track,&error);assert(token&&!error);offlineState=3;membership[track]=@YES;assert(!cleanup(token,YES));assert(offlineRemovals==1);
    reset(7);assert(!capture(track,&error)&&error.length);assert(!offlineRemovals&&!collectionRemovals);
    reset(1);badStatus=YES;assert(!capture(track,&error)&&error.length);assert(!offlineRemovals&&!collectionRemovals);
    reset(1);token=capture(track,&error);offlineState=3;membership[track]=@YES;missingMembership=YES;
    assert(cleanup(token,YES).length);assert(offlineRemovals==1&&!collectionRemovals);
    reset(1);__block BOOL boundedDone=NO;__block NSDictionary *oversizedToken;__block NSString *boundedError;
    NSMutableArray *many=[NSMutableArray array];
    for(unsigned i=0;i<65;i++)[many addObject:@{@"uri":track,@"album_uri":[NSString stringWithFormat:@"spotify:album:%022u",i]}];
    SAPCaptureTemporaryOfflineExport(track,many,^(NSDictionary *t,NSString *e){oversizedToken=t;boundedError=e;boundedDone=YES;});
    waitUntil(^BOOL{return boundedDone;});assert(!oversizedToken&&boundedError.length&&containsReads==0);
    // An album is prepared and restored track by track with the single-track commands.
    reset(0);token=capture(album,&error);assert(token&&!error);offlineState=3;membership[album]=@YES;
    assert(!cleanup(token,YES));assert(offlineRemovals==1&&!nativeRemovals&&collectionRemovals==1&&![membership[album]boolValue]);
    reset(0);token=capture(album,&error);assert(token&&!error);
    // Cancellation can precede the first visible state of an accepted download.
    assert(!cleanup(token,YES));assert(offlineRemovals==1&&!nativeRemovals&&!collectionRemovals);
    // A track Spotify already had is never removed.
    reset(3);token=capture(album,&error);assert(token&&!error);assert(!cleanup(token,YES));assert(!offlineRemovals&&!nativeRemovals&&!collectionRemovals);
    puts("PASS temporary baseline, existing state preservation, conditional restoration, no replay and truthful verification");
}return 0;}
