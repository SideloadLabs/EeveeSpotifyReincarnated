#pragma once
#import <UIKit/UIKit.h>

// Shared loader ownership preserves coalescing and cancellation across both pages.
extern char SAPArtistArtworkURLKey;
NSString *SAPArtistArtworkIdentifier(NSString *value);

@interface SAPArtistArtworkLoader : NSObject <NSURLSessionDataDelegate>
+ (instancetype)shared;
- (dispatch_block_t)loadURL:(NSString *)value completion:(void (^)(UIImage *))completion;
- (dispatch_block_t)loadPlaylistURI:(NSString *)uri completion:(void (^)(UIImage *))completion;
- (dispatch_block_t)loadImageURI:(NSString *)uri maximumPixels:(NSUInteger)pixels completion:(void (^)(UIImage *))completion;
- (UIImage *)thumbnailForData:(NSData *)data;
@end

#ifdef SAP_TESTING
void SAPArtistArtworkSetDataProviderForTesting(void (^provider)(NSString *,void (^)(NSData *)));
dispatch_block_t SAPArtistArtworkLoadForTesting(NSString *url,void (^completion)(UIImage *));
#endif
