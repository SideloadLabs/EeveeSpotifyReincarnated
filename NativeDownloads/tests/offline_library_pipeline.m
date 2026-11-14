#import "OfflineLibraryExport.h"
#import "OfflineLibraryPackage.h"
#import "M4AConversionQueue.h"
#include <assert.h>
static NSMutableArray *calls,*workers,*roots;
static NSUInteger running,maximum;static BOOL nativeBusy,overlap;
static NSProgress *job;
NSString *SAPAudioExportFormat(void){return @"m4a";}
void SAPCancelAudioExport(void){nativeBusy=NO;}
void SAPExportAudioURIForBatch(NSString *uri,NSString *format,void (^progress)(NSString *),void (^completion)(NSArray *,NSString *)) {
 assert(!nativeBusy && [format isEqual:@"m4a"]);nativeBusy=YES;[calls addObject:uri];if(running)overlap=YES;
 dispatch_async(dispatch_get_main_queue(),^{nativeBusy=NO;completion(@[[NSURL fileURLWithPath:[@"/tmp/"stringByAppendingString:[[uri substringFromIndex:14]stringByAppendingPathExtension:@"ogg"]]]],nil);});
}
void SAPExportAudioURI(NSString *uri,void (^progress)(NSString *),void (^completion)(NSArray *,NSString *)){SAPExportAudioURIForBatch(uri,@"m4a",progress,completion);}
NSDictionary *SAPAttachedExportArtwork(NSURL *file){return @{@"share_filename":@"Title.ogg",@"encoding_metadata":@{@"uri":[@"spotify:track:"stringByAppendingString:file.lastPathComponent.stringByDeletingPathExtension],@"name":@"Resolved title",@"artist_name":@"Resolved artist"}};}
void SAPAttachExportArtwork(NSURL *file,NSDictionary *art){assert([art[@"share_filename"]isEqual:@"Title.m4a"]);}
void SAPRetainTemporaryAudioFiles(NSArray *files,NSURL *root){[roots addObject:root];}
static void finish(NSUInteger index){NSDictionary *worker=workers[index];if([worker[@"done"]boolValue])return;running--;((NSMutableDictionary *)worker)[@"done"]=@YES;void (^completion)(SAPM4AExportStatus)=worker[@"completion"];completion(SAPM4AExportOK);}
NSProgress *SAPQueueM4AConversion(NSURL *input,NSURL *output,NSDictionary *track,NSDictionary *art,BOOL (^cancelled)(void),void (^completion)(SAPM4AExportStatus)) {
 assert([track[@"name"]isEqual:@"Resolved title"] && [track[@"artist_name"]isEqual:@"Resolved artist"]);
 NSProgress *p=[NSProgress progressWithTotalUnitCount:1];running++;maximum=MAX(maximum,running);
 [workers addObject:[@{@"completion":[completion copy],@"progress":p,@"done":@NO}mutableCopy]];
 if(workers.count==20)dispatch_async(dispatch_get_main_queue(),^{assert(calls.count==20);assert(running==20);assert(SAPAppendOfflineLibrarySelection(job,@[@{@"uri":@"spotify:track:00",@"name":@"duplicate"},@{@"uri":@"spotify:track:20",@"name":@"new single"}])==1);finish(19);});
 if(workers.count==21)dispatch_async(dispatch_get_main_queue(),^{assert(calls.count==21 && overlap);for(NSInteger i=(NSInteger)workers.count-1;i>=0;i--)finish((NSUInteger)i);});
 return p;
}
NSProgress *SAPPrepareOfflineLibraryPackage(NSArray *tracks,BOOL zip,void (^progress)(double),void (^completion)(NSURL *,NSError *)) {
 assert(tracks.count==21 && maximum==20 && !nativeBusy);
 for(NSUInteger i=0;i<tracks.count;i++){assert(([tracks[i][@"uri"]isEqual:[NSString stringWithFormat:@"spotify:track:%02lu",(unsigned long)i]]));assert([tracks[i][@"file"]pathExtension]&&[[tracks[i][@"file"]pathExtension]isEqual:@"m4a"]);}
 NSProgress *p=[NSProgress progressWithTotalUnitCount:1];dispatch_async(dispatch_get_main_queue(),^{completion([NSURL fileURLWithPath:@"/tmp/pipeline.zip"],nil);});return p;
}
void SAPReleaseOfflineLibraryPackage(NSURL *url){}
int main(void){@autoreleasepool {
 calls=NSMutableArray.array;workers=NSMutableArray.array;roots=NSMutableArray.array;NSMutableArray *tracks=NSMutableArray.array;
 for(NSUInteger i=0;i<20;i++)[tracks addObject:@{@"uri":[NSString stringWithFormat:@"spotify:track:%02lu",(unsigned long)i],@"name":@"Title"}];
 job=SAPExportOfflineLibrarySelectionWithEvents(tracks,YES,nil,^(NSURL *url,NSArray *failures,NSString *error){assert(url&&!error&&!failures.count);for(NSURL *root in roots)[NSFileManager.defaultManager removeItemAtURL:root error:nil];puts("offline_library_pipeline PASS:20 conversions, producer overlap, stable order");exit(0);});
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{fputs("pipeline timeout\n",stderr);exit(2);});dispatch_main();
}}
