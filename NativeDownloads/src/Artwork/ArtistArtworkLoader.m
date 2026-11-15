#import "ArtistArtworkLoader.h"
#import "PlaylistArtwork.h"
#import "TrackJournal.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import <ImageIO/ImageIO.h>

static const NSUInteger SAPArtistArtworkMaximumBytes=1024*1024;
static const NSUInteger SAPArtistArtworkMaximumEntries=64;
static const NSUInteger SAPArtistArtworkMaximumPixels=128;
static const NSUInteger SAPArtistArtworkMaximumRequests=16;
char SAPArtistArtworkURLKey;
#ifdef SAP_TESTING
static void (^SAPArtistArtworkDataProviderForTesting)(NSString *,void (^)(NSData *));
void SAPArtistArtworkSetDataProviderForTesting(void (^provider)(NSString *,void (^)(NSData *))) {SAPArtistArtworkDataProviderForTesting=[provider copy];}
#endif

NSString *SAPArtistArtworkIdentifier(NSString *value) {
    if(![value isKindOfClass:NSString.class])return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithString:value];
    NSString *path=parts.path;
    BOOL mosaic=[parts.host.lowercaseString isEqual:@"mosaic.scdn.co"];
    NSString *prefix=mosaic?@"/300/":@"/image/";
    if(![parts.scheme.lowercaseString isEqual:@"https"] || (!mosaic && ![parts.host.lowercaseString isEqual:@"i.scdn.co"]) || parts.query.length || parts.fragment.length || ![path hasPrefix:prefix])return nil;
    NSString *identifier=[path substringFromIndex:prefix.length];
    if(mosaic?(identifier.length<40 || identifier.length>160 || identifier.length%40):identifier.length!=40)return nil;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet;
    if([identifier rangeOfCharacterFromSet:invalid].location!=NSNotFound)return nil;
    return mosaic?[@"mosaic:" stringByAppendingString:identifier.lowercaseString]:identifier.lowercaseString;
}

@interface SAPArtistArtworkConsumer : NSObject
@property(atomic) BOOL cancelled;
@property(nonatomic,copy) void (^completion)(UIImage *);
@end
@implementation SAPArtistArtworkConsumer @end

@interface SAPArtistArtworkRequest : NSObject
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,strong) NSMutableDictionary<NSString *,SAPArtistArtworkConsumer *> *completions;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic) BOOL allowed;
@property(nonatomic,copy) dispatch_block_t cancelNative;
@end
@implementation SAPArtistArtworkRequest @end

