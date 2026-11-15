// Executes the production state/lifecycle methods with Foundation-only UI
// boundaries. Native catalog membership/cache behavior has its own fixture.
#import <Foundation/Foundation.h>
#import "OfflineLibraryProgress.h"
#import "OfflineLibrarySelection.h"
#define SAP_TRACE(...) ((void)0)
#include <assert.h>
#include "OfflineLibraryRefreshHelpers.inc"
@class SAPOfflineLibraryController;
@interface UIViewController:NSObject
@property(nonatomic,getter=isViewLoaded) BOOL viewLoaded;
@property(nonatomic,strong) UIViewController *presentedViewController;
- (void)viewDidAppear:(BOOL)animated;
@end
@implementation UIViewController
- (void)viewDidAppear:(BOOL)animated {}
@end
@interface RefreshNavigation:NSObject
@property(nonatomic,copy) NSArray *viewControllers;
@property(nonatomic,readonly) UIViewController *topViewController;
@end
@implementation RefreshNavigation
- (UIViewController *)topViewController{return self.viewControllers.lastObject;}
@end
@interface RefreshLabel:NSObject
@property(nonatomic) BOOL hidden;
@property(nonatomic,copy) NSString *text;
@end
@implementation RefreshLabel @end
@interface RefreshSpinner:NSObject
@property(nonatomic) BOOL animating;
- (void)startAnimating;
- (void)stopAnimating;
@end
@implementation RefreshSpinner
- (void)startAnimating {self.animating=YES;}
- (void)stopAnimating {self.animating=NO;}
@end
@interface SAPOfflineLibraryState:NSObject
@property(nonatomic,weak) SAPOfflineLibraryController *root;
@property(nonatomic,strong) RefreshNavigation *navigation;
@property(nonatomic,copy) NSArray *tracks,*artists;
@property(nonatomic,strong) NSMutableSet *selectedURIs,*selectedArtistKeys;
@property(nonatomic,copy) dispatch_block_t catalogCancel;
@property(nonatomic) NSUInteger catalogGeneration,loadCompleted,loadTotal,messages;
@property(nonatomic) BOOL dismissed;
@property(nonatomic,strong) NSProgress *deleteProgress,*exportProgress;
@property(nonatomic,strong) SAPOfflineLibraryProgress *progressModel;
@property(nonatomic,strong) NSURL *pendingPackage;
@property(nonatomic,copy) NSArray *pendingFailures;
@property(nonatomic) BOOL exportCancelled,selecting,pendingSave;
@property(nonatomic) NSUInteger reviews;
- (void)beginExport:(NSArray *)rows zip:(BOOL)zip save:(BOOL)save;
- (void)appendExportRows:(NSArray *)rows;
- (void)releasePendingPackage;
- (void)refreshProgress;
- (void)reviewPackage;
- (void)load;
- (void)refresh;
- (void)refreshSelection;
- (void)showMessage:(NSString *)title detail:(NSString *)detail;
@end
@interface SAPOfflineLibraryController:UIViewController
@property(nonatomic,strong) SAPOfflineLibraryState *state;
@property(nonatomic,copy) NSString *title,*pageTitle,*artistKey,*releaseKey;
@property(nonatomic,copy) NSArray *scope,*releaseSections;
@property(nonatomic) NSInteger level;
@property(nonatomic) NSUInteger applications;
@property(nonatomic,strong) RefreshLabel *loadingLabel;
@property(nonatomic,strong) RefreshSpinner *loadingSpinner;
+ (NSArray *)artistRowsForTracks:(NSArray *)tracks;
- (NSArray *)buildReleaseSections;
- (void)applyCatalogSnapshot;
- (void)updateLoading;
- (void)updateToolbar;
- (void)updateBottomControls;
- (void)updateProgressPanel;
- (void)refreshSelection;
- (void)refreshCatalog;
- (void)progressActionTapped;
- (NSArray *)selectedRows;
- (NSArray *)newExportRows;
@end
static NSArray *snapshot;
static NSMutableArray *requests;
static NSUInteger cancellations;
NSArray *SAPOfflineLibraryCachedTracks(void) {return snapshot;}
dispatch_block_t SAPFetchOfflineLibrary(void(^progress)(NSUInteger,NSUInteger),void(^completion)(NSArray *,NSString *)) {
    [requests addObject:@{@"progress":[progress copy],@"completion":[completion copy]}];
    // Keep callback intentionally deliverable after cancel to check the real
    // state's generation guard against a misbehaving transport boundary.
    return ^{cancellations++;};
}
static void (^exportEvent)(NSDictionary *);
static void (^exportCompletion)(NSURL *,NSArray *,NSString *);
static NSUInteger releasedPackages;
static NSProgress *currentOperation;
static NSMutableSet *queuedURIs;
NSString *SAPAudioExportFormat(void){return @"m4a";}
NSProgress *SAPExportOfflineLibrarySelectionWithEvents(NSArray *rows,BOOL zip,void(^event)(NSDictionary *),void(^completion)(NSURL *,NSArray *,NSString *)) {
    exportEvent=[event copy];exportCompletion=[completion copy];
    NSProgress *p=[NSProgress progressWithTotalUnitCount:10];p.cancellable=YES;currentOperation=p;queuedURIs=NSMutableSet.set;for(NSDictionary *row in rows)[queuedURIs addObject:row[@"uri"]];return p;
}
NSUInteger SAPAppendOfflineLibrarySelection(NSProgress *operation,NSArray *rows) {
    if(operation!=currentOperation || operation.cancelled)return 0;
    NSMutableArray *added=NSMutableArray.array;
    for(NSDictionary *row in rows)if(![queuedURIs containsObject:row[@"uri"]]){[queuedURIs addObject:row[@"uri"]];[added addObject:row[@"uri"]];}
    if(added.count)exportEvent(@{@"phase":@"queue_extended",@"uris":added});return added.count;
}
void SAPReleaseOfflineLibraryPackage(NSURL *url){assert(url);releasedPackages++;}
@implementation SAPOfflineLibraryState
#include "OfflineLibraryRefreshState.inc"
- (void)refreshSelection {}
- (void)refreshProgress {}
- (void)reviewPackage {self.reviews++;}
- (void)showMessage:(NSString *)title detail:(NSString *)detail {self.messages++;}
@end
@implementation SAPOfflineLibraryController
#include "OfflineLibraryRefreshController.inc"
- (void)applyCatalogSnapshot {self.applications++;}
- (void)updateToolbar {}
- (void)updateBottomControls {}
- (void)updateProgressPanel {}
- (void)refreshSelection {}
@end
static void deliver(NSUInteger index,NSArray *rows,NSString *error) {
    void(^completion)(NSArray *,NSString *)=requests[index][@"completion"];completion(rows,error);
}
static SAPOfflineLibraryController *openManager(NSArray *rows) {
    snapshot=rows;requests=NSMutableArray.array;cancellations=0;
    SAPOfflineLibraryState *state=SAPOfflineLibraryState.new;
    SAPOfflineLibraryController *root=SAPOfflineLibraryController.new;
    root.state=state;root.viewLoaded=YES;root.loadingLabel=RefreshLabel.new;root.loadingSpinner=RefreshSpinner.new;
    state.root=root;state.navigation=RefreshNavigation.new;state.navigation.viewControllers=@[root];
    return root;
}
int main(void) {@autoreleasepool {
    NSDictionary *a=@{@"uri":@"a",@"artist_uri":@"artist-a",@"artist_name":@"A",@"album_uri":@"album-a",@"album_name":@"Album A"};
    NSDictionary *b=@{@"uri":@"b",@"artist_uri":@"artist-b",@"artist_name":@"B",@"album_uri":@"album-b",@"album_name":@"Album B"};
    SAPOfflineLibraryController *root=openManager(@[a,b]);SAPOfflineLibraryState *state=root.state;
    assert(state.tracks.count==2 && state.artists.count==2 && requests.count==0);
    [root viewDidAppear:NO];assert(requests.count==1 && state.tracks.count==2 && !root.loadingSpinner.animating);
    [root viewDidAppear:NO];assert(requests.count==1);
    deliver(0,nil,@"unavailable");assert(state.tracks.count==2 && state.messages==1);
    [state.selectedURIs addObjectsFromArray:@[@"a",@"b"]];[root refreshCatalog];
    assert(requests.count==2 && state.tracks.count==2 && state.selectedURIs.count==2);
    SAPOfflineLibraryController *hidden=SAPOfflineLibraryController.new;hidden.state=state;hidden.level=1;hidden.artistKey=@"artist-a";hidden.scope=@[a];
    SAPOfflineLibraryController *child=SAPOfflineLibraryController.new;child.state=state;child.level=2;child.artistKey=@"artist-b";child.releaseKey=@"album-b";child.scope=@[b];child.viewLoaded=YES;
    state.navigation.viewControllers=@[root,hidden,child];
    deliver(1,@[b],nil);
    assert(state.tracks.count==1 && state.artists.count==1 && state.selectedURIs.count==1 && [state.selectedURIs containsObject:@"b"]);
    assert(hidden.scope.count==0 && hidden.releaseSections.count==0 && hidden.applications==0);
    assert(child.scope.count==1 && [child.scope.firstObject[@"uri"]isEqual:@"b"] && child.applications==1);
    [root viewDidAppear:NO];assert(requests.count==2);
    puts("PASS: immediate cached rows, one entry scan, error retention, preserved selection and hidden/open child scopes");
    NSDictionary *c=@{@"uri":@"c",@"artist_uri":@"artist-c",@"artist_name":@"C",@"album_uri":@"album-c",@"album_name":@"Album C"};
    [root refreshCatalog];deliver(2,@[b,c],nil);
    assert(state.artists.count==2 && [state.artists[0][@"name"]isEqual:@"B"] && [state.artists[1][@"name"]isEqual:@"C"] && [state.selectedURIs containsObject:@"b"]);
    assert(child.scope.count==1 && [child.scope.firstObject[@"uri"]isEqual:@"b"]);
    puts("PASS: a new artist appears while selection and the open release remain intact");
    [root refreshCatalog];[root refreshCatalog];assert(requests.count==5 && cancellations==1);
    deliver(3,@[a,b],nil);assert(state.tracks.count==2 && [state.tracks.firstObject[@"uri"]isEqual:@"b"] && state.catalogCancel!=nil);
    deliver(4,@[],nil);assert(state.tracks!=nil && state.tracks.count==0 && state.artists.count==0 && state.selectedURIs.count==0);
    [root refreshCatalog];assert(!root.loadingSpinner.animating && [root.loadingLabel.text isEqual:@"No downloaded tracks"]);
    state.dismissed=YES;deliver(5,@[a],nil);assert(state.tracks.count==0);
    puts("PASS: superseded/dismissed callbacks ignored; successful empty refresh replaces old rows without blocking next check");
    root=openManager(@[]);[root viewDidAppear:NO];assert(requests.count==1 && !root.loadingSpinner.animating);
    root=openManager(nil);[root viewDidAppear:NO];assert(requests.count==1 && root.loadingSpinner.animating);
    deliver(0,@[a],nil);assert(!root.loadingSpinner.animating && root.state.tracks.count==1);
    puts("PASS: cached empty results still revalidate; only the first uncached scan shows blocking loading");
    NSDictionary *unknown=@{@"uri":@"a",@"artist_name":@"Unknown artist",@"album_name":@"Unknown album"};
    root=openManager(@[unknown]);state=root.state;
    hidden=SAPOfflineLibraryController.new;hidden.state=state;hidden.level=1;hidden.artistKey=SAPOfflineArtistKey(unknown);hidden.scope=@[unknown];
    child=SAPOfflineLibraryController.new;child.state=state;child.level=2;child.artistKey=hidden.artistKey;child.releaseKey=SAPOfflineReleaseKey(unknown);child.scope=@[unknown];child.viewLoaded=YES;
    state.navigation.viewControllers=@[root,hidden,child];[root viewDidAppear:NO];deliver(0,@[a],nil);
    assert(hidden.scope.count==1 && [hidden.artistKey isEqual:@"artist-a"] && [hidden.title isEqual:@"A"]);
    assert(child.scope.count==1 && [child.artistKey isEqual:@"artist-a"] && [child.releaseKey isEqual:@"album-a"] && [child.title isEqual:@"Album A"]);
    puts("PASS: recovered metadata migrates open and hidden child identities without emptying surviving tracks");
    root=openManager(@[a]);state=root.state;releasedPackages=0;
    [state beginExport:@[a] zip:NO save:NO];NSProgress *operation=state.exportProgress;
    assert([[state.progressModel snapshotForTracks:nil][@"visible"]boolValue]);
    [root progressActionTapped];
    assert(operation.cancelled && state.progressModel==nil && "Cancel must remove the progress panel immediately, before completion or Done");
    [root progressActionTapped];exportEvent(@{@"phase":@"cancelled"});
    assert(state.progressModel==nil && state.pendingPackage==nil);
    exportCompletion(nil,@[],@"Export cancelled.");
    assert(state.exportProgress==nil && state.progressModel==nil && state.messages==0 && state.reviews==0);
    puts("PASS: Cancel immediately clears progress, requests worker cancellation and needs no Done after completion");
    [state beginExport:@[a] zip:NO save:NO];[root progressActionTapped];
    exportCompletion([NSURL fileURLWithPath:@"/tmp/cancelled-late-package"],@[],nil);
    assert(releasedPackages==1 && state.pendingPackage==nil && state.progressModel==nil && state.reviews==0);
    [state beginExport:@[a] zip:NO save:NO];exportEvent(@{@"phase":@"ready"});
    exportCompletion([NSURL fileURLWithPath:@"/tmp/ready-package"],@[],nil);
    assert(state.pendingPackage!=nil && state.progressModel!=nil && state.reviews==1);
    [root progressActionTapped];assert(state.pendingPackage==nil && state.progressModel==nil && releasedPackages==2);
    puts("PASS: cancelled late packages are released; successful exports still retain Share/Done until dismissed");
    // After a finished export the user may select again and export again without Done.
    [state beginExport:@[a] zip:NO save:NO];exportEvent(@{@"phase":@"ready"});
    exportCompletion([NSURL fileURLWithPath:@"/tmp/first-package"],@[],nil);
    assert(state.pendingPackage!=nil && state.exportProgress==nil && releasedPackages==2);
    state.selecting=YES;
    [state beginExport:@[a] zip:NO save:NO];
    assert(releasedPackages==3 && state.exportProgress!=nil && state.pendingPackage==nil && !state.selecting && "the previous package is released exactly once and a new export starts");
    [root progressActionTapped];exportCompletion(nil,@[],@"Export cancelled.");
    assert(releasedPackages==3 && state.exportProgress==nil && state.pendingPackage==nil);
    puts("PASS: a finished export no longer blocks Select and Export selected until Done");
    root=openManager(@[a,b]);state=root.state;[state beginExport:@[a] zip:NO save:NO];operation=state.exportProgress;
    state.selecting=YES;[state.selectedURIs addObjectsFromArray:@[@"a",@"b"]];
    assert([root newExportRows].count==1 && [[root newExportRows].firstObject[@"uri"]isEqual:@"b"]);
    [state appendExportRows:[root selectedRows]];
    assert(state.exportProgress==operation && !state.selecting && state.selectedURIs.count==0 && [[state.progressModel snapshotForTracks:nil][@"total"]unsignedIntegerValue]==2);
    state.tracks=@[a,b,c];state.selecting=YES;[state.selectedURIs addObjectsFromArray:@[@"a",@"b",@"c"]];
    assert([root newExportRows].count==1 && [[root newExportRows].firstObject[@"uri"]isEqual:@"c"]);
    [state appendExportRows:[root selectedRows]];assert([[state.progressModel snapshotForTracks:nil][@"total"]unsignedIntegerValue]==3);
    [root progressActionTapped];exportCompletion(nil,@[],@"cancelled");
    puts("PASS: selection during export adds only newly selected track identities into the same operation");
    root=openManager(@[b]);state=root.state;[state beginExport:@[b] zip:NO save:NO];operation=state.exportProgress;
    state.selecting=YES;[state.selectedURIs addObject:@"b"];[state.selectedArtistKeys addObject:@"artist-b"];
    [state load];NSDictionary *single=@{@"uri":@"new-single",@"artist_uri":@"artist-b",@"artist_name":@"B",@"album_uri":@"new-release",@"album_name":@"New single"};
    deliver(0,@[b,single],nil);
    assert([state.selectedURIs containsObject:@"new-single"] && [root newExportRows].count==1);
    [state appendExportRows:[root selectedRows]];
    assert(state.exportProgress==operation && [[state.progressModel snapshotForTracks:nil][@"total"]unsignedIntegerValue]==2 && state.selectedArtistKeys.count==0);
    [root progressActionTapped];exportCompletion(nil,@[],@"cancelled");
    puts("PASS: fresh native catalog adds the selected artist's new single without queuing its existing track twice");
}return 0;}
