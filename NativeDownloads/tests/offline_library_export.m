#import <Foundation/Foundation.h>
#import "OfflineLibraryExport.h"
#import "OfflineLibraryPackage.h"
#import "M4AConversionQueue.h"
#import <assert.h>

static NSString *format = @"m4a";
static NSMutableArray *calls;
static NSString *scenario;
static NSMutableArray<NSDictionary *> *events;
static NSUInteger active, maximum, cancelled, packaged;
static void (^held)(NSArray *,NSString *);
static NSProgress *operation;
static NSURL *input;
NSString *SAPAudioExportFormat(void) { return format; }
void SAPCancelAudioExport(void) { cancelled++; active = 0; }
void SAPExportAudioURI(NSString *uri,void (^progress)(NSString *),void (^completion)(NSArray *,NSString *)) {
    [calls addObject:uri];
    if ([scenario isEqual:@"busy"]) { completion(nil,@"Another export is already running."); return; }
    active++; maximum=MAX(maximum,active);
    if ([scenario isEqual:@"cancel"]) { held=[completion copy]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        active--;
        if ([scenario isEqual:@"format"]) format=@"ogg";
        completion([uri hasSuffix:@"bad"]?nil:@[input],[uri hasSuffix:@"bad"]?@"No readable native audio":nil);
    });
}

void SAPExportAudioURIForBatch(NSString *uri,NSString *format,void (^progress)(NSString *),void (^completion)(NSArray *,NSString *)){SAPExportAudioURI(uri,progress,completion);}
NSDictionary *SAPAttachedExportArtwork(NSURL *file){return @{};}
void SAPAttachExportArtwork(NSURL *file,NSDictionary *artwork){}
void SAPRetainTemporaryAudioFiles(NSArray *files,NSURL *root){}
NSProgress *SAPQueueM4AConversion(NSURL *input,NSURL *output,NSDictionary *track,NSDictionary *art,BOOL (^cancelled)(void),void (^completion)(SAPM4AExportStatus)){assert(!"Unexpected conversion of existing M4A");return nil;}
NSProgress *SAPPrepareOfflineLibraryPackage(NSArray *tracks,BOOL zip,void (^progress)(double),void (^completion)(NSURL *,NSError *)) {
    packaged++;
    assert(zip); assert(tracks.count == 2);
    assert([tracks[0][@"uri"] isEqual:@"spotify:track:a"]);
    assert([tracks[1][@"uri"] isEqual:@"spotify:track:b"]);
    assert([tracks[0][@"file"] isEqual:input]);
    NSProgress *p=[NSProgress progressWithTotalUnitCount:1];
    dispatch_async(dispatch_get_main_queue(), ^{if(progress)progress(.25);if(progress)progress(.75);p.completedUnitCount=1;completion([NSURL fileURLWithPath:@"/tmp/offline-test.zip"],nil);});
    return p;
}
void SAPReleaseOfflineLibraryPackage(NSURL *url) {}
static NSDictionary *row(NSString *identity) { return @{@"uri":[@"spotify:track:" stringByAppendingString:identity],@"name":identity,@"artist_name":@"Artist",@"album_name":@"Album"}; }
static void reset(NSString *name) {scenario=name; calls=NSMutableArray.array;active=maximum=cancelled=packaged=0;format=@"m4a";}
static void testCancel(void) {
    reset(@"cancel");
    operation=SAPExportOfflineLibrarySelection(@[row(@"a"),row(@"b")],YES,nil,^(NSURL *url,NSArray *failures,NSString *error){
        assert(!url && error.length); assert(cancelled==1); assert(calls.count==1); assert(!packaged);
        held(@[input],nil); held=nil;
        dispatch_async(dispatch_get_main_queue(), ^{assert(calls.count==1 && !packaged); puts("offline_library_export PASS"); exit(0);});
    });
    dispatch_async(dispatch_get_main_queue(), ^{[operation cancel];});
}
static void testFormat(void) {
    reset(@"format");
    operation=SAPExportOfflineLibrarySelection(@[row(@"a"),row(@"b")],YES,nil,^(NSURL *url,NSArray *failures,NSString *error){
        assert(!url && error.length); assert(calls.count==1 && !packaged && !cancelled); testCancel();
    });
}
static void testBusy(void) {
    reset(@"busy");
    operation=SAPExportOfflineLibrarySelection(@[row(@"a"),row(@"b")],YES,nil,^(NSURL *url,NSArray *failures,NSString *error){
        assert(!url && [error containsString:@"already running"]); assert(calls.count==1 && !cancelled && !packaged); testFormat();
    });
}
int main(void) { @autoreleasepool {
    input=[NSURL fileURLWithPath:@"/tmp/offline-input.m4a"];
    reset(@"partial");events=NSMutableArray.array;
    operation=SAPExportOfflineLibrarySelectionWithEvents(@[row(@"a"),row(@"bad"),row(@"b"),row(@"a")],YES,^(NSDictionary *event){[events addObject:event];},^(NSURL *url,NSArray *failures,NSString *error){
        assert(url && !error); assert(failures.count==1 && [failures[0][@"uri"] hasSuffix:@"bad"]);
        assert([failures[0][@"error"] containsString:@"No readable"]); assert(calls.count==3 && maximum==1 && packaged==1);
        NSArray *prepared=[events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"phase == 'prepared'"]];
        assert(prepared.count==3 && [prepared[0][@"uri"]hasSuffix:@"a"] && ![prepared[1][@"success"]boolValue]);
        assert([events.lastObject[@"phase"]isEqual:@"ready"]);
        NSArray *packing=[events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"phase == 'packaging'"]];
        assert(packing.count>=3 && [packing.lastObject[@"fraction"]doubleValue]==.75);testBusy();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{fputs("fixture timeout\n",stderr);exit(2);});
    dispatch_main();
} }
