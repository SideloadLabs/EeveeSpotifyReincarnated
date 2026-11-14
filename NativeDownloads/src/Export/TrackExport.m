#import "TrackExport.h"
#import "TrackDownload.h"
#import "ExportNativeAdapters.h"
#import "NativeOffline.h"
#import "ExportAlbumMetadata.h"
#import "WireProto.h"
#import "ExportArtwork.h"
#import "ExportLibrary.h"
#import "ExportRefreshPolicy.h"
#import "ExportShareFolder.h"
#import "M4AConversionQueue.h"
#import "TemporaryOfflineExport.h"
#import "ExportKeyVault.h"
#import "ExportKeyStore.h"
#import "TrackCacheExport.h"
#import "ExportCacheIndex.h"
#import "M4AExport.h"
#import <AVFoundation/AVFoundation.h>
#import "ExportLayout.h"
#import "CacheStorageKey.h"
#import "ExportObservation.h"
#import "ExportMediaUnsealPatch.h"
#import "NativeCacheMap.h"
#import "DiagnosticTrace.h"
#import "Deadline.h"
#ifdef SAP_EXPORT_TESTING
extern NSString *SAPExportTestHome;
#define NSHomeDirectory() SAPExportTestHome
#endif
#include <stdatomic.h>

@class SAPExportJob;
static SAPExportJob *activeJob;
static atomic_bool exporting;
static void SAPStartAudioExportURI(NSString *,NSString *,BOOL,void (^)(NSString *),void (^)(NSUInteger,void (^)(BOOL)),void (^)(NSArray<NSURL *> *,NSString *));
static dispatch_queue_t exportWorkQueue(void){static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("com.pixie.export-work",DISPATCH_QUEUE_SERIAL);});return queue;}
static NSURL *exportLibraryRoot(void){return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Pixie Exports"] isDirectory:YES];}
NSString *SAPAudioExportFormat(void){return [[NSUserDefaults.standardUserDefaults stringForKey:@"PixieExportFormat"] isEqual:@"ogg"]?@"ogg":@"m4a";}

static NSArray *fileIDs(NSArray *fields){NSMutableArray *ids=[NSMutableArray array];for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==12&&[f[@"wire"]unsignedIntValue]==2){NSData *d=SAPProtoData(SAPProtoFields(f[@"value"]),1);if(d.length==20&&![ids containsObject:d])[ids addObject:d];}return ids;}
static NSDictionary *trackMetadata(NSData *data,NSString *uri) {
    NSArray *envelope=SAPProtoFields(data),*item=SAPProtoFields(SAPProtoData(envelope,1));
    if(SAPProtoNumber(item,1,0))return nil;NSArray *track=SAPProtoFields(SAPProtoData(item,4));NSString *name=SAPProtoString(track,2);int64_t duration=SAPProtoSInt(track,7,0);NSArray *ids=fileIDs(track);
    // Spotify leaves the file list empty for a track that is not downloaded yet; beginWrite fetches it again afterwards.
    if(!name.length||duration<=0||duration>86400000)return nil;
    NSArray *album=SAPProtoFields(SAPProtoData(track,3));
    return @{@"uri":uri,@"name":name,@"duration_ms":@(duration),@"files":ids,
        @"cover_image_uri":SAPExportAlbumCoverURI(album)?:@"",@"album_uri":SAPExportAlbumURI(album)?:@"",
        @"artist_name":SAPExportArtistName(track,4)?:SAPExportArtistName(album,3)?:@"Unknown artist",
        @"album_name":SAPProtoString(album,2)?:name,@"year":@(SAPProtoSInt(SAPProtoFields(SAPProtoData(album,6)),1,0)),@"number":@(MAX(1,SAPProtoSInt(track,5,1))),@"disc":@(MAX(1,SAPProtoSInt(track,6,1)))};
}