@interface SAPArtistArtworkLoader ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic,strong) NSOperationQueue *delegateQueue;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSCache<NSString *,UIImage *> *cache;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,SAPArtistArtworkRequest *> *requests;
@property(nonatomic,strong) NSMutableDictionary<NSString *,SAPArtistArtworkRequest *> *inFlight;
@end
@implementation SAPArtistArtworkLoader
+ (instancetype)shared {static SAPArtistArtworkLoader *loader;static dispatch_once_t once;dispatch_once(&once,^{loader=[self new];});return loader;}
- (instancetype)init {
    if((self=[super init])) {
        _queue=dispatch_queue_create("com.pixie.artist-artwork",DISPATCH_QUEUE_SERIAL);
        _delegateQueue=[NSOperationQueue new];_delegateQueue.maxConcurrentOperationCount=1;_delegateQueue.underlyingQueue=_queue;
        NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCache=nil;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest=8;configuration.timeoutIntervalForResource=12;
        configuration.HTTPMaximumConnectionsPerHost=4;configuration.HTTPShouldSetCookies=NO;
        _session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegateQueue];
        _cache=[NSCache new];_cache.countLimit=SAPArtistArtworkMaximumEntries;_cache.totalCostLimit=4*1024*1024;
        _requests=[NSMutableDictionary dictionary];_inFlight=[NSMutableDictionary dictionary];
    }
    return self;
}
- (void)complete:(NSArray<SAPArtistArtworkConsumer *> *)consumers image:(UIImage *)image {
    for(SAPArtistArtworkConsumer *consumer in consumers)dispatch_async(dispatch_get_main_queue(),^{
        if(!consumer.cancelled && consumer.completion)consumer.completion(image);
    });
}
- (dispatch_block_t)loadPlaylistURI:(NSString *)uri completion:(void (^)(UIImage *))completion {
    if([uri hasPrefix:@"spotify:mosaic:"]){
        NSString *url=SAPPlaylistArtworkURL(uri);
        return [self loadURL:url completion:^(UIImage *image){SAP_JOURNAL_ACTION(@"playlist_artwork_result",@{@"uri":uri,@"route":@"spotify_mosaic_cdn",@"url":url,@"image_received":@(image!=nil),@"error":image?@"":@"Mosaic image unavailable"});if(completion)completion(image);}];
    }
    return [self loadImageURI:uri maximumPixels:128 completion:completion];
}
- (dispatch_block_t)loadImageURI:(NSString *)uri maximumPixels:(NSUInteger)pixels completion:(void (^)(UIImage *))completion {
    pixels=MAX(1,MIN(pixels,1024));
    SAPArtistArtworkConsumer *consumer=[SAPArtistArtworkConsumer new];consumer.completion=completion;
    if(![uri isKindOfClass:NSString.class] || !uri.length || uri.length>4096 || (![uri hasPrefix:@"spotify:"] && ![uri hasPrefix:@"https://"])) {[self complete:@[consumer] image:nil];return ^{consumer.cancelled=YES;};}
    NSString *identifier=pixels==128?[@"native:" stringByAppendingString:uri]:[NSString stringWithFormat:@"native:%lu:%@",(unsigned long)pixels,uri],*token=NSUUID.UUID.UUIDString;
    dispatch_async(self.queue,^{
        if(consumer.cancelled)return;UIImage *cached=[self.cache objectForKey:identifier];if(cached){[self complete:@[consumer] image:cached];return;}
        SAPArtistArtworkRequest *request=self.inFlight[identifier];if(request){if(request.completions.count<64)request.completions[token]=consumer;else[self complete:@[consumer] image:nil];return;}
        if(self.inFlight.count>=SAPArtistArtworkMaximumRequests){[self complete:@[consumer] image:nil];return;}
        request=[SAPArtistArtworkRequest new];request.identifier=identifier;request.completions=[@{token:consumer}mutableCopy];self.inFlight[identifier]=request;
        // Verified es_image.proto: GetImageParams.uri=1, resolve.size=2.1;
        // ImageData.error=1, data=3. Spotify resolves mosaics and custom covers.
        NSMutableData *size=[SAPProtoInteger(1,pixels)mutableCopy];[size appendData:SAPProtoInteger(2,pixels)];
        NSMutableData *payload=[SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];[payload appendData:SAPProtoBytes(2,SAPProtoBytes(1,size))];
        request.cancelNative=SAPCallReadOnlyServiceCancellable(@"spotify.image.esperanto.proto.Image",@"GetImage",payload,^(NSData *data,NSString *error){
            dispatch_async(self.queue,^{
                if(self.inFlight[identifier]!=request)return;request.cancelNative=nil;[self.inFlight removeObjectForKey:identifier];
                NSArray *fields=data.length<=SAPArtistArtworkMaximumBytes+1024?SAPProtoFields(data):nil;uint64_t code=SAPProtoNumber(fields,1,0);
                UIImage *image=!error.length && fields && !code?[self thumbnailForData:SAPProtoData(fields,3) maximumPixels:pixels]:nil;
                if(image && pixels==128){NSUInteger cost=(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4;[self.cache setObject:image forKey:identifier cost:cost];}
                SAP_JOURNAL_ACTION(@"playlist_artwork_result",@{@"uri":uri,@"route":@"native_image_service",@"image_received":@(image!=nil),@"native_error_code":@(code),@"error":error?:(!fields?@"Invalid native image response":image?@"":@"Native image unavailable")});
                [self complete:request.completions.allValues image:image];
            });
        });
    });
    return ^{consumer.cancelled=YES;dispatch_async(self.queue,^{SAPArtistArtworkRequest *request=self.inFlight[identifier];[request.completions removeObjectForKey:token];if(request&&!request.completions.count){if(request.cancelNative)request.cancelNative();request.cancelNative=nil;[self.inFlight removeObjectForKey:identifier];}});};
}
- (dispatch_block_t)loadURL:(NSString *)value completion:(void (^)(UIImage *))completion {
    SAPArtistArtworkConsumer *consumer=[SAPArtistArtworkConsumer new];consumer.completion=completion;
    NSString *identifier=SAPArtistArtworkIdentifier(value),*token=NSUUID.UUID.UUIDString;
    if(!identifier)[self complete:@[consumer] image:nil];
    else dispatch_async(self.queue,^{
        if(consumer.cancelled)return;
        UIImage *cached=[self.cache objectForKey:identifier];
        if(cached){[self complete:@[consumer] image:cached];return;}
        SAPArtistArtworkRequest *existing=self.inFlight[identifier];
        if(existing){
            if(existing.completions.count<64)existing.completions[token]=consumer;
            else [self complete:@[consumer] image:nil];
            return;
        }
        if(self.inFlight.count>=SAPArtistArtworkMaximumRequests){[self complete:@[consumer] image:nil];return;}
        SAPArtistArtworkRequest *request=[SAPArtistArtworkRequest new];request.identifier=identifier;
        request.data=[NSMutableData data];request.completions=[@{token:consumer}mutableCopy];self.inFlight[identifier]=request;
#ifdef SAP_TESTING
        if(SAPArtistArtworkDataProviderForTesting) {
            SAPArtistArtworkDataProviderForTesting(value,^(NSData *data){dispatch_async(self.queue,^{
                if(self.inFlight[identifier]!=request)return;
                UIImage *image=[self thumbnailForData:data];
                if(image){NSUInteger cost=(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4;[self.cache setObject:image forKey:identifier cost:cost];}
                [self.inFlight removeObjectForKey:identifier];[self complete:request.completions.allValues image:image];
            });});return;
        }
#endif
        NSString *address=[identifier hasPrefix:@"mosaic:"]?[@"https://mosaic.scdn.co/300/" stringByAppendingString:[identifier substringFromIndex:7]]:[@"https://i.scdn.co/image/" stringByAppendingString:identifier];
        NSURL *url=[NSURL URLWithString:address];
        NSMutableURLRequest *http=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
        [http setValue:@"image/jpeg,image/png,image/webp" forHTTPHeaderField:@"Accept"];
        request.task=[self.session dataTaskWithRequest:http];self.requests[@(request.task.taskIdentifier)]=request;[request.task resume];
    });
    return ^{
        consumer.cancelled=YES;
        if(!identifier)return;
        dispatch_async(self.queue,^{
            SAPArtistArtworkRequest *request=self.inFlight[identifier];
            [request.completions removeObjectForKey:token];
            if(request && !request.completions.count){
                [request.task cancel];if(request.cancelNative)request.cancelNative();request.cancelNative=nil;
                if(request.task)[self.requests removeObjectForKey:@(request.task.taskIdentifier)];
                [self.inFlight removeObjectForKey:identifier];
            }
        });
    };
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    SAPArtistArtworkRequest *request=self.requests[@(task.taskIdentifier)];NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(id)response:nil;
    NSString *type=response.MIMEType.lowercaseString;
    request.allowed=http.statusCode==200 && [type hasPrefix:@"image/"] && (response.expectedContentLength<0 || response.expectedContentLength<=(long long)SAPArtistArtworkMaximumBytes);
    completionHandler(request.allowed?NSURLSessionResponseAllow: NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    SAPArtistArtworkRequest *active=self.requests[@(task.taskIdentifier)];
    completionHandler(active && [SAPArtistArtworkIdentifier(request.URL.absoluteString)isEqual:active.identifier]?request:nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    SAPArtistArtworkRequest *request=self.requests[@(task.taskIdentifier)];
    if(!request.allowed || data.length>SAPArtistArtworkMaximumBytes || request.data.length>SAPArtistArtworkMaximumBytes-data.length){[task cancel];return;}
    [request.data appendData:data];
}
- (UIImage *)thumbnailForData:(NSData *)data {
    return [self thumbnailForData:data maximumPixels:SAPArtistArtworkMaximumPixels];
}
- (UIImage *)thumbnailForData:(NSData *)data maximumPixels:(NSUInteger)pixels {
#ifdef SAP_TESTING
    NSCAssert(!NSThread.isMainThread,@"Artist artwork decoding must stay off the main thread");
#endif
    if(!data.length || data.length>SAPArtistArtworkMaximumBytes)return nil;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!source)return nil;
    NSDictionary *options=@{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (id)kCGImageSourceThumbnailMaxPixelSize:@(pixels),
        (id)kCGImageSourceShouldCacheImmediately:@YES};
    CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);CFRelease(source);
    if(!image)return nil;UIImage *thumbnail=[UIImage imageWithCGImage:image scale:1.0 orientation:UIImageOrientationUp];CFRelease(image);return thumbnail;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *key=@(task.taskIdentifier);SAPArtistArtworkRequest *request=self.requests[key];if(!request)return;
    [self.requests removeObjectForKey:key];[self.inFlight removeObjectForKey:request.identifier];
    UIImage *image=error||!request.allowed?nil:[self thumbnailForData:request.data];
    if(image) {
        NSUInteger cost=(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4;
        [self.cache setObject:image forKey:request.identifier cost:cost];
    }
    [self complete:request.completions.allValues image:image];
}
@end

#ifdef SAP_TESTING
dispatch_block_t SAPArtistArtworkLoadForTesting(NSString *url,void (^completion)(UIImage *)) {
    return [[SAPArtistArtworkLoader shared]loadURL:url completion:completion];
}
#endif

