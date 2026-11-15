#import <Foundation/Foundation.h>
#import "ShareFilePromise.h"
#include <assert.h>
int main(void){@autoreleasepool {
 NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
 assert([@"audio" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
 SAPShareFilePromise *p=[SAPShareFilePromise new];__block unsigned first=0,second=0,third=0;dispatch_semaphore_t canceled=dispatch_semaphore_create(0);
 NSProgress *cancel=[p load:^(NSURL *url,NSError *e){assert(!url&&e);first++;dispatch_semaphore_signal(canceled);}];
 [p load:^(NSURL *url,NSError *e){assert([url isEqual:file]&&!e);second++;}];
 assert(!first&&!second);[cancel cancel];assert(dispatch_semaphore_wait(canceled,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);assert(first==1&&!second);
 [p resolveFile:file error:nil];assert(second==1&&[p.resolvedFile isEqual:file]);
 [p load:^(NSURL *url,NSError *e){assert([url isEqual:file]&&!e);third++;}];assert(third==1);
 [p cancel];[p resolveFile:nil error:[NSError errorWithDomain:@"test" code:1 userInfo:nil]];assert(first==1&&second==1&&third==1);
 SAPShareFilePromise *bad=[SAPShareFilePromise new];__block BOOL rejected=NO;
 [bad load:^(NSURL *url,NSError *e){assert(!url&&e);rejected=YES;}];[bad resolveFile:[NSURL URLWithString:@"https://open.spotify.com/track/x"] error:nil];assert(rejected&&!bad.resolvedFile);
 SAPShareFilePromise *stopped=[SAPShareFilePromise new];rejected=NO;
 [stopped load:^(NSURL *url,NSError *e){assert(!url&&e);rejected=YES;}];[stopped cancel];assert(rejected);
 [NSFileManager.defaultManager removeItemAtURL:file error:nil];
 puts("PASS promised audio: deferred callbacks, per-consumer cancel, multiple consumers, terminal result and link rejection");
}return 0;}
