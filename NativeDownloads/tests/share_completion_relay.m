#import <Foundation/Foundation.h>
#import "ShareCompletionRelay.h"
#include <assert.h>
int main(void){@autoreleasepool {
 __block BOOL spotifyBusy=YES;__block NSUInteger calls=0;__block BOOL sent=YES;
 SAPShareCompletionRelay *cancel=[[SAPShareCompletionRelay alloc]initWithCompletion:^(NSString *type,BOOL completed,NSArray *items,NSError *error){spotifyBusy=NO;sent=completed;calls++;}];
 [cancel finish:nil completed:NO items:nil error:nil];assert(!spotifyBusy&&!sent&&calls==1);
 [cancel finish:@"duplicate" completed:YES items:@[] error:nil];assert(calls==1);
 spotifyBusy=YES;
 SAPShareCompletionRelay *send=[[SAPShareCompletionRelay alloc]initWithCompletion:^(NSString *type,BOOL completed,NSArray *items,NSError *error){assert([type isEqual:@"target"]&&completed&&items.count==1);spotifyBusy=NO;calls++;}];
 [send finish:@"target" completed:YES items:@[@"file"] error:nil];assert(!spotifyBusy&&calls==2);
 NSError *expected=[NSError errorWithDomain:@"test" code:1 userInfo:nil];
 SAPShareCompletionRelay *failure=[[SAPShareCompletionRelay alloc]initWithCompletion:^(NSString *type,BOOL completed,NSArray *items,NSError *error){assert(!completed&&error==expected);calls++;}];
 [failure finish:nil completed:NO items:nil error:expected];[failure finish:nil completed:NO items:nil error:nil];assert(calls==3);
 puts("PASS native More completion releases busy state exactly once on cancel, send, and preparation error");
}return 0;}
