#import "OfflineLibraryExport.h"
#import "OfflineLibraryPackage.h"
#import "../Export/TrackExport.h"
#import "../Export/M4AConversionQueue.h"
#import "../Export/ExportArtwork.h"
#import "../Export/ExportShareFolder.h"

@class SAPOfflineLibraryExportJob;
static NSMapTable<NSProgress *,SAPOfflineLibraryExportJob *> *activeJobs;

@interface SAPOfflineLibraryExportJob : NSObject
@property(nonatomic,strong) NSProgress *operation,*packageProgress;
@property(nonatomic,copy) NSArray<NSDictionary *> *tracks;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *prepared;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSProgress *> *conversions;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *failures;
@property(nonatomic,copy) NSString *format;
@property(nonatomic,copy) void (^progress)(NSUInteger,NSUInteger,NSString *);
@property(nonatomic,copy) void (^completion)(NSURL *,NSArray *,NSString *);
@property(nonatomic,copy) void (^event)(NSDictionary *);
@property(nonatomic) BOOL packaging,finished,ownsCurrentExport,zip;
@property(nonatomic) double packageFraction;
@property(nonatomic) NSUInteger completed,nextIndex,packageGeneration;
@property(nonatomic,strong) NSMutableSet<NSString *> *knownURIs;
- (NSUInteger)appendTracks:(NSArray<NSDictionary *> *)tracks;
@end
@implementation SAPOfflineLibraryExportJob
- (void)finish:(NSURL *)package error:(NSString *)error {
    if(self.finished){if(package)SAPReleaseOfflineLibraryPackage(package);return;}
    self.finished=YES;self.packageGeneration++;
    [activeJobs removeObjectForKey:self.operation];
    // Finish may happen while other conversions are still running. Their output
    // URL leases survive until their worker callbacks return; source files stay intact.
    if(self.ownsCurrentExport){self.ownsCurrentExport=NO;SAPCancelAudioExport();}
    for(NSProgress *progress in self.conversions.allValues)[progress cancel];
    if(!package)[self.packageProgress cancel];
    if(self.event)self.event(@{@"phase":self.operation.cancelled?@"cancelled":package?@"ready":@"failed",@"message":error?:@"Files ready",@"failed":@(self.failures.count)});
    self.operation.cancellationHandler=nil;self.operation.completedUnitCount=self.operation.totalUnitCount;
    self.packageProgress=nil;[self.prepared removeAllObjects];[self.conversions removeAllObjects];
    void (^completion)(NSURL *,NSArray *,NSString *)=self.completion;
    self.completion=nil;self.progress=nil;self.event=nil;
    if(completion)completion(package,[self.failures copy],error);else if(package)SAPReleaseOfflineLibraryPackage(package);
}
- (void)cancel {if(!self.finished)[self finish:nil error:@"Export cancelled."];}
- (NSUInteger)appendTracks:(NSArray<NSDictionary *> *)tracks {
    if(self.finished || self.operation.cancelled)return 0;
    NSMutableArray *added=NSMutableArray.array,*identities=NSMutableArray.array;
    for(id value in tracks) {
        if(![value isKindOfClass:NSDictionary.class])continue;
        NSString *uri=value[@"uri"];
        if(![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"spotify:track:"] || [self.knownURIs containsObject:uri])continue;
        [self.knownURIs addObject:uri];[identities addObject:uri];[added addObject:[value copy]];
    }
    if(!added.count)return 0;
    self.tracks=[self.tracks arrayByAddingObjectsFromArray:added];self.operation.totalUnitCount=(int64_t)self.tracks.count+1;
    if(self.packaging) {
        // Invalidate before cancel: even a synchronous old callback is stale.
        self.packageGeneration++;self.packaging=NO;self.packageFraction=0;
        NSProgress *previous=self.packageProgress;self.packageProgress=nil;[previous cancel];
    }
    if(self.event)self.event(@{@"phase":@"queue_extended",@"uris":identities,@"total":@(self.tracks.count),@"completed":@(self.completed)});
    [self schedule];return added.count;
}

