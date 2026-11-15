#import "ExportArtwork.h"
#import "ExportShareFolder.h"
#import "ArtistArtworkLoader.h"
#import <stdatomic.h>
#import <LinkPresentation/LinkPresentation.h>
// Only explicit export requests allocate this token or request an image.
@interface SAPExportArtworkToken:NSObject { @public atomic_bool cancelled; }
@end
@implementation SAPExportArtworkToken @end
// Cache the completed 640px export representation, including its JPEG bytes.
// Manager batches create a new track-export job for every song; their per-job
// artwork dictionaries cannot reuse an album cover across those jobs.
static NSCache<NSString *,NSDictionary *> *SAPExportArtworkCache(void) {
    static NSCache *cache;static dispatch_once_t once;
    dispatch_once(&once,^{cache=NSCache.new;cache.countLimit=16;cache.totalCostLimit=16*1024*1024;});
    return cache;
}
static NSString *SAPExportArtworkCacheKey(NSString *uri) {
    // Only immutable image identities are reusable. Playlist/entity artwork may
    // change while its URI stays the same, so it retains the uncached path.
    if(![uri isKindOfClass:NSString.class]||![uri hasPrefix:@"spotify:image:"]||uri.length!=54)return nil;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet;
    return [uri rangeOfCharacterFromSet:invalid options:0 range:NSMakeRange(14,40)].location==NSNotFound?uri.lowercaseString:nil;
}
dispatch_block_t SAPLoadExportArtwork(NSString *uri,void (^completion)(NSDictionary *)) {
    SAPExportArtworkToken *token=[SAPExportArtworkToken new];
    NSString *key=SAPExportArtworkCacheKey(uri);
    NSDictionary *cached=key?[SAPExportArtworkCache()objectForKey:key]:nil;
    if(cached) {
        dispatch_async(dispatch_get_main_queue(),^{if(!atomic_load(&token->cancelled)&&completion)completion(cached);});
        return ^{atomic_store(&token->cancelled,true);};
    }
    dispatch_block_t cancel=[[SAPArtistArtworkLoader shared]loadImageURI:uri maximumPixels:640 completion:^(UIImage *image){
        if(atomic_load(&token->cancelled))return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {
            NSData *jpeg=image?UIImageJPEGRepresentation(image,0.9):nil;
            NSDictionary *art=jpeg.length && jpeg.length<=1024*1024?@{@"jpeg":jpeg,@"preview":image,@"width":@((unsigned)(image.size.width*image.scale)),@"height":@((unsigned)(image.size.height*image.scale))}:nil;
            dispatch_async(dispatch_get_main_queue(),^{
                if(atomic_load(&token->cancelled))return;
                if(key&&art){NSUInteger cost=jpeg.length+[art[@"width"]unsignedIntegerValue]*[art[@"height"]unsignedIntegerValue]*4;[SAPExportArtworkCache()setObject:art forKey:key cost:cost];}
                if(completion)completion(art);
            });
        }});
    }];
    return ^{atomic_store(&token->cancelled,true);if(cancel)cancel();};
}

@interface SAPExportAudioShareItem:NSObject <UIActivityItemSource>
@property(nonatomic,strong) NSURL *file;
@property(nonatomic,strong) UIImage *cover;
@end
@implementation SAPExportAudioShareItem
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller {return self.file;}
- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)type {return self.file;}
- (NSString *)activityViewController:(UIActivityViewController *)controller subjectForActivityType:(UIActivityType)type {
    return self.file.lastPathComponent.stringByDeletingPathExtension;
}
- (UIImage *)activityViewController:(UIActivityViewController *)controller thumbnailImageForActivityType:(UIActivityType)type suggestedSize:(CGSize)size {
    return self.cover;
}
- (LPLinkMetadata *)activityViewControllerLinkMetadata:(UIActivityViewController *)controller {
    LPLinkMetadata *metadata=[LPLinkMetadata new];metadata.originalURL=self.file;metadata.URL=self.file;
    metadata.title=self.file.lastPathComponent.stringByDeletingPathExtension;
    NSItemProvider *image=[[NSItemProvider alloc]initWithObject:self.cover];
    metadata.imageProvider=image;metadata.iconProvider=image;
    return metadata;
}
@end
NSArray *SAPAudioExportShareItems(NSArray<NSURL *> *files) {
    NSMutableArray *items=[NSMutableArray arrayWithCapacity:files.count];
    for(NSURL *file in files) {
        NSDictionary *art=SAPAttachedExportArtwork(file);UIImage *cover=art[@"preview"];
        if(!cover){[items addObject:file];continue;}
        SAPExportAudioShareItem *item=[SAPExportAudioShareItem new];item.file=file;item.cover=cover;[items addObject:item];
    }
    return items;
}

void SAPPrepareAudioExportShareItems(NSArray<NSURL *> *files,BOOL album,void (^completion)(NSArray *,NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        NSString *name=SAPAttachedExportArtwork(files.firstObject)[@"album_name"]?:files.firstObject.URLByDeletingLastPathComponent.lastPathComponent;
        NSString *error=nil;NSURL *folder=album?SAPCreateAudioShareFolder(files,name,&error):(files.count==1?SAPCreateAudioShareFile(files.firstObject,&error):nil);
        if(folder){NSDictionary *art=SAPAttachedExportArtwork(files.firstObject);if(art)SAPAttachExportArtwork(folder,art);}
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(folder?SAPAudioExportShareItems(@[folder]):nil,error);});
    }});
}
