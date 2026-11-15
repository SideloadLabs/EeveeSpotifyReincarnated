#import "ShareFilePromise.h"
static NSError *promiseError(NSString *message){return [NSError errorWithDomain:@"PixieShare" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
@interface SAPShareFileRequest:NSObject
@property(nonatomic,copy) void (^completion)(NSURL *,NSError *);
@property(nonatomic,strong) NSProgress *progress;
- (void)finish:(NSURL *)file error:(NSError *)error;
@end
@implementation SAPShareFileRequest
- (void)finish:(NSURL *)file error:(NSError *)error {
    void (^reply)(NSURL *,NSError *);
    @synchronized(self){reply=self.completion;self.completion=nil;}
    if(!reply)return;self.progress.cancellationHandler=nil;self.progress.completedUnitCount=1;reply(file,error);
}
@end
@interface SAPShareFilePromise ()
@property(nonatomic,strong) NSMutableArray<SAPShareFileRequest *> *requests;
@property(nonatomic,strong) NSURL *file;
@property(nonatomic,strong) NSError *failure;
@property(nonatomic) BOOL settled;
@end
@implementation SAPShareFilePromise
- (NSURL *)resolvedFile {@synchronized(self){return self.file;}}
- (NSProgress *)load:(void(^)(NSURL *,NSError *))completion {
    SAPShareFileRequest *request=[SAPShareFileRequest new];request.completion=completion;
    request.progress=[NSProgress progressWithTotalUnitCount:1];request.progress.cancellable=YES;
    __weak SAPShareFilePromise *weak=self;__weak SAPShareFileRequest *weakRequest=request;
    request.progress.cancellationHandler=^{SAPShareFilePromise *promise=weak;SAPShareFileRequest *pending=weakRequest;if(!pending)return;
        @synchronized(promise){[promise.requests removeObjectIdenticalTo:pending];}
        [pending finish:nil error:promiseError(@"File sharing was cancelled.")];
    };
    NSURL *file=nil;NSError *error=nil;BOOL reply=NO;
    @synchronized(self){
        if(self.settled){reply=YES;file=self.file;error=self.failure;}
        else if(self.requests.count>=32){reply=YES;error=promiseError(@"Too many requests for this shared file.");}
        else {if(!self.requests)self.requests=[NSMutableArray array];[self.requests addObject:request];}
    }
    if(reply)[request finish:file error:error];return request.progress;
}
- (void)resolveFile:(NSURL *)file error:(NSError *)error {
    if(!error && (!file.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:file.path]))error=promiseError(@"The audio file is unavailable. No link was sent.");
    NSArray<SAPShareFileRequest *> *requests;
    @synchronized(self){
        if(self.settled)return;self.settled=YES;self.file=error?nil:file;self.failure=error;
        requests=[self.requests copy];self.requests=nil;
    }
    for(SAPShareFileRequest *request in requests)[request finish:error?nil:file error:error];
}
- (void)cancel {[self resolveFile:nil error:promiseError(@"File sharing was cancelled.")];}
@end