- (void)report:(NSString *)message uri:(NSString *)uri phase:(NSString *)phase {
    if(self.finished)return;
    if(self.progress)self.progress(self.completed,self.tracks.count,message);
    if(self.event) {
        NSMutableDictionary *event=[@{@"phase":phase,@"completed":@(self.completed),@"total":@(self.tracks.count),@"message":message?:@"Preparing files…"}mutableCopy];
        if(uri)event[@"uri"]=uri;if(self.packaging)event[@"fraction"]=@(self.packageFraction);self.event(event);
    }
}
- (void)schedule {dispatch_async(dispatch_get_main_queue(),^{[self pump];});}
- (void)completeTrack:(NSDictionary *)track file:(NSURL *)file error:(NSString *)error {
    if(self.finished)return;
    if(self.operation.cancelled){[self cancel];return;}
    BOOL success=file.isFileURL && !error.length;
    if(success){NSMutableDictionary *record=[track mutableCopy];record[@"file"]=file;self.prepared[track[@"uri"]]=record;}
    else {NSMutableDictionary *failure=[track mutableCopy];failure[@"error"]=error?:@"No audio file was produced.";[self.failures addObject:failure];}
    self.completed++;self.operation.completedUnitCount=(int64_t)self.completed;
    if(self.event)self.event(@{@"phase":@"prepared",@"uri":track[@"uri"],@"success":@(success),@"error":error?:@""});
    [self schedule];
}
- (void)convert:(NSURL *)input track:(NSDictionary *)track {
    NSURL *folder=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:[@"PixieConvert-"stringByAppendingString:NSUUID.UUID.UUIDString]]isDirectory:YES];NSError *error=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]){[self completeTrack:track file:nil error:error.localizedDescription];return;}
    NSURL *output=[folder URLByAppendingPathComponent:[input.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"m4a"]];
    SAPRetainTemporaryAudioFiles(@[output],folder);
    NSDictionary *art=SAPAttachedExportArtwork(input);[self report:@"Converting to M4A…" uri:track[@"uri"] phase:@"converting"];
    NSProgress *conversion=SAPQueueM4AConversion(input,output,track,art,^BOOL{return self.operation.cancelled;},^(SAPM4AExportStatus code){
        dispatch_async(dispatch_get_main_queue(),^{
            if(self.finished)return;[self.conversions removeObjectForKey:track[@"uri"]];
            if(code==SAPM4AExportOK){NSMutableDictionary *preview=[art mutableCopy]?:NSMutableDictionary.dictionary;
                NSString *filename=art[@"share_filename"]?:input.lastPathComponent;preview[@"share_filename"]=[filename.stringByDeletingPathExtension stringByAppendingPathExtension:@"m4a"];
                SAPAttachExportArtwork(output,preview);
            }
            [self completeTrack:track file:code==SAPM4AExportOK?output:nil error:code==SAPM4AExportOK?nil:[NSString stringWithFormat:@"M4A conversion failed (code %u).",(unsigned)code]];
        });
    });
    self.conversions[track[@"uri"]]=conversion;
}
- (void)package {
    if(!self.prepared.count){[self finish:nil error:@"No selected tracks could be exported."];return;}
    BOOL archive=self.zip && self.prepared.count>1;
    NSUInteger generation=++self.packageGeneration;
    self.packaging=YES;[self report:archive?@"Creating ZIP…":self.prepared.count==1?@"Preparing audio file…":@"Preparing folder…" uri:nil phase:@"packaging"];
    if(self.finished || !self.packaging || generation!=self.packageGeneration)return;
    // Conversion completion order must never change the requested release/track order.
    NSMutableArray *ordered=NSMutableArray.array;for(NSDictionary *track in self.tracks)if(self.prepared[track[@"uri"]])[ordered addObject:self.prepared[track[@"uri"]]];
    NSProgress *packageProgress=SAPPrepareOfflineLibraryPackage(ordered,archive,^(double fraction){
        if(self.finished || generation!=self.packageGeneration)return;
        self.packageFraction=fraction;[self report:[NSString stringWithFormat:@"Packaging · %.0f%%",fraction*100] uri:nil phase:@"packaging"];
    },^(NSURL *package,NSError *error){
        if(self.finished || generation!=self.packageGeneration){if(package)SAPReleaseOfflineLibraryPackage(package);return;}
        [self finish:package error:error.localizedDescription];
    });
    if(!self.finished && self.packaging && generation==self.packageGeneration)self.packageProgress=packageProgress;
    else [packageProgress cancel];
}
- (void)pump {
    if(self.finished || self.packaging)return;
    if(self.operation.cancelled){[self cancel];return;}
    if(![SAPAudioExportFormat()isEqual:self.format]){[self finish:nil error:@"The export format changed. Start again with the chosen format."];return;}
    if(self.completed==self.tracks.count){[self package];return;}
    if(self.ownsCurrentExport || self.nextIndex==self.tracks.count || self.conversions.count>=20)return;
    NSDictionary *track=self.tracks[self.nextIndex++];[self report:track[@"name"]?:@"Preparing track…" uri:track[@"uri"] phase:@"preparing"];
    self.ownsCurrentExport=YES;
    SAPExportAudioURIForBatch(track[@"uri"],self.format,^(NSString *message){[self report:message uri:track[@"uri"] phase:@"preparing"];},^(NSArray<NSURL *> *files,NSString *error){
        self.ownsCurrentExport=NO;if(self.finished)return;
        if(self.operation.cancelled){[self cancel];return;}
        if([error isEqual:@"Another export is already running."]){[self finish:nil error:error];return;}
        NSURL *file=files.count==1?files.firstObject:nil;
        NSDictionary *resolved=SAPAttachedExportArtwork(file)[@"encoding_metadata"];
        NSDictionary *encodingTrack=track;
        if([resolved isKindOfClass:NSDictionary.class] && [resolved[@"uri"]isEqual:track[@"uri"]]) {
            NSMutableDictionary *merged=[track mutableCopy];[merged addEntriesFromDictionary:resolved];encodingTrack=merged;
        }
        if(!error.length && [self.format isEqual:@"m4a"] && [file.pathExtension.lowercaseString isEqual:@"ogg"]){[self convert:file track:encodingTrack];[self schedule];}
        else [self completeTrack:encodingTrack file:file error:error];
    });
}
@end
static NSProgress *SAPStartOfflineLibraryExport(NSArray<NSDictionary *> *tracks,BOOL zip,void (^progress)(NSUInteger,NSUInteger,NSString *),void (^event)(NSDictionary *),void (^completion)(NSURL *,NSArray *,NSString *)) {
    SAPOfflineLibraryExportJob *job=SAPOfflineLibraryExportJob.new;NSMutableSet *seen=NSMutableSet.set;NSMutableArray *unique=NSMutableArray.array;
    for(id candidate in tracks)if([candidate isKindOfClass:NSDictionary.class]){NSString *uri=candidate[@"uri"];
        if([uri isKindOfClass:NSString.class]&&[uri hasPrefix:@"spotify:track:"]&&![seen containsObject:uri]){[seen addObject:uri];[unique addObject:[candidate copy]];}}
    job.tracks=unique;job.knownURIs=seen;job.zip=zip;job.format=SAPAudioExportFormat();job.progress=progress;job.event=event;job.completion=completion;
    job.prepared=NSMutableDictionary.dictionary;job.conversions=NSMutableDictionary.dictionary;job.failures=NSMutableArray.array;
    job.operation=[NSProgress progressWithTotalUnitCount:(int64_t)unique.count+1];job.operation.cancellable=YES;
    __weak SAPOfflineLibraryExportJob *weakJob=job;job.operation.cancellationHandler=^{dispatch_async(dispatch_get_main_queue(),^{[weakJob cancel];});};
    if(!activeJobs)activeJobs=[NSMapTable weakToWeakObjectsMapTable];
    [activeJobs setObject:job forKey:job.operation];
    [job schedule];return job.operation;
}
NSProgress *SAPExportOfflineLibrarySelection(NSArray<NSDictionary *> *tracks,BOOL zip,void (^progress)(NSUInteger,NSUInteger,NSString *),void (^completion)(NSURL *,NSArray *,NSString *)) {
    return SAPStartOfflineLibraryExport(tracks,zip,progress,nil,completion);
}
NSProgress *SAPExportOfflineLibrarySelectionWithEvents(NSArray<NSDictionary *> *tracks,BOOL zip,void (^event)(NSDictionary *),void (^completion)(NSURL *,NSArray *,NSString *)) {
    return SAPStartOfflineLibraryExport(tracks,zip,nil,event,completion);
}

NSUInteger SAPAppendOfflineLibrarySelection(NSProgress *operation,NSArray<NSDictionary *> *tracks){
    dispatch_assert_queue(dispatch_get_main_queue());
    SAPOfflineLibraryExportJob *job=operation?[activeJobs objectForKey:operation]:nil;
    return job?[job appendTracks:tracks]:0;
}
