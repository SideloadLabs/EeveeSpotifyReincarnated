#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdatomic.h>

// Native image retrieval and UIKit are unavailable on the host. These doubles
// return distinct image bytes so a wrong cache key cannot satisfy the test.
@interface UIImage : NSObject
@property(nonatomic) CGSize size;
@property(nonatomic) CGFloat scale;
@property(nonatomic,strong) NSData *bytes;
@end
@implementation UIImage @end
static atomic_int encodes;
static NSUInteger requests;
static BOOL failNext;
static NSData *UIImageJPEGRepresentation(UIImage *image,CGFloat quality) {
    assert(quality==0.9);atomic_fetch_add(&encodes,1);return image.bytes;
}
@interface SAPArtistArtworkLoader : NSObject
+ (instancetype)shared;
- (dispatch_block_t)loadImageURI:(NSString *)uri maximumPixels:(NSUInteger)pixels completion:(void (^)(UIImage *))completion;
@end
@implementation SAPArtistArtworkLoader
+ (instancetype)shared {static id loader;static dispatch_once_t once;dispatch_once(&once,^{loader=[self new];});return loader;}
- (dispatch_block_t)loadImageURI:(NSString *)uri maximumPixels:(NSUInteger)pixels completion:(void (^)(UIImage *))completion {
    requests++;assert(pixels==640);__block BOOL cancelled=NO;
    UIImage *image=nil;
    if(!failNext){image=UIImage.new;image.size=CGSizeMake(640,640);image.scale=1;image.bytes=[uri dataUsingEncoding:NSUTF8StringEncoding];}
    failNext=NO;
    dispatch_async(dispatch_get_main_queue(),^{if(!cancelled)completion(image);});
    return ^{cancelled=YES;};
}
@end

#include "ExportArtworkUnderTest.inc"

static NSString *const coverA=@"spotify:image:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static NSString *const coverB=@"spotify:image:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
static NSDictionary *load(NSString *uri) {
    __block BOOL done=NO;__block NSDictionary *result;
    SAPLoadExportArtwork(uri,^(NSDictionary *art){assert(NSThread.isMainThread);result=art;done=YES;});
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];
    while(!done&&end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(done);return result;
}
int main(void){@autoreleasepool {
    atomic_init(&encodes,0);
    for(NSUInteger i=0;i<15;i++) {
        NSDictionary *art=load(coverA);
        assert([art[@"jpeg"]isEqual:[coverA dataUsingEncoding:NSUTF8StringEncoding]]);
        assert([art[@"width"]intValue]==640&&[art[@"height"]intValue]==640&&art[@"preview"]);
    }
    assert(requests==1 && "same album must request its cover only once");
    assert(atomic_load(&encodes)==1 && "same album must encode JPEG only once");
    assert([load(coverB)[@"jpeg"]isEqual:[coverB dataUsingEncoding:NSUTF8StringEncoding]]);
    assert(requests==2&&atomic_load(&encodes)==2);

    __block BOOL delivered=NO;
    dispatch_block_t cancel=SAPLoadExportArtwork(coverA,^(NSDictionary *art){delivered=YES;});
    assert(!delivered && "cache hit preserves asynchronous completion");cancel();
    __block BOOL drained=NO;dispatch_async(dispatch_get_main_queue(),^{drained=YES;});
    while(!drained)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(!delivered && "cancel suppresses a pending cached completion");
    assert(requests==2&&atomic_load(&encodes)==2);

    NSString *retry=@"spotify:image:cccccccccccccccccccccccccccccccccccccccc";
    failNext=YES;assert(!load(retry));assert(load(retry));
    assert(requests==4 && "failed artwork must be retried");

    // Mutable entity URIs must not pin an old playlist image in this cache.
    load(@"spotify:playlist:mutable");load(@"spotify:playlist:mutable");
    assert(requests==6);

    NSString *uncached=@"spotify:image:dddddddddddddddddddddddddddddddddddddddd";
    delivered=NO;drained=NO;
    cancel=SAPLoadExportArtwork(uncached,^(NSDictionary *art){delivered=YES;});cancel();
    dispatch_async(dispatch_get_main_queue(),^{drained=YES;});
    while(!drained)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(!delivered);assert(load(uncached));assert(requests==8);

    NSString *invalid=@"spotify:image:gggggggggggggggggggggggggggggggggggggggg";
    load(invalid);load(invalid);assert(requests==10);
    puts("export_artwork_cache PASS: 15 covers -> 1 request/encode; identity, cached/uncached cancellation, retry, mutable/malformed URI");
}}
