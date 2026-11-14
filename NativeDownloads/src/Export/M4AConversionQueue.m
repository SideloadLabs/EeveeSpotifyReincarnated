#import "M4AConversionQueue.h"
@interface SAPM4AConversionContext : NSObject
@property(nonatomic,strong) NSProgress *progress;
@property(nonatomic,copy) BOOL (^cancelled)(void);
@end
@implementation SAPM4AConversionContext
@end
static int SAPM4AConversionCancelled(void *value) {
    SAPM4AConversionContext *context = (__bridge SAPM4AConversionContext *)value;
    return context.progress.cancelled || (context.cancelled && context.cancelled());
}
static void SAPM4AConversionProgress(double fraction, void *value) {
    SAPM4AConversionContext *context = (__bridge SAPM4AConversionContext *)value;
    context.progress.completedUnitCount = (int64_t)(fraction * context.progress.totalUnitCount);
}
static void SAPM4AUpdateConcurrency(NSOperationQueue *queue) {
    NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    NSInteger limit = thermal == NSProcessInfoThermalStateCritical ? 1 :
        thermal == NSProcessInfoThermalStateSerious ? 2 : SAPM4AConversionParallelLimit;
    @synchronized(queue) { queue.maxConcurrentOperationCount = limit; }
}
NSProgress *SAPQueueM4AConversion(NSURL *input, NSURL *output, NSDictionary *track,
    NSDictionary *artwork, BOOL (^cancelled)(void), void (^completion)(SAPM4AExportStatus)) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = NSOperationQueue.new;
        queue.name = @"Pixie M4A conversion";
        queue.qualityOfService = NSQualityOfServiceUserInitiated;
        SAPM4AUpdateConcurrency(queue);
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification
            object:nil queue:nil usingBlock:^(NSNotification *notification) { SAPM4AUpdateConcurrency(queue); }];
    });
    SAPM4AUpdateConcurrency(queue);
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1000000];
    progress.cancellable = YES;
    SAPM4AConversionContext *context = SAPM4AConversionContext.new;
    context.progress = progress;
    context.cancelled = cancelled;
    NSDictionary *metadata = [track copy], *art = [artwork copy];
    [queue addOperationWithBlock:^{ @autoreleasepool {
        SAPM4AExportStatus code = SAPM4AExportCancelled;
        if (!SAPM4AConversionCancelled((__bridge void *)context)) {
            NSString *number = [metadata[@"number"] description];
            NSString *year = [metadata[@"year"] integerValue] > 0 ? [metadata[@"year"] description] : nil;
            NSData *cover = art[@"jpeg"];
            SAPM4AExportMetadata tags = {
                .title = [metadata[@"name"] UTF8String], .artist = [metadata[@"artist_name"] UTF8String],
                .album = [metadata[@"album_name"] UTF8String], .track = number.UTF8String,
                .year = year.UTF8String, .jpeg_cover = cover.bytes, .jpeg_cover_length = cover.length};
            code = SAPExportOggToM4A(input.path.fileSystemRepresentation, output.path.fileSystemRepresentation,
                &tags, SAPM4AConversionCancelled, SAPM4AConversionProgress, (__bridge void *)context);
            if (code == SAPM4AExportOK && SAPM4AConversionCancelled((__bridge void *)context)) {
                [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                code = SAPM4AExportCancelled;
            }
        }
        progress.completedUnitCount = progress.totalUnitCount;
        if (completion) completion(code);
    }}];
    return progress;
}
