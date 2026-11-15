#import "ShareCompletionRelay.h"
@interface SAPShareCompletionRelay ()
@property(nonatomic,copy) void (^completion)(NSString *,BOOL,NSArray *,NSError *);
@end
@implementation SAPShareCompletionRelay
- (instancetype)initWithCompletion:(void (^)(NSString *,BOOL,NSArray *,NSError *))completion {if((self=[super init]))_completion=[completion copy];return self;}
- (void)finish:(NSString *)type completed:(BOOL)completed items:(NSArray *)items error:(NSError *)error {
    void (^reply)(NSString *,BOOL,NSArray *,NSError *);
    @synchronized(self){reply=self.completion;self.completion=nil;}
    if(reply)reply(type,completed,items,error);
}
@end