@interface SAPExportJob:NSObject { atomic_bool ended; }
@property(nonatomic,strong) NSArray<NSDictionary *> *tracks;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *resolved;
@property(nonatomic,copy) void (^completion)(NSArray *,NSString *);
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSString *format;
@property(nonatomic,copy) NSString *targetURI;
@property(nonatomic,copy) void (^progress)(NSString *);
@property(nonatomic,strong) dispatch_source_t poll;
@property(nonatomic) BOOL preparationStarted,commandRequested,observingExisting,startObserved;
@property(nonatomic) NSUInteger completeSamples,progressMark;
@property(nonatomic) NSTimeInterval lastProgress;
@property(nonatomic) NSTimeInterval downloadStarted;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL deferM4AConversion;
@property(nonatomic) BOOL shareOnly,temporaryCaptured,temporaryAddAccepted,nativeAddInFlight,temporaryOutcomeUnknown,temporaryCleanupStarted;
@property(nonatomic,strong) NSDictionary *temporaryToken;
@property(nonatomic,strong) NSArray *finishingFiles;
@property(nonatomic,copy) NSString *finishingError;
@property(nonatomic,strong) dispatch_source_t cleanupWait;
@property(nonatomic) NSUInteger artworkIndex;
@property(nonatomic,strong) NSMutableDictionary *artworkCache;
@property(nonatomic,copy) dispatch_block_t cancelArtwork;
@property(nonatomic,copy) void (^confirmRefresh)(NSUInteger,void (^)(BOOL));
@property(nonatomic) BOOL refreshAttempted,automaticKeyRefresh;
@property(nonatomic,strong) NSSet<NSString *> *confirmedDownloadedURIs;
@property(nonatomic,strong) NSArray<NSString *> *refreshURIs;
@property(nonatomic) NSTimeInterval refreshStarted;
@property(nonatomic,strong) dispatch_source_t refreshTimer;
- (void)beginWrite;
- (void)requestKeyRefresh;
- (void)resolveNext;
- (void)prepareNativeDownload;
- (void)prepareNextArtwork;
- (void)reuseExportsOrPrepareDownload;
- (void)pollNativeDownload;
- (void)pollNativeAlbumContext;
- (void)writeFiles;
- (void)completeTemporaryFinish;
- (void)deliverFiles:(NSArray *)files error:(NSString *)error;
@end
@implementation SAPExportJob
- (void)finish:(NSArray *)files error:(NSString *)error {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self finish:files error:error];});return;}
    if(self.finished)return;self.finished=YES;atomic_store(&ended,true);
    if(self.cancelArtwork){self.cancelArtwork();self.cancelArtwork=nil;}self.artworkCache=nil;
    if(self.poll){dispatch_source_cancel(self.poll);self.poll=nil;}self.progress=nil;
    if(self.refreshTimer){dispatch_source_cancel(self.refreshTimer);self.refreshTimer=nil;}
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    self.finishingFiles=files;self.finishingError=error;
    if(self.shareOnly&&self.temporaryToken&&(self.temporaryAddAccepted||self.nativeAddInFlight)){
        if(self.nativeAddInFlight){
            __weak SAPExportJob *weak=self;self.cleanupWait=SAPScheduleDeadline(dispatch_get_main_queue(),15,^{SAPExportJob *job=weak;if(!job)return;job.nativeAddInFlight=NO;job.temporaryOutcomeUnknown=YES;[job completeTemporaryFinish];});
        }else [self completeTemporaryFinish];
        return;
    }
    [self deliverFiles:files error:error];
}
- (void)completeTemporaryFinish {
    if(!self.shareOnly||!self.temporaryToken||!self.completion||self.nativeAddInFlight||self.temporaryCleanupStarted)return;self.temporaryCleanupStarted=YES;
    if(self.cleanupWait){dispatch_source_cancel(self.cleanupWait);self.cleanupWait=nil;}
    if(self.temporaryOutcomeUnknown){[self deliverFiles:self.finishingFiles error:@"Spotify's temporary download result is unknown. No automatic removal was attempted."];return;}
    SAPCleanupTemporaryOfflineExport(self.temporaryToken,self.temporaryAddAccepted,^(NSString *cleanupError){
        NSString *error=self.finishingError;if(cleanupError.length)error=error.length?[error stringByAppendingFormat:@"\n%@",cleanupError]:cleanupError;
        SAP_TRACE("export","temporary_spotify_restore",0,@{@"error":cleanupError?:NSNull.null,@"verified":@(!cleanupError.length)});
        [self deliverFiles:self.finishingFiles error:error];
    });
}
- (void)deliverFiles:(NSArray *)files error:(NSString *)error {
    if(!self.completion)return;
    self.finishingFiles=nil;self.finishingError=nil;
    atomic_store(&exporting,false);if(activeJob==self)activeJob=nil;void (^reply)(NSArray *,NSString *)=self.completion;self.completion=nil;
    SAP_TRACE("export","audio_export_completed",0,@{@"share_only":@(self.shareOnly),@"format":self.format?:@"ogg",@"conversion_deferred":@(self.deferM4AConversion),@"file_formats":[files valueForKey:@"pathExtension"]?:@[],@"file_count":@(files.count),@"error":error?:NSNull.null,@"exporter_wrote_source_cache":@NO,@"native_download_requested":@(self.commandRequested)});
    dispatch_async(dispatch_get_main_queue(),^{if(reply)reply(files,error);});
}
- (void)resolveNext {
    if(self.finished)return;
    while(self.resolved.count<self.tracks.count&&[self.tracks[self.resolved.count][@"audio_files"] count]&&[self.tracks[self.resolved.count][@"metadata_complete"]boolValue]){NSMutableDictionary *track=[self.tracks[self.resolved.count]mutableCopy];track[@"files"]=track[@"audio_files"];[self.resolved addObject:track];}
    if(self.resolved.count==self.tracks.count){[self prepareNextArtwork];return;}
    NSString *uri=self.tracks[self.resolved.count][@"uri"];
    SAPCallReadOnlyService(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *response,NSString *error){
        if(self.finished)return;
        NSDictionary *track=response?trackMetadata(response,uri):nil;if(!track){[self finish:nil error:error?:@"Track metadata is unavailable; nothing was exported."];return;}
        NSMutableDictionary *merged=[self.tracks[self.resolved.count]mutableCopy];
        [track enumerateKeysAndObjectsUsingBlock:^(id key,id value,BOOL *stop){
            BOOL albumIdentity=[self.targetURI hasPrefix:@"spotify:album:"]&&[@[@"album_name",@"album_uri",@"artist_name",@"year"]containsObject:key]&&merged[key]!=nil;
            if(!albumIdentity&&(![value isKindOfClass:NSString.class]||[value length]))merged[key]=value;
        }];
        [self.resolved addObject:merged];[self resolveNext];
    });
}
- (void)status:(NSString *)message {
    if(self.progress && !self.finished){
        NSString *name=self.resolved.firstObject[@"name"];
        if([self.targetURI hasPrefix:@"spotify:album:"])name=self.name;
        self.progress(self.shareOnly&&name.length?[NSString stringWithFormat:@"%@ · %@",name,message]:message);
    }
}
- (void)prepareNextArtwork {
    if(self.finished)return;
    if(!self.artworkCache)self.artworkCache=[NSMutableDictionary dictionary];
    while(self.artworkIndex<self.resolved.count) {
        NSMutableDictionary *track=[self.resolved[self.artworkIndex]mutableCopy];
        NSString *uri=track[@"cover_image_uri"],*album=track[@"album_uri"];
        if(!uri.length && album.length && !self.artworkCache[album]) {
            self.artworkCache[album]=NSNull.null;
            SAPFetchExportAlbumMetadata(album,^(NSDictionary *metadata,NSString *error){
                if(self.finished)return;NSString *cover=metadata[@"cover_image_uri"];
                self.artworkCache[album]=cover.length?cover:(id)NSNull.null;[self prepareNextArtwork];
            });return;
        }
        if(!uri.length && [self.artworkCache[album?:@""]isKindOfClass:NSString.class])uri=self.artworkCache[album];
        id cached=uri.length?self.artworkCache[uri]:NSNull.null;
        if(!cached) {
            [self status:@"Preparing cover artwork…"];
            self.cancelArtwork=SAPLoadExportArtwork(uri,^(NSDictionary *art){
                if(self.finished)return;self.cancelArtwork=nil;self.artworkCache[uri]=art?:(id)NSNull.null;
                SAP_TRACE("export","cover_artwork_resolved",0,@{@"image_uri":uri,@"received":@(art!=nil),@"jpeg_bytes":@([art[@"jpeg"]length])});
                [self prepareNextArtwork];
            });return;
        }
        if([cached isKindOfClass:NSDictionary.class])track[@"export_artwork"]=cached;
        self.resolved[self.artworkIndex++]=track;
    }
    [self reuseExportsOrPrepareDownload];
}
- (void)reuseExportsOrPrepareDownload {
    dispatch_async(exportWorkQueue(),^{@autoreleasepool {
        NSURL *root=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Pixie Exports"] isDirectory:YES];
        NSMutableArray *existing=[NSMutableArray array];
        for(NSDictionary *track in self.resolved) {
            if(atomic_load(&self->ended))return;
            NSURL *file=SAPExportLibraryExisting(root,track,self.format?:@"ogg");if(!file)break;
            if(!SAPExportValidExistingAudio(file,track,self.format?:@"ogg",^BOOL{return atomic_load(&self->ended);}))break;
            SAPAttachExportArtwork(file,SAPExportShareMetadata(track,file));
            [existing addObject:file];
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if(self.finished)return;
            if(existing.count==self.resolved.count){
                SAP_TRACE("export","validated_export_reused",0,@{@"file_count":@(existing.count),@"download_requested":@NO});
                [self finish:existing error:nil];
            }else if(self.shareOnly)[self writeFiles];else [self prepareNativeDownload];
        });
    }});
}
- (void)prepareNativeDownload {
    if(self.finished || self.preparationStarted)return;
    self.preparationStarted=YES;self.downloadStarted=NSDate.timeIntervalSinceReferenceDate;
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    __weak SAPExportJob *weak=self;
    self.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),1800,^{
        [weak finish:nil error:@"Spotify did not finish preparing the audio within 30 minutes. Export monitoring stopped; no files were shared."];
    });
    [self status:@"Checking Spotify downloads before exporting…"];
    [self pollNativeDownload];
}
- (void)schedulePoll {
    if(self.finished)return;
    if(self.poll)dispatch_source_cancel(self.poll);
    __weak SAPExportJob *weak=self;
    self.poll=SAPScheduleDeadline(dispatch_get_main_queue(),1.5,^{[weak pollNativeDownload];});
}
- (void)requestNativeDownload {
    if(self.shareOnly&&!self.temporaryCaptured){
        [self status:@"Checking the original Spotify state before temporary preparation…"];
        SAPCaptureTemporaryOfflineExport(self.targetURI,self.resolved,^(NSDictionary *token,NSString *error){
            if(self.finished)return;if(!token){[self finish:nil error:error?:@"Could not verify the original Spotify state."];return;}
            self.temporaryCaptured=YES;self.temporaryToken=token;[self requestNativeDownload];
        });return;
    }
    __weak SAPExportJob *weak=self;
    [self status:@"Preparing the standard Spotify downloader…"];
    SAPPrepareNativeOffline(^BOOL{
        SAPExportJob *job=weak;return job && !atomic_load(&job->ended);
    },^(BOOL ready,NSString *reason){
        if(self.finished)return;
        if(!ready){[self finish:nil error:reason?:@"Spotify download preparation failed."];return;}
        // The preceding GetItems reply established this exact transport. Mutations
        // use a single endpoint and are never replayed after an ambiguous result.
        self.commandRequested=YES;self.nativeAddInFlight=self.shareOnly;
        if([self.targetURI hasPrefix:@"spotify:album:"]&&![self perTrackDownload]) {
            // Offline.AddDownload's wire message (DownloadRequest: uri +
            // music_video_uris) has no context field — it only actually queues
            // individual items. Sending it an album/context URI is acknowledged
            // (SUCCESS) but the context never leaves state 0: confirmed on-device
            // in the 2026-10-30 export7 log (native_download_context_state stayed
            // context_state=0 for the full 30s after a code:0 reply). Spotify's own
            // playlist/album "Download" row instead calls
            // -[SPTOfflineManagerImplementation makeEntityAvailableOfflineWithURL:trackURLs:]
            // with the context URL and every track URL — call that directly.
            NSMutableArray<NSString *> *trackURIs=[NSMutableArray arrayWithCapacity:self.resolved.count];
            for(NSDictionary *track in self.resolved) if([track[@"uri"] isKindOfClass:NSString.class])[trackURIs addObject:track[@"uri"]];
            SAP_TRACE("export","native_download_requested",0,@{@"uri":self.targetURI,@"automatic_replay":@NO,@"source":@"native_entity_make_available_offline",@"track_count":@(trackURIs.count)});
            SAPMakeEntityAvailableOffline(self.targetURI,trackURIs,^(BOOL attempted,NSString *reason){
                self.nativeAddInFlight=NO;if(attempted)self.temporaryAddAccepted=YES;
                if(self.finished){[self completeTemporaryFinish];return;}
                SAP_TRACE("export","native_download_reply",0,@{@"uri":self.targetURI,@"code":@(attempted?0:1),@"download_completion_verified":@NO,@"method":@"makeEntityAvailableOfflineWithURL:trackURLs:"});
                if(!attempted){[self finish:nil error:reason?:@"Spotify did not accept the album download request."];return;}
                [self status:@"Spotify is downloading the audio for export…"];
                [self schedulePoll];
            });
            return;
        }
        // Tracks Spotify already has (or is already fetching) are left alone; an album
        // share asks for each missing track exactly like a single-track share does.
        NSMutableArray<NSString *> *pending=[NSMutableArray array];
        if([self perTrackDownload]) {
            NSDictionary *states=self.temporaryToken[@"initial_download_states"];
            for(NSDictionary *track in self.resolved){NSString *uri=track[@"uri"];if([uri isKindOfClass:NSString.class]&&states[uri]&&[states[uri]unsignedIntegerValue]<=1&&![pending containsObject:uri])[pending addObject:uri];}
            if(!pending.count){self.nativeAddInFlight=NO;self.observingExisting=YES;[self schedulePoll];return;}
        }else [pending addObject:self.targetURI];
        SAP_TRACE("export","native_download_requested",0,@{@"uri":self.targetURI,@"automatic_replay":@NO,@"source":@"ordinary_spotify_offline_AddDownload",@"track_count":@(pending.count)});
        [self addDownloads:pending index:0];
    });
}
- (BOOL)perTrackDownload {return self.shareOnly&&[self.targetURI hasPrefix:@"spotify:album:"];}
- (void)addDownloads:(NSArray<NSString *> *)uris index:(NSUInteger)index {
    if(self.finished){self.nativeAddInFlight=NO;[self completeTemporaryFinish];return;}
    if(index>=uris.count){self.nativeAddInFlight=NO;[self status:@"Spotify is downloading the audio for export…"];[self schedulePoll];return;}
    NSString *uri=uris[index];
    SAPCallOfflineCommandOnce(@"AddDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        NSArray *fields=data?SAPProtoFields(data):nil;
        if(!fields)self.temporaryOutcomeUnknown=YES;
        if(fields&&SAPProtoNumber(fields,1,0)==0)self.temporaryAddAccepted=YES;
        if(self.finished){self.nativeAddInFlight=NO;[self completeTemporaryFinish];return;}
        if(!fields){self.nativeAddInFlight=NO;[self finish:nil error:error?:@"Spotify did not confirm the download request. It was not sent again."];return;}
        uint64_t code=SAPProtoNumber(fields,1,0);
        SAP_TRACE("export","native_download_reply",0,@{@"uri":uri,@"code":@(code),@"download_completion_verified":@NO});
        if(code){self.nativeAddInFlight=NO;[self finish:nil error:[NSString stringWithFormat:@"Spotify rejected the download request (code %llu). No audio was exported.",code]];return;}
        [self addDownloads:uris index:index+1];
    });
}
- (void)pollNativeDownload {
    if(self.finished)return;
    if(self.poll){dispatch_source_cancel(self.poll);self.poll=nil;}
    if([self.targetURI hasPrefix:@"spotify:album:"]&&![self perTrackDownload]){[self pollNativeAlbumContext];return;}
    NSMutableData *request=[NSMutableData data];NSMutableDictionary *wanted=[NSMutableDictionary dictionary];
    for(NSDictionary *track in self.resolved) {
        NSString *uri=track[@"uri"];if(![uri isKindOfClass:NSString.class])continue;
        if(!wanted[uri]){wanted[uri]=track;[request appendData:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])];}
    }
    if(!wanted.count){[self finish:nil error:@"No valid tracks were resolved for export."];return;}
    SAPCallReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"GetItems",request,^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;
        if(!fields){[self finish:nil error:error?:@"Spotify did not return the download state."];return;}
        NSMutableSet *seen=[NSMutableSet set],*completed=[NSMutableSet set];NSUInteger complete=0,active=0;
        NSString *failure=nil;
        for(NSDictionary *field in fields) {
            if([field[@"number"]unsignedIntValue]!=1 || [field[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *item=SAPProtoFields(field[@"value"]);NSString *uri=SAPProtoString(item,1);
            if(!wanted[uri] || [seen containsObject:uri])continue;
            [seen addObject:uri];uint64_t state=SAPProtoNumber(item,2,0);
            if(state==3){complete++;[completed addObject:uri];self.startObserved=YES;}
            if(state==4 || state==5 || state==6){active++;self.startObserved=YES;}
            if(state==7 || (![self perTrackDownload] && state==1 && (self.commandRequested || self.observingExisting) && NSDate.timeIntervalSinceReferenceDate-self.downloadStarted>30))
                failure=[NSString stringWithFormat:@"Spotify reported download state %llu for %@. No audio was exported.",state,wanted[uri][@"name"]?:uri];
        }
        SAP_TRACE("export","native_download_state",0,@{@"uri":self.targetURI,@"complete_tracks":@(complete),@"total_tracks":@(wanted.count),@"in_progress_tracks":@(active),@"observed_tracks":@(seen.count),@"download_command_requested":@(self.commandRequested)});
        if([self perTrackDownload]&&(self.commandRequested||self.observingExisting)) {
            // Spotify fetches the tracks one after another, so a queued track may wait. Only
            // a download that has shown no progress at all for a long time is a failure.
            NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
            if(active||complete>self.progressMark||!self.lastProgress){self.lastProgress=now;self.progressMark=MAX(self.progressMark,complete);}
            if(!failure&&complete<wanted.count) {
                // Spotify takes some tracks but never queues them (not available to this account).
                // Once everything else is finished, export what is there and name what is missing.
                if(complete>0&&!active&&now-self.lastProgress>60) {
                    NSMutableArray *kept=[NSMutableArray array],*skipped=[NSMutableArray array];
                    for(NSDictionary *track in self.resolved)if([completed containsObject:track[@"uri"]])[kept addObject:track];else [skipped addObject:track[@"name"]?:track[@"uri"]];
                    for(NSUInteger i=0;i<kept.count;i++){NSMutableDictionary *track=[kept[i]mutableCopy];track[@"album_skipped"]=skipped;kept[i]=track;}
                    SAP_TRACE("export","album_tracks_skipped",0,@{@"skipped":@(skipped.count),@"exported":@(kept.count)});
                    self.resolved=kept;self.completeSamples=0;
                    [self status:[NSString stringWithFormat:@"Spotify cannot download %lu track(s); exporting the rest…",(unsigned long)skipped.count]];
                    [self schedulePoll];return;
                }
                if(now-self.lastProgress>60)failure=[NSString stringWithFormat:@"Spotify stopped downloading the album tracks (%lu of %lu ready). No audio was exported.",(unsigned long)complete,(unsigned long)wanted.count];
            }
        }
        if(failure){[self finish:nil error:failure];return;}
        if(complete==wanted.count) {
            if(++self.completeSamples>=2){self.confirmedDownloadedURIs=[NSSet setWithArray:wanted.allKeys];[self status:@"Spotify reports all tracks downloaded. Exporting audio…"];[self beginWrite];return;}
            [self schedulePoll];return;
        }
        self.completeSamples=0;
        if(self.commandRequested && !self.startObserved && NSDate.timeIntervalSinceReferenceDate-self.downloadStarted>30) {
            [self finish:nil error:@"Spotify accepted the download command, but the track did not enter its download queue within 30 seconds. Export monitoring stopped; try the normal Spotify download button first."];
            return;
        }
        if(!self.commandRequested && !self.observingExisting) {
            // Respect a download already started by Spotify or another Pixie action.
            if(active && active+complete==wanted.count){self.observingExisting=YES;[self status:@"Waiting for the existing Spotify download…"];[self schedulePoll];}
            else [self requestNativeDownload];
            return;
        }
        [self status:[NSString stringWithFormat:@"Spotify downloads: %lu / %lu tracks ready for export",(unsigned long)complete,(unsigned long)wanted.count]];
        [self schedulePoll];
    });
}
- (void)pollNativeAlbumContext {
    NSMutableData *request=[SAPProtoBytes(1,SAPProtoInteger(1,1))mutableCopy];
    [request appendData:SAPProtoBytes(3,[self.targetURI dataUsingEncoding:NSUTF8StringEncoding])];
    SAPCallReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"GetContexts",request,^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;
        if(!fields){[self finish:nil error:error?:@"Spotify did not return the album download state."];return;}
        BOOL found=NO;uint64_t state=0;
        for(NSDictionary *field in fields) {
            if([field[@"number"]unsignedIntValue]!=1 || [field[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *info=SAPProtoFields(field[@"value"]),*context=SAPProtoFields(SAPProtoData(info,1));
            if(![SAPProtoString(context,1)isEqualToString:self.targetURI])continue;
            found=YES;state=SAPProtoNumber(context,2,0);break;
        }
        BOOL complete=found&&state==3,active=found&&(state==2||state==4||state==5);
        if(complete||active)self.startObserved=YES;
        SAP_TRACE("export","native_download_context_state",0,@{@"uri":self.targetURI,@"context_found":@(found),@"context_state":@(state),@"complete":@(complete),@"in_progress":@(active),@"download_command_requested":@(self.commandRequested)});
        if(found&&(state==1||state==7)) {
            [self finish:nil error:[NSString stringWithFormat:@"Spotify reported album download state %llu. No audio was exported.",state]];return;
        }
        if(complete) {
            if(++self.completeSamples>=2){[self status:@"Spotify reports the album downloaded. Exporting audio…"];[self beginWrite];return;}
            [self schedulePoll];return;
        }
        self.completeSamples=0;
        if(!self.commandRequested&&!self.observingExisting) {
            if(active){self.observingExisting=YES;[self status:@"Waiting for the existing Spotify album download…"];[self schedulePoll];}
            else [self requestNativeDownload];
            return;
        }
        if(self.commandRequested&&!self.startObserved&&NSDate.timeIntervalSinceReferenceDate-self.downloadStarted>30) {
            [self finish:nil error:@"Spotify accepted the album download command, but the album did not enter its download queue within 30 seconds. Export monitoring stopped; try the normal Spotify album download button first."];
            return;
        }
        [self status:active?@"Spotify is downloading the album for export…":@"Waiting for Spotify to start the album download…"];
        [self schedulePoll];
    });
}
- (NSArray<NSDictionary *> *)tracksMissingKeys {
    NSMutableArray *missing=[NSMutableArray array];
    for(NSDictionary *track in self.resolved) {
        BOOL have=NO;uint8_t key[16];
        for(NSData *identifier in track[@"files"])if(SAPExportKeyStoreCopyKey(identifier,key)){have=YES;break;}
        memset_s(key,sizeof(key),0,sizeof(key));
        if(!have)[missing addObject:track];
    }
    return missing;
}
// A validated plain payload needs no observed media key. Try the actual cache
// first; offer a one-shot native refresh only after that attempt fails.
- (void)beginWrite {
    if(self.finished)return;
    if(self.poll){dispatch_source_cancel(self.poll);self.poll=nil;}
    [self refreshMissingFilesThen:^{[self writeFiles];}];
}
// A track resolved before its download has no audio file ids. Once Spotify has
// downloaded it, ask for its metadata again and fill the ids in.
- (void)refreshMissingFilesThen:(dispatch_block_t)next {
    NSUInteger index=NSNotFound;
    for(NSUInteger i=0;i<self.resolved.count;i++)if(![self.resolved[i][@"files"]count]){index=i;break;}
    if(index==NSNotFound){next();return;}
    NSString *uri=self.resolved[index][@"uri"];
    SAPCallReadOnlyService(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *response,NSString *error){
        if(self.finished)return;
        NSDictionary *track=response?trackMetadata(response,uri):nil;
        if(![track[@"files"]count]){[self finish:nil error:error?:[NSString stringWithFormat:@"Spotify has no audio files for %@ even after the download.",self.resolved[index][@"name"]?:uri]];return;}
        NSMutableDictionary *merged=[self.resolved[index]mutableCopy];merged[@"files"]=track[@"files"];
        self.resolved[index]=merged;[self refreshMissingFilesThen:next];
    });
}
- (void)requestKeyRefresh {
    if(self.finished)return;
    NSArray<NSDictionary *> *missing=self.refreshAttempted?@[]:[self tracksMissingKeys];
    if(!self.confirmRefresh||self.refreshAttempted){[self finish:nil error:@"The cached audio could not be validated. No files were shared."];return;}
    // A present but wrong/media-mismatched key is indistinguishable from a
    // missing one at the UI level. Offer the one-shot refresh in both cases;
    // the user still has to approve the removal.
    NSArray<NSDictionary *> *targets=missing.count?missing:self.resolved;
    self.refreshAttempted=YES;
    if(self.poll){dispatch_source_cancel(self.poll);self.poll=nil;}
    SAP_TRACE("export","key_refresh_needed",0,@{@"tracks_without_key":@(missing.count),@"total_tracks":@(self.resolved.count),@"refresh_targets":@(targets.count)});
    __weak SAPExportJob *weak=self;
    self.confirmRefresh(targets.count,^(BOOL approved){
        dispatch_async(dispatch_get_main_queue(),^{
            SAPExportJob *job=weak;if(!job||job.finished)return;
            SAP_TRACE("export","key_refresh_decision",0,@{@"approved":@(approved)});
            if(!approved){[job finish:nil error:@"Export stopped. Cache refresh was declined; no files were shared."];return;}
            [job refreshKeysForTracks:targets];
        });
    });
}
- (void)refreshKeysForTracks:(NSArray<NSDictionary *> *)tracks {
    NSMutableArray<NSString *> *uris=[NSMutableArray array];
    for(NSDictionary *track in tracks)if([track[@"uri"] isKindOfClass:NSString.class])[uris addObject:track[@"uri"]];
    self.refreshURIs=uris;self.refreshStarted=NSDate.timeIntervalSinceReferenceDate;
    [self status:@"Requesting removal of the old offline copies…"];
    __weak SAPExportJob *weak=self;
    SAPPrepareNativeOffline(^BOOL{SAPExportJob *job=weak;return job&&!atomic_load(&job->ended);},^(BOOL ready,NSString *reason){
        if(self.finished)return;
        if(!ready){[self finish:nil error:reason?:@"Spotify download preparation failed."];return;}
        if(!self.automaticKeyRefresh)for(NSString *uri in uris)SAPResetEntityOffline(uri,^(BOOL attempted,NSString *why){
            SAP_TRACE("export","key_refresh_native_remove",0,@{@"uri":uri,@"attempted":@(attempted),@"reason":why?:NSNull.null});
        });
        [self removeNext:0];
    });
}
- (void)removeNext:(NSUInteger)index {
    if(self.finished)return;
    if(index>=self.refreshURIs.count){[self waitRemoved];return;}
    NSString *uri=self.refreshURIs[index];
    SAPCallOfflineCommandOnce(@"RemoveDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;
        SAP_TRACE("export","key_refresh_rpc_remove",0,@{@"uri":uri,@"reply_received":@(fields!=nil),@"code":fields?@(SAPProtoNumber(fields,1,0)):NSNull.null,@"error":error?:NSNull.null});
        if(!fields || SAPProtoNumber(fields,1,0)!=0){[self finish:nil error:error?:@"Spotify did not confirm removal of the offline copy. Nothing was downloaded again."];return;}
        [self removeNext:index+1];
    });
}
- (void)scheduleRefreshStep:(NSTimeInterval)delay block:(void (^)(void))block {
    if(self.finished)return;
    if(self.refreshTimer)dispatch_source_cancel(self.refreshTimer);
    self.refreshTimer=SAPScheduleDeadline(dispatch_get_main_queue(),delay,block);
}
- (void)waitRemoved {
    if(self.finished)return;
    NSMutableData *request=[NSMutableData data];
    for(NSString *uri in self.refreshURIs)[request appendData:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])];
    __weak SAPExportJob *weak=self;
    SAPCallReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"GetItems",request,^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;NSUInteger stillComplete=0;NSMutableSet *seen=[NSMutableSet set];
        if(!fields){[self finish:nil error:error?:@"Spotify did not return the removal state. Nothing was downloaded again."];return;}
        for(NSDictionary *field in fields) {
            if([field[@"number"]unsignedIntValue]!=1||[field[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *item=SAPProtoFields(field[@"value"]);
            NSString *uri=SAPProtoString(item,1);
            if(![self.refreshURIs containsObject:uri]||[seen containsObject:uri])continue;
            [seen addObject:uri];
            uint64_t state=SAPProtoNumber(item,2,0);
            if(state==3||state==4||state==5||state==6)stillComplete++;
        }
        BOOL timedOut=NSDate.timeIntervalSinceReferenceDate-self.refreshStarted>25;
        SAP_TRACE("export","key_refresh_removal_state",0,@{@"still_complete":@(stillComplete),@"requested":@(self.refreshURIs.count),@"timed_out":@(timedOut)});
        if(seen.count!=self.refreshURIs.count){
            if(timedOut){[self finish:nil error:@"Spotify did not report every requested removal. Nothing was downloaded again."];return;}
            [self scheduleRefreshStep:1.5 block:^{[weak waitRemoved];}];return;
        }
        if(stillComplete&&timedOut){[self finish:nil error:@"Spotify kept the downloaded copies (another downloaded playlist or album may still hold them), so no new key could be issued. No files were shared."];return;}
        if(stillComplete){[self scheduleRefreshStep:1.5 block:^{[weak waitRemoved];}];return;}
        [self addNext:0];
    });
}
- (void)addNext:(NSUInteger)index {
    if(self.finished)return;
    if(index>=self.refreshURIs.count){self.commandRequested=YES;self.refreshStarted=NSDate.timeIntervalSinceReferenceDate;self.completeSamples=0;[self status:@"Waiting for Spotify to finish the requested downloads…"];[self waitKeys];return;}
    NSString *uri=self.refreshURIs[index];
    SAPCallOfflineCommandOnce(@"AddDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;uint64_t code=fields?SAPProtoNumber(fields,1,0):1000;
        SAP_TRACE("export","key_refresh_rpc_add",0,@{@"uri":uri,@"reply_received":@(fields!=nil),@"code":@(code),@"error":error?:NSNull.null});
        if(code){[self finish:nil error:[NSString stringWithFormat:@"Spotify did not accept the repeated download of a track (code %llu). No files were shared.",code]];return;}
        [self addNext:index+1];
    });
}
- (void)waitKeys {
    if(self.finished)return;
    NSUInteger remaining=[self tracksMissingKeys].count;
    NSTimeInterval elapsed=NSDate.timeIntervalSinceReferenceDate-self.refreshStarted;
    SAP_TRACE("export","key_refresh_wait",0,@{@"tracks_without_key":@(remaining),@"elapsed_seconds":@(elapsed)});
    __weak SAPExportJob *weak=self;
    if(elapsed>240){[self finish:nil error:@"Spotify did not provide complete readable audio within 4 minutes. Export stopped; no files were shared."];return;}
    NSMutableData *request=[NSMutableData data];
    for(NSString *uri in self.refreshURIs)[request appendData:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])];
    SAPCallReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"GetItems",request,^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;
        if(!fields){[self finish:nil error:error?:@"Spotify did not return the refreshed download state."];return;}
        NSMutableSet *complete=[NSMutableSet set];
        for(NSDictionary *field in fields){
            if([field[@"number"]unsignedIntValue]!=1||[field[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *item=SAPProtoFields(field[@"value"]);NSString *uri=SAPProtoString(item,1);
            if(![self.refreshURIs containsObject:uri])continue;
            uint64_t state=SAPProtoNumber(item,2,0);
            if(state==7){[self finish:nil error:@"Spotify reported an error downloading the refreshed track. No files were shared."];return;}
            if(state==3)[complete addObject:uri];
        }
        // A callback or a fixed delay is not proof that the cache file is complete.
        if(complete.count==self.refreshURIs.count){
            if(++self.completeSamples>=2){[self status:@"Checking the downloaded audio…"];[self writeFiles];return;}
        }else self.completeSamples=0;
        SAP_TRACE("export","key_refresh_download_state",0,@{@"complete_tracks":@(complete.count),@"requested_tracks":@(self.refreshURIs.count),@"tracks_without_observed_key":@(remaining),@"elapsed_seconds":@(elapsed)});
        [self status:[NSString stringWithFormat:@"Spotify downloads: %lu / %lu complete",(unsigned long)complete.count,(unsigned long)self.refreshURIs.count]];
        [self scheduleRefreshStep:1.5 block:^{[weak waitKeys];}];
    });
}
- (BOOL)recoverMissingCachedKey:(NSDictionary *)track evidence:(NSDictionary *)evidence {
    if(self.finished||self.commandRequested||self.observingExisting||!SAPShouldRefreshCachedTrack(self.shareOnly,self.refreshAttempted,[self.confirmedDownloadedURIs containsObject:track[@"uri"]],evidence))return NO;
    self.refreshAttempted=YES;self.automaticKeyRefresh=YES;
    SAP_TRACE("export","confirmed_missing_key_refresh",0,@{@"uri":track[@"uri"],@"reason":evidence,@"downloaded_confirmed_twice":@YES,@"maximum_attempts":@1,@"source":@"user-authorized recovery for unreadable previously downloaded audio"});
    [self status:@"The downloaded track has no usable export key. Downloading this track again…"];
    [self refreshKeysForTracks:@[track]];return YES;
}
- (void)writeFiles {
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    dispatch_async(exportWorkQueue(),^{@autoreleasepool {
        NSFileManager *fm=NSFileManager.defaultManager;NSURL *root=[[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] isDirectory:YES] URLByAppendingPathComponent:@"Pixie Exports" isDirectory:YES];
        NSURL *folder=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"PixieExport-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];NSError *error=nil;
        if(![fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]){[self finish:nil error:error.localizedDescription];return;}
        NSMutableArray *files=[NSMutableArray array];NSMutableIndexSet *reused=[NSMutableIndexSet indexSet];NSString *failure=nil;NSUInteger number=0;BOOL cacheFailed=NO;NSDictionary *cacheEvidence=nil,*failedTrack=nil;
        dispatch_group_t conversions=dispatch_group_create();dispatch_semaphore_t window=dispatch_semaphore_create(SAPM4AConversionParallelLimit);
        NSProgress *conversionCancel=[NSProgress progressWithTotalUnitCount:1];__block NSString *conversionError=nil;
        for(NSDictionary *track in self.resolved){if(atomic_load(&self->ended)){failure=@"Audio export cancelled.";break;}++number;
            NSURL *existing=SAPExportLibraryExisting(root,track,self.format?:@"ogg");
            if(existing&&SAPExportValidExistingAudio(existing,track,self.format?:@"ogg",^BOOL{return atomic_load(&self->ended);})) {
                SAPAttachExportArtwork(existing,SAPExportShareMetadata(track,existing));
                [reused addIndex:files.count];[files addObject:existing];continue;
            }
            NSURL *trackFolder=[folder URLByAppendingPathComponent:[NSString stringWithFormat:@".track-%lu",(unsigned long)number] isDirectory:YES];
            if(![fm createDirectoryAtURL:trackFolder withIntermediateDirectories:YES attributes:nil error:nil]){failure=@"Could not create temporary audio storage.";break;}
            NSURL *url=nil;if(!SAPExportTrackFromCache(track,trackFolder,number,&url,&failure,&cacheEvidence,^BOOL{return atomic_load(&self->ended);})){cacheFailed=!atomic_load(&self->ended);failedTrack=track;failure=[NSString stringWithFormat:@"%@\n%@\nExport stopped; no files will be shared.",track[@"name"],failure];break;}BOOL m4a=[self.format isEqual:@"m4a"]&&!self.deferM4AConversion;BOOL embedded=!m4a&&SAPExportEmbedArtwork(url,track,self.format,self.deferM4AConversion,^BOOL{return atomic_load(&self->ended);});
            if(embedded)SAPAttachExportArtwork(url,track[@"export_artwork"]);
            if(!m4a)SAP_TRACE("export","file_artwork_written",0,@{@"track_uri":track[@"uri"]?:@"",@"embedded":@(embedded),@"audio_reencoded":@NO});
            if(m4a) {
                NSURL *output=[[url URLByDeletingPathExtension]URLByAppendingPathExtension:@"m4a"];
                // Producer continues reading the next Ogg while this file encodes.
                // Bound queued/running conversions and temporary inputs as well.
                dispatch_semaphore_wait(window,DISPATCH_TIME_FOREVER);
                if(atomic_load(&self->ended)||conversionCancel.cancelled){dispatch_semaphore_signal(window);failure=@"Audio conversion cancelled.";break;}
                dispatch_group_enter(conversions);
                NSUInteger itemNumber=number;
                dispatch_async(dispatch_get_main_queue(),^{[self status:[NSString stringWithFormat:@"Converting to M4A: %lu / %lu",(unsigned long)itemNumber,(unsigned long)self.resolved.count]];});
                SAPQueueM4AConversion(url,output,track,track[@"export_artwork"],^BOOL{return atomic_load(&self->ended)||conversionCancel.cancelled;},^(SAPM4AExportStatus code){
                    SAP_TRACE("export","m4a_conversion_finished",0,(@{@"track_uri":track[@"uri"]?:@"",@"status":@(code),@"target_bitrate_kbps":@320,@"encoder_limits_respected":@YES,@"audio_reencoded":@YES,@"parallel_limit":@(SAPM4AConversionParallelLimit)}));
                    if(code!=SAPM4AExportOK){@synchronized(conversionCancel){if(!conversionError)conversionError=code==SAPM4AExportCancelled?@"Audio export cancelled.":[NSString stringWithFormat:@"M4A conversion failed (code %u). No files were shared.",(unsigned)code];}[conversionCancel cancel];}
                    dispatch_semaphore_signal(window);dispatch_group_leave(conversions);
                });
                url=output;
            }
            [files addObject:url];}
        if(failure)[conversionCancel cancel];
        dispatch_group_wait(conversions,DISPATCH_TIME_FOREVER);
        if(!failure)failure=conversionError;
        if(atomic_load(&self->ended))failure=@"Audio export cancelled.";
        BOOL audioFailed=cacheFailed;
        if(!failure&&!self.shareOnly) {
            NSMutableArray *published=[NSMutableArray array];
            for(NSUInteger i=0;i<files.count;i++) {
                if(atomic_load(&self->ended)){failure=@"Audio export cancelled.";break;}
                NSURL *file=[reused containsIndex:i]?files[i]:SAPExportLibraryPublish(files[i],root,self.resolved[i],&failure);
                if(!file)break;
                SAPAttachExportArtwork(file,SAPExportShareMetadata(self.resolved[i],file));
                [published addObject:file];
            }
            if(!failure)files=published;
        }
        if(failure){NSError *cleanup=nil;if(![fm removeItemAtURL:folder error:&cleanup])failure=[failure stringByAppendingFormat:@"\nCleanup failed: %@",cleanup.localizedDescription];dispatch_async(dispatch_get_main_queue(),^{
            if(self.finished)return;
            if(self.shareOnly&&audioFailed&&!self.preparationStarted){
                [self prepareNativeDownload];
            }else if(audioFailed&&[self recoverMissingCachedKey:failedTrack evidence:cacheEvidence]){
                // The recovery callback owns the remaining export workflow.
            }else if(audioFailed && !self.refreshAttempted && self.confirmRefresh){
                SAP_TRACE("export","cache_attempt_before_refresh",0,@{@"validated":@NO,@"error":failure?:NSNull.null});
                [self requestKeyRefresh];
            }else [self finish:nil error:failure];
        });}else {
            if(self.shareOnly){for(NSUInteger i=0;i<files.count;i++)SAPAttachExportArtwork(files[i],SAPExportShareMetadata(self.resolved[i],files[i]));SAPRetainTemporaryAudioFiles(files,folder);}
            else [fm removeItemAtURL:folder error:nil];
            [self finish:files error:nil];
        }
    }});
}
@end
void SAPExportCurrentAudio(BOOL album,void (^completion)(NSArray<NSURL *> *,NSString *)) {
    SAPExportCurrentAudioWithProgress(album,nil,completion);
}
void SAPExportCurrentAudioWithProgress(BOOL album,void (^progress)(NSString *),void (^completion)(NSArray<NSURL *> *,NSString *)) {
    SAPExportCurrentAudioWithKeyRefresh(album,progress,nil,completion);
}
void SAPExportCurrentAudioWithKeyRefresh(BOOL album,void (^progress)(NSString *),void (^confirmRefresh)(NSUInteger,void (^)(BOOL)),void (^completion)(NSArray<NSURL *> *,NSString *)) {
    NSDictionary *current=SAPCurrentExportTrack();NSString *uri=current[album?@"album_uri":@"uri"];
    SAPStartAudioExportURI(uri,current[@"name"],NO,progress,confirmRefresh,completion);
}
static void SAPStartAudioExportWithOptions(NSString *uri,NSString *name,BOOL shareOnly,NSString *format,BOOL deferConversion,void (^progress)(NSString *),void (^confirmRefresh)(NSUInteger,void (^)(BOOL)),void (^completion)(NSArray<NSURL *> *,NSString *)) {
    NSCAssert(NSThread.isMainThread,@"Export must be requested from the main thread");
    BOOL album=[uri hasPrefix:@"spotify:album:"];
    static NSUInteger cleanupWaits;
    if(atomic_load(&exporting)&&activeJob.finished&&cleanupWaits<100) {
        // A cancelled job gives Spotify's downloads back before it releases the exporter; wait for that.
        cleanupWaits++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{SAPStartAudioExportWithOptions(uri,name,shareOnly,format,deferConversion,progress,confirmRefresh,completion);});
        return;
    }
    cleanupWaits=0;
    if(atomic_exchange(&exporting,true)){if(completion)completion(nil,@"Another export is already running.");return;}
    SAP_TRACE("export","audio_export_requested",0,@{@"album":@(album),@"native_download_preparation":@YES,@"direct_cache_write_requested":@NO});
    SAPExportJob *job=[SAPExportJob new];activeJob=job;job.completion=completion;job.progress=progress;job.confirmRefresh=confirmRefresh;job.targetURI=uri;job.resolved=[NSMutableArray array];job.name=name?:@"Track";job.format=format?:SAPAudioExportFormat();job.deferM4AConversion=deferConversion;job.shareOnly=shareOnly;
    if(!uri){[job finish:nil error:@"Start a music track on this iPhone first."];return;}
    __weak SAPExportJob *weak=job;job.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),120,^{[weak finish:nil error:@"Metadata timed out. Nothing was exported; you can retry."];});
    if(album)SAPFetchExportAlbumMetadata(uri,^(NSDictionary *metadata,NSString *error){if(job.finished)return;if(!metadata){[job finish:nil error:error];return;}job.tracks=metadata[@"tracks"];job.name=metadata[@"name"];[job resolveNext];});
    else {job.tracks=@[@{@"uri":uri}];[job resolveNext];}
}
static void SAPStartAudioExportURI(NSString *uri,NSString *name,BOOL shareOnly,void (^progress)(NSString *),void (^confirmRefresh)(NSUInteger,void (^)(BOOL)),void (^completion)(NSArray<NSURL *> *,NSString *)) {
    SAPStartAudioExportWithOptions(uri,name,shareOnly,nil,NO,progress,confirmRefresh,completion);
}
void SAPExportAudioURIForBatch(NSString *uri,NSString *format,void (^progress)(NSString *),void (^completion)(NSArray<NSURL *> *,NSString *)) {
    BOOL valid=[uri isKindOfClass:NSString.class]&&[uri hasPrefix:@"spotify:track:"]&&uri.length==36&&[@[@"m4a",@"ogg"]containsObject:format];
    if(!valid){if(completion)completion(nil,@"Invalid track or export format.");return;}
    SAPStartAudioExportWithOptions(uri,nil,YES,format,YES,progress,nil,completion);
}
void SAPExportAudioURI(NSString *uri,void (^progress)(NSString *),void (^completion)(NSArray<NSURL *> *,NSString *)) {
    BOOL valid=[uri isKindOfClass:NSString.class]&&([uri hasPrefix:@"spotify:track:"]||[uri hasPrefix:@"spotify:album:"])&&uri.length==36;
    if(!valid){if(completion)completion(nil,@"Only Spotify tracks and albums can be exported as files.");return;}
    SAPStartAudioExportURI(uri,nil,YES,progress,nil,completion);
}
void SAPClearAudioExports(void (^completion)(BOOL,NSString *)) {
    SAPCancelAudioExport();
    dispatch_async(exportWorkQueue(),^{@autoreleasepool{NSString *error=nil;BOOL ok=SAPExportLibraryClear(exportLibraryRoot(),&error);dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(ok,error);});}});
}
void SAPCancelAudioExport(void) {
    void (^cancel)(void)=^{SAPExportJob *job=activeJob;if(job&&!job.finished)[job finish:nil error:@"Audio export cancelled."];};
    if(NSThread.isMainThread)cancel();else dispatch_async(dispatch_get_main_queue(),cancel);
}
NSDictionary *SAPTrackExportReport(void){NSMutableDictionary *report=[SAPExportKeyStoreReport() mutableCopy];[report addEntriesFromDictionary:@{@"native_cache_mapping":SAPNativeCacheMapReport(),@"cache_storage_contexts":SAPCacheStorageKeyReport(),@"cache_container_reader":@"validated native header and complete block table before audio validation",@"native_boundaries":SAPExportObservationReport(),@"active":@(atomic_load(&exporting)),@"download_monitor":@"album contexts or individual track items; two complete samples required",@"no_start_timeout_seconds":@30,@"artwork":@"embedded JPEG front cover: M4A iTunes metadata or Ogg METADATA_BLOCK_PICTURE; up to 640 pixels",@"supported_audio":@"complete Ogg Vorbis; optional M4A conversion",@"export_format":SAPAudioExportFormat(),@"cache_index":SAPExportCacheIndexReport(),@"key_vault":SAPExportKeyVaultReport(),@"key_storage":@"bounded process cache and device-only Keychain, scoped to installation and native storage namespace; never logged or shared",@"media_decode":@"bounded candidate list (key/IV/counter/skip); full Ogg validation decides",@"export_directory":@"Documents/Pixie Exports",@"process_id":@(NSProcessInfo.processInfo.processIdentifier),@"cipher_caller_diagnostics":@"bounded scalar caller/length observations while Diagnostics is enabled; no media key is read by this diagnostic",@"runtime_verified":@NO}];return report;}
