#import <Foundation/Foundation.h>
#import "SpotifyTransport.h"
#import "WireProto.h"
#include <assert.h>

NSString *const SAPOfflineService=@"spotify.offline_esperanto.proto.Offline";
static NSUInteger calls;
static NSData *expectedPayload;
static NSString *expectedMethod;
static BOOL simulateTimeout;

void SAPInvokeServiceOnce(NSString *service,NSString *method,NSData *payload,
                         void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)) {
    assert([service isEqual:SAPOfflineService]);
    assert([method isEqual:expectedMethod]&&[payload isEqual:expectedPayload]);
    calls++;
    completion(simulateTimeout?nil:NSData.data,simulateTimeout?@"Synthetic timeout":nil,SAPCommandInvoked);
}
static void waitFor(BOOL (^done)(void)) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:1];
    while(!done()&&end.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(done());
}
static void accepted(NSString *method,NSString *uri) {
    expectedMethod=method;expectedPayload=SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]);
    NSUInteger before=calls;__block NSUInteger replies=0;
    SAPCallOfflineCommandOnceWithDisposition(method,expectedPayload,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        assert(disposition==SAPCommandInvoked);
        assert(simulateTimeout?(!data&&error.length):(data!=nil&&error==nil));replies++;
    });
    waitFor(^BOOL{return replies!=0;});
    assert(replies==1&&calls==before+1);
}
static void rejected(NSString *method,id payload) {
    NSUInteger before=calls;__block NSUInteger replies=0;
    SAPCallOfflineCommandOnceWithDisposition(method,payload,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        assert(NSThread.isMainThread&&disposition==SAPCommandNotInvoked&&!data&&error.length);replies++;
    });
    waitFor(^BOOL{return replies!=0;});assert(replies==1&&calls==before);
}
int main(void) {@autoreleasepool {
    NSString *track=@"spotify:track:0123456789abcdefghijAB";
    for(NSString *method in @[@"AddDownload",@"RemoveDownload"])
        for(NSString *uri in @[track,@"spotify:album:0123456789abcdefghijAB",@"spotify:playlist:0123456789abcdefghijAB"])
            accepted(method,uri);
    simulateTimeout=YES;accepted(@"AddDownload",track);simulateTimeout=NO;
    NSData *valid=SAPProtoBytes(2,[track dataUsingEncoding:NSUTF8StringEncoding]);
    for(NSString *uri in @[@"spotify:track:short",@"spotify:track:0123456789abcdefghijA!",@"https://example.com",@"spotify:artist:0123456789abcdefghijAB"])
        rejected(@"AddDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]));
    NSMutableData *extra=[valid mutableCopy];[extra appendData:SAPProtoInteger(1,0)];
    rejected(@"AddDownload",extra);[extra setData:valid];[extra appendData:valid];rejected(@"AddDownload",extra);
    rejected(@"AddDownload",SAPProtoInteger(2,1));rejected(@"AddDownload",NSData.data);
    rejected(@"AddDownload",@"not protobuf");rejected(@"RemoveAllDownloads",valid);
    puts("PASS: exact track/album/playlist Add/Remove; one invocation on timeout; malformed and broader commands rejected");
}return 0;}
