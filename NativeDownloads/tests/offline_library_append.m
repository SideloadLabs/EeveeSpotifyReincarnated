#import "OfflineLibraryExport.h"
#import "OfflineLibraryProgress.h"
#import "M4AConversionQueue.h"
#include <assert.h>
static NSMutableArray *calls,*nativeReplies,*packages;
static BOOL holdNative;
static NSUInteger released;
static NSURL *input;
NSString *SAPAudioExportFormat(void){return @"m4a";}
void SAPCancelAudioExport(void){}
NSDictionary *SAPAttachedExportArtwork(NSURL *url){return @{};}
void SAPAttachExportArtwork(NSURL *url,NSDictionary *art){}
void SAPRetainTemporaryAudioFiles(NSArray *urls,NSURL *root){}
NSProgress *SAPQueueM4AConversion(NSURL *input,NSURL *output,NSDictionary *track,NSDictionary *art,BOOL(^cancelled)(void),void(^completion)(SAPM4AExportStatus)){assert(0);return nil;}
void SAPExportAudioURIForBatch(NSString *uri,NSString *format,void(^progress)(NSString *),void(^completion)(NSArray *,NSString *)){
    [calls addObject:uri];
    if(holdNative)[nativeReplies addObject:[completion copy]];
    else dispatch_async(dispatch_get_main_queue(),^{completion(@[input],nil);});
}
NSProgress *SAPPrepareOfflineLibraryPackage(NSArray *tracks,BOOL zip,void(^progress)(double),void(^completion)(NSURL *,NSError *)){
    NSProgress *p=[NSProgress progressWithTotalUnitCount:1];p.cancellable=YES;
    [packages addObject:@{@"tracks":[tracks copy],@"zip":@(zip),@"progress":[progress copy],@"completion":[completion copy],@"operation":p}];return p;
}
void SAPReleaseOfflineLibraryPackage(NSURL *url){released++;}
static NSDictionary *row(NSString *key){return @{@"uri":[@"spotify:track:" stringByAppendingString:key],@"name":key};}
static void waitFor(BOOL(^done)(void)){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:5];while(!done()&&end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];assert(done());}
static void finishPackage(NSUInteger index,NSString *name){void(^completion)(NSURL *,NSError *)=packages[index][@"completion"];completion([NSURL fileURLWithPath:[@"/tmp/" stringByAppendingString:name]],nil);}
static void reset(void){calls=NSMutableArray.array;nativeReplies=NSMutableArray.array;packages=NSMutableArray.array;holdNative=NO;released=0;}
int main(void){@autoreleasepool{
    input=[NSURL fileURLWithPath:@"/tmp/already-encoded.m4a"];
    reset();holdNative=YES;__block NSUInteger completed=0;__block NSURL *result;
    SAPOfflineLibraryProgress *model=[[SAPOfflineLibraryProgress alloc]initWithTracks:@[row(@"a"),row(@"b")]];
    NSProgress *operation=SAPExportOfflineLibrarySelectionWithEvents(@[row(@"a"),row(@"b")],YES,^(NSDictionary *event){[model applyEvent:event];},^(NSURL *url,NSArray *failures,NSString *error){assert(!error&&!failures.count);completed++;result=url;});
    assert(SAPAppendOfflineLibrarySelection(operation,@[row(@"a"),row(@"c"),row(@"c"),@{@"uri":@"bad"}])==1);
    waitFor(^{return (BOOL)(nativeReplies.count==1);});
    assert(SAPAppendOfflineLibrarySelection(operation,@[row(@"a"),row(@"b"),row(@"c"),row(@"d")])==1);
    assert([[model stateForTrackURI:@"spotify:track:a"]isEqual:@"preparing"] && "adding work must preserve the in-flight track indicator");
    assert(operation.totalUnitCount==5 && [[model snapshotForTracks:nil][@"total"]unsignedIntegerValue]==4);
    assert([[model stateForTrackURI:@"spotify:track:d"]isEqual:@"queued"]);
    holdNative=NO;void(^native)(NSArray *,NSString *)=nativeReplies[0];native(@[input],nil);
    waitFor(^{return (BOOL)(packages.count==1);});
    assert(SAPAppendOfflineLibrarySelection(operation,@[row(@"a"),row(@"d")])==0);
    assert(([calls isEqual:@[@"spotify:track:a",@"spotify:track:b",@"spotify:track:c",@"spotify:track:d"]]));
    assert([packages[0][@"tracks"]count]==4 && [packages[0][@"zip"]boolValue]);
    finishPackage(0,@"union.zip");assert(completed==1 && result && SAPAppendOfflineLibrarySelection(operation,@[row(@"e")])==0);
    puts("PASS: append before start/during preparation deduplicates queued and completed tracks, expands progress and preserves order/options");
    reset();completed=0;result=nil;
    operation=SAPExportOfflineLibrarySelectionWithEvents(@[row(@"a"),row(@"b")],NO,nil,^(NSURL *url,NSArray *failures,NSString *error){assert(url&&!error);completed++;result=url;});
    waitFor(^{return (BOOL)(packages.count==1);});NSProgress *old=packages[0][@"operation"];
    assert(SAPAppendOfflineLibrarySelection(operation,@[row(@"a"),row(@"b"),row(@"c")])==1 && old.cancelled);
    waitFor(^{return (BOOL)(packages.count==2);});
    assert([packages[1][@"tracks"]count]==3 && ![packages[1][@"zip"]boolValue] && calls.count==3);
    void(^staleProgress)(double)=packages[0][@"progress"];staleProgress(.9);finishPackage(0,@"stale-folder");
    assert(completed==0 && released==1);finishPackage(1,@"current-folder");
    assert(completed==1 && [result.lastPathComponent isEqual:@"current-folder"]);
    puts("PASS: adding during packaging cancels only that attempt, reuses prepared audio and releases stale package callbacks");
    reset();completed=0;__block BOOL addedAtEntry=NO;__block NSProgress *entryOperation;
    entryOperation=SAPExportOfflineLibrarySelectionWithEvents(@[row(@"a"),row(@"b")],YES,^(NSDictionary *event){
        if(!addedAtEntry && [event[@"phase"]isEqual:@"packaging"]){addedAtEntry=YES;assert(SAPAppendOfflineLibrarySelection(entryOperation,@[row(@"c")])==1);}
    },^(NSURL *url,NSArray *failures,NSString *error){assert(url&&!error);completed++;});
    waitFor(^{return (BOOL)(packages.count==1);});assert(addedAtEntry && calls.count==3 && [packages[0][@"tracks"]count]==3);
    finishPackage(0,@"entry-union.zip");assert(completed==1);
    puts("PASS: reentrant append at packaging entry cannot start an obsolete package");
    reset();holdNative=YES;completed=0;
    operation=SAPExportOfflineLibrarySelectionWithEvents(@[row(@"a")],NO,nil,^(NSURL *url,NSArray *failures,NSString *error){assert(!url&&error.length);completed++;});
    waitFor(^{return (BOOL)(nativeReplies.count==1);});[operation cancel];
    assert(SAPAppendOfflineLibrarySelection(operation,@[row(@"b")])==0);
    waitFor(^{return (BOOL)(completed==1);});native=nativeReplies[0];native(@[input],nil);
    assert(calls.count==1 && packages.count==0 && SAPAppendOfflineLibrarySelection(operation,@[row(@"b")])==0);
    puts("PASS: cancelled/finished operations reject additions and late native replies do not restart work");
}return 0;}
