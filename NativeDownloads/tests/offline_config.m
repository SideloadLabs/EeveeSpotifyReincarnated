#include "Diagnostics.h"
#import <Foundation/Foundation.h>
#import "OfflineConfig.h"
#import "WireProto.h"
#include <assert.h>

@interface TestTask : NSObject
@property(nonatomic, strong) NSURLRequest *currentRequest;
@property(nonatomic, strong) NSURLRequest *originalRequest;
@property(nonatomic, strong) NSURLResponse *response;
@end
@implementation TestTask @end
@interface SPTCoreURLSessionDataDelegate : NSObject
@property(nonatomic, strong) NSMutableData *received;
@property(nonatomic) unsigned completions;
@property(nonatomic, strong) NSError *error;
- (void)URLSession:(id)session dataTask:(id)task didReceiveData:(NSData *)data;
- (void)URLSession:(id)session task:(id)task didCompleteWithError:(NSError *)error;
@end
@implementation SPTCoreURLSessionDataDelegate
- (instancetype)init { if ((self = [super init])) _received = [NSMutableData data]; return self; }
- (void)URLSession:(id)session dataTask:(id)task didReceiveData:(NSData *)data { [self.received appendData:data]; }
- (void)URLSession:(id)session task:(id)task didCompleteWithError:(NSError *)error { self.completions++; self.error = error; }
@end

// Vitrine holds the body, then delivers its full rewritten/cached response by
// calling the delegate selector again during completion or a 304 response.
@interface SPTDataLoaderService : NSObject
@property(nonatomic,strong) NSMutableData *received,*held;
@property(nonatomic,strong) NSData *cached;
@property(nonatomic) BOOL delivering,served;
@property(nonatomic) unsigned completions;
- (void)URLSession:(id)session dataTask:(id)task didReceiveData:(NSData *)data;
- (void)URLSession:(id)session task:(id)task didCompleteWithError:(NSError *)error;
- (void)URLSession:(id)session dataTask:(id)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSInteger))handler;
@end
@implementation SPTDataLoaderService
- (instancetype)init {if((self=[super init])){_received=[NSMutableData data];_held=[NSMutableData data];}return self;}
- (void)URLSession:(id)session dataTask:(id)task didReceiveData:(NSData *)data {
    [(self.delivering?self.received:self.held) appendData:data];
}
- (void)URLSession:(id)session task:(id)task didCompleteWithError:(NSError *)error {
    if(!self.served){self.delivering=YES;[self URLSession:session dataTask:task didReceiveData:[self.held copy]];self.delivering=NO;}
    self.completions++;
}
- (void)URLSession:(id)session dataTask:(id)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSInteger))handler {
    if([(NSHTTPURLResponse *)response statusCode]==304 && self.cached){
        self.served=YES;self.delivering=YES;
        [self URLSession:session dataTask:task didReceiveData:self.cached];self.delivering=NO;
    }
    if(handler)handler(1);
}
@end

