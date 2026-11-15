#import "SpotifyCacheClear.h"
#import "TrackDownload.h"
#import "SpotifyTransport.h"
#import "WireProto.h"

static NSString *const StorageService=@"spotify.storage.esperanto.proto.Storage";
static BOOL running;

// Stats (es_storage.proto in Spotify 9.1.90): current_size=4, current_locked_size=5.
static NSDictionary *sizes(NSData *data) {
    NSArray *fields=data.length?SAPProtoFields(data):nil;if(!fields)return nil;
    return @{@"size":@(SAPProtoNumber(fields,4,0)),@"locked":@(SAPProtoNumber(fields,5,0))};
}
static void readStats(void (^done)(NSDictionary *)) {
    SAPCallReadOnlyService(StorageService,@"GetStats",NSData.data,^(NSData *response,NSString *error){done(error.length?nil:sizes(response));});
}
static void finish(void (^completion)(NSDictionary *,NSString *),NSDictionary *result,NSString *error) {
    running=NO;if(completion)completion(result,error);
}
void SAPClearSpotifyCache(void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPClearSpotifyCache(completion);});return;}
    if(running){if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Cache clearing is already running.");});return;}
    running=YES;
    readStats(^(NSDictionary *before){
        SAPInvokeServiceOnce(StorageService,@"DeleteUnlockedItems",NSData.data,^(__unused NSData *reply,NSString *error,SAPCommandInvocationDisposition disposition){
            dispatch_async(dispatch_get_main_queue(),^{
                if(error.length||disposition!=SAPCommandInvoked){finish(completion,nil,error.length?error:@"Spotify was not ready. Start playback and try again.");return;}
                readStats(^(NSDictionary *after){
                    NSMutableDictionary *result=NSMutableDictionary.dictionary;
                    if(before&&after) {
                        unsigned long long sizeBefore=[before[@"size"]unsignedLongLongValue],sizeAfter=[after[@"size"]unsignedLongLongValue];
                        result[@"size_before"]=before[@"size"];result[@"size_after"]=after[@"size"];
                        result[@"locked_before"]=before[@"locked"];result[@"locked_after"]=after[@"locked"];
                        result[@"freed_bytes"]=@(sizeBefore>sizeAfter?sizeBefore-sizeAfter:0);
                    }
                    finish(completion,result,nil);
                });
            });
        });
    });
}