static NSData *join(NSData *a, NSData *b) { NSMutableData *d = [a mutableCopy]; [d appendData:b]; return d; }
static NSData *entry(NSString *name, NSData *value) { return SAPProtoBytes(1, join(SAPProtoBytes(1, [name dataUsingEncoding:NSUTF8StringEncoding]), SAPProtoBytes(2, value))); }
static NSData *attributes(NSData *data, BOOL bootstrap) {
    unsigned path[] = {2, 1, 1, 1, 3};
    if (bootstrap) { for (unsigned i = 0; i < 5; i++) data = SAPProtoData(SAPProtoFields(data), path[i]); }
    else { data = SAPProtoData(SAPProtoFields(data), 1); data = SAPProtoData(SAPProtoFields(data), 3); }
    return data;
}
static NSData *attribute(NSData *config, NSString *key, BOOL bootstrap) {
    for (NSDictionary *field in SAPProtoFields(attributes(config, bootstrap))) {
        if ([field[@"number"] intValue] != 1 || [field[@"wire"] intValue] != 2) continue;
        NSArray *mapEntry = SAPProtoFields(field[@"value"]);
        if ([SAPProtoString(mapEntry, 1) isEqual:key]) return SAPProtoData(mapEntry, 2);
    }
    return nil;
}
static TestTask *task(NSString *path, NSInteger status) {
    TestTask *task = [TestTask new]; NSURL *url = [NSURL URLWithString:path];
    task.currentRequest = [NSURLRequest requestWithURL:url]; task.originalRequest = task.currentRequest;
    task.response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/2" headerFields:@{}]; return task;
}
int main(void) { @autoreleasepool {
    SAPDiagnosticsSetEnabled(true);

    NSData *unknown = SAPProtoInteger(98, 123456);
    NSData *attrs = join(entry(@"type", SAPProtoBytes(4, [@"free" dataUsingEncoding:NSUTF8StringEncoding])), unknown);
    attrs = join(attrs, entry(@"offline", join(SAPProtoInteger(2, 0), unknown)));
    attrs = join(attrs, entry(@"can-use-offline", SAPProtoBytes(4, [@"0" dataUsingEncoding:NSUTF8StringEncoding])));
    attrs = join(attrs, entry(@"max-offline-tracks", SAPProtoInteger(3, 10)));
    NSData *customize = SAPProtoBytes(1, join(SAPProtoBytes(3, attrs), unknown));
    NSData *bootstrap = SAPProtoBytes(2, SAPProtoBytes(1, SAPProtoBytes(1, customize)));
    NSString *suite = [@"SpotifyAudioProbe.ConfigTest." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setObject:customize forKey:@"eeveeCachedCustomizeData"];
    [defaults setObject:@"keep" forKey:@"unrelated"];
    assert(SAPPrepareCachedOfflineConfig(defaults));
    assert([[defaults dataForKey:@"eeveeCachedCustomizeData"] isEqual:SAPRewriteOfflineConfig(customize, NO)]);
    assert([[defaults dataForKey:@"SAPOriginalCustomizeBeforeOfflineFlags"] isEqual:customize]);
    assert(!SAPPrepareCachedOfflineConfig(defaults) && [[defaults stringForKey:@"unrelated"] isEqual:@"keep"]);
    [defaults removePersistentDomainForName:suite];
    for (unsigned boot = 0; boot < 2; boot++) {
        NSData *original = boot ? bootstrap : customize;
        NSData *result = SAPRewriteOfflineConfig(original, boot);
        assert(![result isEqual:original]);
        assert(SAPProtoNumber(SAPProtoFields(attribute(result, @"offline", boot)), 2, 0) == 1);
        assert([SAPProtoString(SAPProtoFields(attribute(result, @"can-use-offline", boot)), 4) isEqual:@"1"]);
        assert(SAPProtoNumber(SAPProtoFields(attribute(result, @"max-offline-tracks", boot)), 3, 0) == 1000000);
        assert(SAPProtoNumber(SAPProtoFields(attribute(result, @"max-offline-downloads-per-device", boot)), 3, 0) == 1000000);
        assert([attribute(result, @"type", boot) isEqual:attribute(original, @"type", boot)]);
        assert(SAPProtoNumber(SAPProtoFields(attribute(result, @"offline", boot)), 98, 0) == 123456);
        assert([SAPRewriteOfflineConfig(result, boot) isEqual:result]);
    }
    // Corrupt lengths, overflowed varints, illegal tags/groups and other schemas
    // must be passed back byte-for-byte, not partially decoded and rewritten.
    for (NSData *bad in @[[NSData dataWithBytes:(uint8_t[]){0x0a,0x7f,1} length:3],
        [NSData dataWithBytes:(uint8_t[]){0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,2} length:10],
        [NSData dataWithBytes:(uint8_t[]){0} length:1], SAPProtoInteger(1, 10), NSData.data])
        assert([SAPRewriteOfflineConfig(bad, NO) isEqual:bad]);
    SAPInstallOfflineConfig(); SAPInstallOfflineConfig();
    assert([SAPOfflineConfigReport()[@"delegates"] count] == 2);
    SPTCoreURLSessionDataDelegate *delegate = [SPTCoreURLSessionDataDelegate new];
    TestTask *t = task(@"https://spclient.wg.spotify.com/bootstrap/v1/bootstrap", 200);
    [delegate URLSession:nil dataTask:t didReceiveData:[bootstrap subdataWithRange:NSMakeRange(0, 7)]];
    [delegate URLSession:nil dataTask:t didReceiveData:[bootstrap subdataWithRange:NSMakeRange(7, bootstrap.length - 7)]];
    assert(delegate.received.length == 0);
    [delegate URLSession:nil task:t didCompleteWithError:nil];
    assert(delegate.completions == 1 && [delegate.received isEqual:SAPRewriteOfflineConfig(bootstrap, YES)]);
    [delegate.received setLength:0];
    t = task(@"https://example.com/v1/customize", 200);
    [delegate URLSession:nil dataTask:t didReceiveData:customize]; assert([delegate.received isEqual:customize]);
    [delegate URLSession:nil task:t didCompleteWithError:nil];
    [delegate.received setLength:0];
    t = task(@"https://spclient.wg.spotify.com/ucs/v1/customize", 200);
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:-999 userInfo:nil];
    [delegate URLSession:nil dataTask:t didReceiveData:customize];
    [delegate URLSession:nil task:t didCompleteWithError:error];
    assert([delegate.received isEqual:customize] && delegate.error == error);
    [delegate.received setLength:0];
    t = task(@"https://spclient.wg.spotify.com/ucs/v1/customize", 200);
    NSData *large = [NSMutableData dataWithLength:3 * 1024 * 1024];
    [delegate URLSession:nil dataTask:t didReceiveData:large];
    [delegate URLSession:nil dataTask:t didReceiveData:large];
    assert(delegate.received.length == 6 * 1024 * 1024);
    [delegate URLSession:nil task:t didCompleteWithError:nil];
    assert([SAPOfflineConfigReport()[@"oversized_passthrough"] unsignedIntValue] == 1);
    [delegate.received setLength:0];
    t = task(@"https://spclient.wg.spotify.com/ucs/v1/customize", 304);
    [delegate URLSession:nil task:t didCompleteWithError:nil];
    assert(delegate.received.length == 0 && [SAPOfflineConfigReport()[@"no_body"] unsignedIntValue] == 1);
    assert(delegate.completions == 5);
    // A cached negative classification must be invalidated by a redirect.
    [delegate.received setLength:0];t=task(@"https://example.com/ignored",200);
    [delegate URLSession:nil dataTask:t didReceiveData:NSData.data];
    NSURL *redirect=[NSURL URLWithString:@"https://spclient.wg.spotify.com/ucs/v1/customize"];
    t.currentRequest=[NSURLRequest requestWithURL:redirect];
    t.response=[[NSHTTPURLResponse alloc]initWithURL:redirect statusCode:200 HTTPVersion:@"HTTP/2" headerFields:nil];
    [delegate URLSession:nil dataTask:t didReceiveData:customize];
    [delegate URLSession:nil task:t didCompleteWithError:nil];
    assert([delegate.received isEqual:SAPRewriteOfflineConfig(customize,NO)]);
    // A cached positive classification must also follow a new URL.
    [delegate.received setLength:0];t=task(@"https://spclient.wg.spotify.com/ucs/v1/customize",200);
    [delegate URLSession:nil dataTask:t didReceiveData:NSData.data];
    t.currentRequest=[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com/unrelated"]];
    [delegate URLSession:nil dataTask:t didReceiveData:customize];
    [delegate URLSession:nil task:t didCompleteWithError:nil];assert([delegate.received isEqual:customize]);
    puts("PASS: cached positive/negative HTTP classifications follow redirects");
    SPTDataLoaderService *vitrine=[SPTDataLoaderService new];
    t=task(@"https://spclient.wg.spotify.com/ucs/v1/customize",200);
    [vitrine URLSession:nil dataTask:t didReceiveData:customize];
    [vitrine URLSession:nil task:t didCompleteWithError:nil];
    assert(vitrine.completions==1 && [vitrine.received isEqual:SAPRewriteOfflineConfig(customize,NO)]);
    vitrine=[SPTDataLoaderService new];vitrine.cached=customize;
    t=task(@"https://spclient.wg.spotify.com/ucs/v1/customize",304);
    [vitrine URLSession:nil dataTask:t didReceiveResponse:t.response completionHandler:nil];
    [vitrine URLSession:nil task:t didCompleteWithError:nil];
    assert(vitrine.completions==1 && [vitrine.received isEqual:SAPRewriteOfflineConfig(customize,NO)]);
    puts("PASS: Vitrine's full-body and cached-304 reentrant deliveries reach Spotify once with offline attributes");
    puts("PASS: exact bootstrap/customize wire paths; original value types and unknown/unrelated fields; malformed/overflow passthrough; chunk reassembly; errors/304; 4 MiB cap; no network calls/timers");
} }
