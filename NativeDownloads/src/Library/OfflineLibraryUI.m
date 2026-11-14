#import "OfflineLibraryUI.h"
#import "OfflineLibraryCatalog.h"
#import "OfflineLibraryExport.h"
#import "OfflineLibraryDelete.h"
#import "SpotifyCacheClear.h"
#import "TrackExport.h"
#import "OfflineLibraryPackage.h"
#import "../Artwork/ArtistArtworkLoader.h"
#import "OfflineLibrarySelection.h"
#import "OfflineLibraryChrome.h"
#import "OfflineLibraryProgress.h"
#import "DiagnosticTrace.h"
#import "../UI/ArtistDownloadComponents.h"
#import "../UI/ArtistListAppearance.h"
#import "PixiePageController.h"
#import <QuartzCore/QuartzCore.h>

static NSString * const SAPOfflineUnknownArtist = @"Unknown artist";
static NSString * const SAPOfflineUnknownAlbum = @"Unknown album";
static NSString *SAPOfflineString(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : fallback;
}
static NSString *SAPOfflineArtistKey(NSDictionary *row) {
    NSString *uri = SAPOfflineString(row[@"artist_uri"], @"");
    return uri.length ? uri : [NSString stringWithFormat:@"%@|%@", SAPOfflineString(row[@"artist_name"], SAPOfflineUnknownArtist), SAPOfflineString(row[@"uri"], @"")];
}
static NSString *SAPOfflineReleaseKey(NSDictionary *row) {
    NSString *uri = SAPOfflineString(row[@"album_uri"], @"");
    return uri.length ? uri : [NSString stringWithFormat:@"%@|%@", SAPOfflineString(row[@"album_name"], SAPOfflineUnknownAlbum), SAPOfflineString(row[@"uri"], @"")];
}

@class SAPOfflineLibraryController,SAPOfflineArtworkCell;
@interface SAPOfflineLibraryState : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,weak) SAPOfflineLibraryController *root;
@property(nonatomic) BOOL originalToolbarHidden;
@property(nonatomic) NSUInteger loadCompleted,loadTotal;
@property(nonatomic,weak) UINavigationController *navigation;
@property(nonatomic,copy) NSArray<NSDictionary *> *tracks;
@property(nonatomic,copy) NSArray<NSDictionary *> *artists;
@property(nonatomic,strong) NSMutableSet<NSString *> *selectedURIs,*selectedArtistKeys;
@property(nonatomic,copy) dispatch_block_t catalogCancel;
@property(nonatomic,strong) NSProgress *exportProgress;
@property(nonatomic,strong) NSProgress *deleteProgress;
@property(nonatomic,strong) NSURL *pendingPackage;
@property(nonatomic,strong) SAPOfflineLibraryProgress *progressModel;
@property(nonatomic,copy) NSArray<NSDictionary *> *pendingFailures;
@property(nonatomic) BOOL pendingSave;
@property(nonatomic) BOOL selecting;
@property(nonatomic) BOOL dismissed;
@property(nonatomic) BOOL exportCancelled;
@property(nonatomic) NSUInteger catalogGeneration;
- (void)load;
- (void)refresh;
- (void)exportRows:(NSArray<NSDictionary *> *)rows save:(BOOL)save;
- (void)appendExportRows:(NSArray<NSDictionary *> *)rows;
- (void)deleteRows:(NSArray<NSDictionary *> *)rows;
- (void)cancelWork;
- (void)refreshSelection;
- (void)refreshProgress;
- (void)reviewPackage;
- (void)releasePendingPackage;
@end

@interface SAPOfflineLibraryController : SAPPixiePageController
+ (NSArray<NSDictionary *> *)artistRowsForTracks:(NSArray<NSDictionary *> *)tracks;
@property(nonatomic,strong) SAPOfflineLibraryState *state;
@property(nonatomic,copy) NSArray<NSDictionary *> *scope;
@property(nonatomic,copy) NSString *pageTitle;
@property(nonatomic) NSInteger level; // 0 artists, 1 artist releases grouped by category, 2 tracks
@property(nonatomic,copy) NSString *category;
@property(nonatomic,copy) NSString *artistKey;
@property(nonatomic,copy) NSString *releaseKey;
@property(nonatomic,copy) NSArray<NSDictionary *> *releaseSections;
@property(nonatomic,strong) UIBarButtonItem *selectButton,*exportButton;
@property(nonatomic,strong) UIBarButtonItem *deleteButton;
@property(nonatomic,strong) UIView *loadingBackground;
@property(nonatomic,strong) UIToolbar *exportToolbar;
@property(nonatomic,strong) NSLayoutConstraint *exportToolbarBottom;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *exportToolbarConstraints;
@property(nonatomic,strong) SAPOfflineLibraryChrome *bottomChrome;
@property(nonatomic) CGFloat baseBottomInset,appliedBottomInset;
@property(nonatomic) BOOL updatingBottomControls,updatingProgressPanel;
@property(nonatomic,strong) UIView *progressHeader,*progressPanel;
@property(nonatomic,strong) UILabel *progressTitle,*progressDetail;
@property(nonatomic,strong) UIProgressView *progressBar;
@property(nonatomic,weak) SAPOfflineLibraryProgress *displayedProgressModel;
@property(nonatomic,strong) UIButton *progressAction,*progressShareAction;
@property(nonatomic,strong) NSLayoutConstraint *progressActionHeight,*progressTitleTrailing;
@property(nonatomic,strong) UILabel *loadingLabel;
@property(nonatomic,strong) UIActivityIndicatorView *loadingSpinner;
@property(nonatomic,strong) UITableViewDiffableDataSource<NSString *,NSString *> *catalogDataSource;
@property(nonatomic,copy) NSDictionary<NSString *,NSDictionary *> *catalogItems;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *catalogCategories;
@property(nonatomic) NSUInteger snapshotGeneration;
- (void)applyCatalogSnapshot;
- (UITableViewCell *)catalogCellForTable:(UITableView *)table identifier:(NSString *)identifier;
- (void)configureCell:(SAPArtistReleaseCell *)base identifier:(NSString *)identifier;
- (void)updateToolbar;
- (void)updateBottomControls;
- (void)updateProgressPanel;
- (void)layoutProgressPanel:(BOOL)insert;
- (void)refreshSelection;
- (NSArray<NSDictionary *> *)newExportRows;
- (void)updateLoading;
- (void)configureCell:(SAPArtistReleaseCell *)cell atIndexPath:(NSIndexPath *)path;
- (void)configureIndicator:(SAPOfflineArtworkCell *)cell rows:(NSArray<NSDictionary *> *)rows;
- (NSArray<NSDictionary *> *)buildReleaseSections;
@end

@interface SAPOfflineArtworkCell : SAPArtistReleaseCell
@property(nonatomic,copy) NSString *imageIdentity,*artworkURL;
@end
@implementation SAPOfflineArtworkCell
- (void)prepareForReuse {
    [super prepareForReuse];self.imageIdentity=nil;self.artworkURL=nil;
}
@end

@implementation SAPOfflineLibraryState
- (instancetype)init {
    if ((self = [super init])) {
        self.selectedURIs = NSMutableSet.set;self.selectedArtistKeys=NSMutableSet.set;
        self.tracks=SAPOfflineLibraryCachedTracks();
        if(self.tracks)self.artists=[SAPOfflineLibraryController artistRowsForTracks:self.tracks];
    }
    return self;
}
- (void)load {
    self.dismissed = NO; self.loadCompleted=0;self.loadTotal=0;
    if (self.catalogCancel) { self.catalogCancel(); self.catalogCancel = nil; }
    NSUInteger generation = ++self.catalogGeneration;
    SAPOfflineLibraryController *root=self.root;
    root.title=@"Downloaded tracks";
    __weak typeof(self) weakSelf = self;
    self.catalogCancel = SAPFetchOfflineLibrary(^(NSUInteger done, NSUInteger total) {
        SAPOfflineLibraryState *self = weakSelf; if (!self || self.dismissed || generation != self.catalogGeneration) return;
        self.loadCompleted=done;self.loadTotal=total;if(!self.tracks)[self.root updateLoading];
    }, ^(NSArray<NSDictionary *> *tracks, NSString *error) {
        SAPOfflineLibraryState *self = weakSelf; if (!self || self.dismissed || generation != self.catalogGeneration) return;
        self.catalogCancel = nil;
        self.root.title=@"Downloaded tracks";
        if (!tracks) {
            [self refresh];
            [self showMessage:@"Couldn’t load downloads" detail:error ?: @"The native offline catalog is unavailable."];
            return;
        }
        BOOL changed=![self.tracks isEqualToArray:tracks];
        self.tracks = tracks;
        if(changed)self.artists = [SAPOfflineLibraryController artistRowsForTracks:tracks];
        NSMutableSet *available = NSMutableSet.set;
        for (NSDictionary *row in tracks) if ([row[@"uri"] isKindOfClass:NSString.class]) [available addObject:row[@"uri"]];
        [self.selectedURIs intersectSet:available];
        if(self.selecting)for(NSDictionary *row in tracks)if([self.selectedArtistKeys containsObject:SAPOfflineArtistKey(row)])[self.selectedURIs addObject:row[@"uri"]];
        if(changed)[self refresh];else{[self.root updateLoading];[self refreshSelection];}
        if (error.length) [self showMessage:@"Some track details are unavailable" detail:error];
    });
    [root updateLoading];
}
- (void)refresh {
    NSMutableDictionary *byURI=NSMutableDictionary.dictionary,*byArtist=NSMutableDictionary.dictionary;
    for(NSDictionary *row in self.tracks)byURI[row[@"uri"]]=row;
    for(NSDictionary *artist in self.artists)byArtist[artist[@"key"]]=artist;
    for(UIViewController *controller in self.navigation.viewControllers) {
        if([controller isKindOfClass:SAPOfflineLibraryController.class]) {
            SAPOfflineLibraryController *page=(id)controller;
            if(page.level>0&&self.tracks) {
                NSDictionary *artist=byArtist[page.artistKey],*survivor=nil;
                for(NSDictionary *old in page.scope) {
                    NSDictionary *row=byURI[old[@"uri"]];
                    if(row && (!artist || [SAPOfflineArtistKey(row)isEqual:page.artistKey])){survivor=row;break;}
                }
                // A cached metadata failure used a per-track fallback identity.
                // Follow the surviving track when hydration recovers its real
                // artist/release instead of blanking the page the user opened.
                if(!artist && survivor){page.artistKey=SAPOfflineArtistKey(survivor);artist=byArtist[page.artistKey];}
                if(page.level==2 && survivor) {
                    BOOL releaseExists=NO;
                    for(NSDictionary *row in artist[@"tracks"])if([SAPOfflineReleaseKey(row)isEqual:page.releaseKey]){releaseExists=YES;break;}
                    if(!releaseExists)page.releaseKey=SAPOfflineReleaseKey(survivor);
                }
                NSMutableArray *scope=NSMutableArray.array;
                for(NSDictionary *row in artist[@"tracks"])if(page.level==1||[SAPOfflineReleaseKey(row)isEqual:page.releaseKey])[scope addObject:row];
                page.scope=scope;
                if(page.level==1){page.releaseSections=[page buildReleaseSections];if(artist)page.pageTitle=artist[@"name"];}
                else if(scope.count)page.pageTitle=scope.firstObject[@"album_name"];
                if(page.pageTitle.length)page.title=page.pageTitle;
            }
            if(page.isViewLoaded){[page applyCatalogSnapshot];[page updateLoading];[page updateToolbar];}
        }
    }
}
- (void)refreshSelection {
    for(UIViewController *controller in self.navigation.viewControllers)
        if([controller isKindOfClass:SAPOfflineLibraryController.class] && controller.isViewLoaded)[(SAPOfflineLibraryController *)controller refreshSelection];
}
- (void)refreshProgress {
    for(UIViewController *controller in self.navigation.viewControllers)
        if([controller isKindOfClass:SAPOfflineLibraryController.class] && controller.isViewLoaded) {
            SAPOfflineLibraryController *page=(id)controller;[page updateToolbar];
            if(page.level==2)for(NSIndexPath *path in page.tableView.indexPathsForVisibleRows)
                if(path.row>=0&&(NSUInteger)path.row<page.scope.count)[page configureIndicator:(id)[page.tableView cellForRowAtIndexPath:path] rows:@[page.scope[path.row]]];
        }
}
- (void)showMessage:(NSString *)title detail:(NSString *)detail {
    if(self.dismissed || !self.navigation.topViewController.viewIfLoaded.window)return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self.navigation.topViewController presentViewController:alert animated:YES completion:nil];
}
// After a deletion Spotify keeps the files of removed downloads in its cache. The button runs Spotify's
// own "Clear cache" (Storage.DeleteUnlockedItems); downloads that are still active are never touched.
- (void)showDeleted:(NSString *)title detail:(NSString *)detail offerCacheClear:(BOOL)offer {
    if(!offer){[self showMessage:title detail:detail];return;}
    if(self.dismissed || !self.navigation.topViewController.viewIfLoaded.window)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear Spotify cache" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weakSelf clearSpotifyCache];}]];
    alert.preferredAction=alert.actions.lastObject;
    [self.navigation.topViewController presentViewController:alert animated:YES completion:nil];
}
- (void)clearSpotifyCache {
    __weak typeof(self) weakSelf=self;
    SAPClearSpotifyCache(^(NSDictionary *result,NSString *error){
        SAPOfflineLibraryState *self=weakSelf;if(!self||self.dismissed)return;
        if(error.length){[self showMessage:@"Couldn’t clear cache" detail:error];return;}
        unsigned long long freed=[result[@"freed_bytes"]unsignedLongLongValue];
        NSString *detail=result[@"freed_bytes"]?(freed?[NSString stringWithFormat:@"Freed %@.",[NSByteCountFormatter stringFromByteCount:(long long)freed countStyle:NSByteCountFormatterCountStyleFile]]:@"Nothing more to clear."):@"Spotify cleared its cache.";
        [self showMessage:@"Cache cleared" detail:detail];
    });
}
- (void)cancelWork {
    self.dismissed = YES;
    self.catalogGeneration++;
    if (self.catalogCancel) { self.catalogCancel(); self.catalogCancel = nil; }
    if (self.exportProgress && !self.exportProgress.finished) [self.exportProgress cancel];
    [self.deleteProgress cancel];
    [self releasePendingPackage];
}
- (void)exportRows:(NSArray<NSDictionary *> *)rows save:(BOOL)save {
    if (!rows.count || self.deleteProgress) return;
    if(self.exportProgress){[self appendExportRows:rows];return;}
    if(rows.count==1){[self beginExport:rows zip:NO save:save];return;}
    UIAlertController *choice = [UIAlertController alertControllerWithTitle:save ? @"Save downloads" : @"Share downloads" message:@"Choose how to package the selected tracks." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;__weak UIAlertController *weakChoice=choice;
    for (NSNumber *zip in @[@NO, @YES]) {
        NSString *title = zip.boolValue ? @"ZIP archive" : @"Folder";
        [choice addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            dispatch_block_t begin=^{[weakSelf beginExport:rows zip:zip.boolValue save:save];};
            if(weakChoice.presentingViewController)[weakChoice dismissViewControllerAnimated:YES completion:begin];else begin();
        }]];
    }
    [choice addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    choice.popoverPresentationController.barButtonItem = ((SAPOfflineLibraryController *)self.navigation.topViewController).exportButton;
    [self.navigation.topViewController presentViewController:choice animated:YES completion:nil];
}
- (void)appendExportRows:(NSArray<NSDictionary *> *)rows {
    if(self.dismissed || self.exportCancelled || !self.exportProgress || self.deleteProgress || self.pendingPackage)return;
    NSUInteger added=SAPAppendOfflineLibrarySelection(self.exportProgress,rows);
    if(!added)return;
    SAP_TRACE("offline_library","library_export_extended",0,(@{@"added_tracks":@(added)}));
    self.selecting=NO;[self.selectedURIs removeAllObjects];[self.selectedArtistKeys removeAllObjects];[self refreshSelection];[self refreshProgress];
}
- (void)beginExport:(NSArray<NSDictionary *> *)rows zip:(BOOL)zip save:(BOOL)save {
    if(self.exportProgress || self.deleteProgress)return;
    // A finished export waits for Done only so its package can still be shared or
    // saved. Starting the next selection is the same decision as pressing Done.
    if(self.pendingPackage)[self releasePendingPackage];
    self.exportCancelled=NO;self.selecting=NO;[self.selectedURIs removeAllObjects];[self.selectedArtistKeys removeAllObjects];
    self.pendingSave=save;self.progressModel=[[SAPOfflineLibraryProgress alloc]initWithTracks:rows];
    SAP_TRACE("offline_library","library_export_started",0,(@{@"tracks":@(rows.count),@"zip":@(zip),@"save_to_files":@(save),@"format":SAPAudioExportFormat()}));
    [self refreshSelection];[self refreshProgress];
    __weak typeof(self) weakSelf=self;
    self.exportProgress=SAPExportOfflineLibrarySelectionWithEvents(rows,zip,^(NSDictionary *event){
        SAPOfflineLibraryState *self=weakSelf;if(!self || self.dismissed)return;
        SAP_TRACE("offline_library","library_export_event",0,event);
        if(self.exportCancelled)return;
        [self.progressModel applyEvent:event];[self refreshProgress];
    },^(NSURL *package,NSArray<NSDictionary *> *failures,NSString *error){
        SAPOfflineLibraryState *self=weakSelf;if(!self){if(package)SAPReleaseOfflineLibraryPackage(package);return;}
        self.exportProgress=nil;
        if(self.exportCancelled || self.dismissed){if(package)SAPReleaseOfflineLibraryPackage(package);self.exportCancelled=NO;[self refreshProgress];return;}
        if(!package){[self refreshProgress];[self showMessage:@"Export failed" detail:error?:@"No files could be prepared."];return;}
        self.pendingPackage=package;self.pendingFailures=failures;[self refreshProgress];
        if(!self.navigation.topViewController.presentedViewController)[self reviewPackage];
    });
    [self refreshProgress];
}
- (void)reviewPackage {
    if(self.deleteProgress)return;
    NSURL *package=self.pendingPackage;if(!package || self.navigation.topViewController.presentedViewController)return;
    if(self.pendingFailures.count) {
        NSMutableArray *names=NSMutableArray.array;
        for(NSDictionary *failure in [self.pendingFailures subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)5,self.pendingFailures.count))])
            [names addObject:SAPOfflineString(failure[@"name"],SAPOfflineString(failure[@"uri"],@"Track"))];
        NSString *detail=[NSString stringWithFormat:@"%lu item(s) could not be exported: %@%@",(unsigned long)self.pendingFailures.count,[names componentsJoinedByString:@", "],self.pendingFailures.count>5?@", …":@""];
        UIAlertController *summary=[UIAlertController alertControllerWithTitle:@"Partial export" message:detail preferredStyle:UIAlertControllerStyleAlert];__weak UIAlertController *weakSummary=summary;
        [summary addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
            dispatch_block_t deliver=^{self.pendingFailures=nil;[self deliverPackage:package save:self.pendingSave];};
            if(weakSummary.presentingViewController)[weakSummary dismissViewControllerAnimated:YES completion:deliver];else deliver();
        }]];
        [summary addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a){[self releasePendingPackage];}]];
        [self.navigation.topViewController presentViewController:summary animated:YES completion:nil];
    }else[self deliverPackage:package save:self.pendingSave];
}
- (void)deliverPackage:(NSURL *)package save:(BOOL)save {
    SAP_TRACE("offline_library","library_delivery_presented",0,(@{@"save_to_files":@(save)}));
    if (save) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[package] asCopy:YES];
        picker.delegate = self;
        [self.navigation.topViewController presentViewController:picker animated:YES completion:nil];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[package] applicationActivities:nil];
    activity.completionWithItemsHandler = ^(__unused UIActivityType type, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self refreshProgress]; };
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    popover.sourceView=self.navigation.topViewController.view;
    CGRect bounds=popover.sourceView.bounds;popover.sourceRect=CGRectMake(CGRectGetMidX(bounds),CGRectGetMaxY(bounds)-popover.sourceView.safeAreaInsets.bottom-1,1,1);
    [self.navigation.topViewController presentViewController:activity animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { [self refreshProgress]; }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [self refreshProgress]; }
- (void)releasePendingPackage {
    if(self.pendingPackage)SAPReleaseOfflineLibraryPackage(self.pendingPackage);
    self.pendingPackage=nil;self.pendingFailures=nil;self.progressModel=nil;[self refreshProgress];
}
- (void)deleteRows:(NSArray<NSDictionary *> *)rows {
    if(!rows.count||self.deleteProgress||self.exportProgress||self.dismissed)return;
    // A scan started before deletion must not restore removed rows.
    self.catalogGeneration++;
    if(self.catalogCancel){self.catalogCancel();self.catalogCancel=nil;}
    NSArray *selection=[rows copy];__weak typeof(self) weakSelf=self;
    self.deleteProgress=SAPDeleteOfflineLibrarySelection(selection,^(__unused NSDictionary *event){
        SAPOfflineLibraryState *self=weakSelf;if(self&&!self.dismissed)[self refreshProgress];
    },^(NSArray<NSDictionary *> *results,NSString *error){
        SAPOfflineLibraryState *self=weakSelf;if(!self)return;self.deleteProgress=nil;if(self.dismissed)return;
        if([error isEqual:SAPOfflineLibraryDeleteBusyError]) {
            // Nothing was sent to Spotify and nothing changed: keep the list and selection for a retry.
            [self refreshProgress];
            [self showMessage:@"Still downloading" detail:@"This album is still downloading. Wait until the download finishes, then delete the tracks."];
            return;
        }
        NSUInteger offline=0,library=0;NSMutableArray *details=NSMutableArray.array;
        for(NSDictionary *result in results) {
            BOOL local=[result[@"offline_removed"]isEqual:@YES],saved=[result[@"library_removed"]isEqual:@YES];offline+=local;library+=saved;
            if((!local||!saved)&&details.count<5)[details addObject:[NSString stringWithFormat:@"%@: %@",SAPOfflineString(result[@"name"],@"Track"),SAPOfflineString(result[@"detail"],@"Removal was not confirmed.")]];
        }
        self.tracks=SAPOfflineLibraryRemainingTracks(self.tracks,selection,results);SAPUpdateOfflineLibraryCachedTracks(self.tracks);self.artists=[SAPOfflineLibraryController artistRowsForTracks:self.tracks];
        self.selecting=NO;[self.selectedURIs removeAllObjects];[self.selectedArtistKeys removeAllObjects];[self refresh];
        BOOL complete=offline==selection.count&&library==selection.count&&!error.length;
        if(complete){[self showDeleted:@"Deleted" detail:@"Clear Spotify's cache to fully remove what you just deleted." offerCacheClear:YES];return;}
        NSString *message=[NSString stringWithFormat:@"Offline removal confirmed: %lu / %lu\nLibrary removal confirmed: %lu / %lu",(unsigned long)offline,(unsigned long)selection.count,(unsigned long)library,(unsigned long)selection.count];
        if(details.count)message=[message stringByAppendingFormat:@"\n\n%@",[details componentsJoinedByString:@"\n"]];
        if(error.length)message=[message stringByAppendingFormat:@"\n\n%@",error];
        [self showDeleted:@"Removal incomplete" detail:message offerCacheClear:offline>0];
    });
    [self refreshProgress];
}
@end

@implementation SAPOfflineLibraryController
+ (NSArray<NSDictionary *> *)artistRowsForTracks:(NSArray<NSDictionary *> *)tracks {
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = NSMutableDictionary.dictionary;
    for (NSDictionary *row in tracks) { NSString *key = SAPOfflineArtistKey(row); if (!groups[key]) groups[key] = NSMutableArray.array; [groups[key] addObject:row]; }
    NSMutableArray *result = NSMutableArray.array;
    for (NSString *key in [[groups allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [SAPOfflineString(groups[a].firstObject[@"artist_name"], SAPOfflineUnknownArtist) localizedCaseInsensitiveCompare:SAPOfflineString(groups[b].firstObject[@"artist_name"], SAPOfflineUnknownArtist)]; }]) {
        NSDictionary *first = groups[key].firstObject;
        NSString *artistCover = @"";
        for (NSDictionary *row in groups[key]) { NSString *candidate = SAPOfflineString(row[@"artist_cover_url"], @""); if (candidate.length) { artistCover = candidate; break; } }
        [result addObject:@{@"key":key,@"name":SAPOfflineString(first[@"artist_name"], SAPOfflineUnknownArtist),@"artist_cover_url":artistCover,@"tracks":[groups[key] copy]}];
    }
    return result;
}
- (NSArray<NSDictionary *> *)buildReleaseSections {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableArray *> *> *categories = NSMutableDictionary.dictionary;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *releaseByKey = NSMutableDictionary.dictionary;
    for (NSDictionary *row in self.scope) {
        NSString *category = SAPOfflineString(row[@"category"], @"Albums"), *key = SAPOfflineReleaseKey(row);
        if (!categories[category]) categories[category] = NSMutableDictionary.dictionary;
        if (!categories[category][key]) {
            categories[category][key] = NSMutableArray.array;
            releaseByKey[key] = [@{@"key":key,@"name":SAPOfflineString(row[@"album_name"], SAPOfflineUnknownAlbum),@"cover_url":SAPOfflineString(row[@"cover_url"], @""),@"tracks":categories[category][key]} mutableCopy];
        }
        [categories[category][key] addObject:row];
    }
    for (NSDictionary *category in categories.allValues) {
        for (NSMutableArray *tracks in category.allValues) {
            [tracks sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                NSUInteger aDisc = [a[@"disc"] unsignedIntegerValue], bDisc = [b[@"disc"] unsignedIntegerValue];
                if (aDisc != bDisc) return aDisc < bDisc ? NSOrderedAscending : NSOrderedDescending;
                NSUInteger aNumber = [a[@"number"] unsignedIntegerValue], bNumber = [b[@"number"] unsignedIntegerValue];
                if (aNumber != bNumber) return aNumber < bNumber ? NSOrderedAscending : NSOrderedDescending;
                NSComparisonResult name = [SAPOfflineString(a[@"name"], @"") localizedStandardCompare:SAPOfflineString(b[@"name"], @"")];
                if (name != NSOrderedSame) return name;
                return [SAPOfflineString(a[@"uri"], @"") compare:SAPOfflineString(b[@"uri"], @"")];
            }];
        }
    }
    NSDictionary *categoryGroups = [categories copy];
    NSArray *preferred = @[@"Albums", @"EPs", @"Singles", @"Compilations"];
    NSMutableArray *categoryNames = NSMutableArray.array;
    for (NSString *category in preferred) if (categoryGroups[category]) [categoryNames addObject:category];
    NSMutableSet *other = [NSMutableSet setWithArray:categoryGroups.allKeys]; [other minusSet:[NSSet setWithArray:categoryNames]];
    [categoryNames addObjectsFromArray:[[other allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]];
    NSMutableArray *sections = NSMutableArray.array;
    for (NSString *category in categoryNames) {
        NSMutableArray *releases = NSMutableArray.array;
        for (NSString *key in [categoryGroups[category] keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            return [SAPOfflineString(a.firstObject[@"album_name"], SAPOfflineUnknownAlbum) localizedCaseInsensitiveCompare:SAPOfflineString(b.firstObject[@"album_name"], SAPOfflineUnknownAlbum)];
        }]) [releases addObject:releaseByKey[key]];
        [sections addObject:@{@"category":category,@"releases":[releases copy]}];
    }
    return sections;
}
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.tableView.backgroundColor=UIColor.blackColor;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;
    self.tableView.sectionHeaderHeight=UITableViewAutomaticDimension;self.tableView.estimatedSectionHeaderHeight=52;
    if(@available(iOS 16.0,*))self.tableView.selfSizingInvalidation=UITableViewSelfSizingInvalidationEnabled;
    self.loadingBackground=[UIView new];self.loadingBackground.backgroundColor=UIColor.blackColor;self.tableView.backgroundView=self.loadingBackground;
    self.bottomChrome=SAPOfflineLibraryChrome.new;__weak typeof(self) weakSelf=self;
    self.bottomChrome.changed=^{[weakSelf updateBottomControls];};
    self.baseBottomInset=self.appliedBottomInset=self.tableView.contentInset.bottom;
    self.exportToolbar=UIToolbar.new;self.exportToolbar.translatesAutoresizingMaskIntoConstraints=NO;
    self.exportToolbar.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    UIToolbarAppearance *appearance=UIToolbarAppearance.new;[appearance configureWithTransparentBackground];
    self.exportToolbar.standardAppearance=appearance;self.exportToolbar.compactAppearance=appearance;
    if(@available(iOS 15.0,*))self.exportToolbar.scrollEdgeAppearance=appearance;
    self.loadingLabel=[UILabel new];self.loadingLabel.numberOfLines=0;self.loadingLabel.textAlignment=NSTextAlignmentCenter;
    self.loadingLabel.textColor=UIColor.secondaryLabelColor;self.loadingLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.loadingLabel.adjustsFontForContentSizeCategory=YES;
    self.loadingSpinner=[[UIActivityIndicatorView alloc]initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.loadingSpinner.hidesWhenStopped=YES;
    UIStackView *loading=[[UIStackView alloc]initWithArrangedSubviews:@[self.loadingLabel,self.loadingSpinner]];
    loading.axis=UILayoutConstraintAxisVertical;loading.alignment=UIStackViewAlignmentCenter;loading.spacing=12;loading.translatesAutoresizingMaskIntoConstraints=NO;
    [self.loadingBackground addSubview:loading];
    [NSLayoutConstraint activateConstraints:@[[loading.centerXAnchor constraintEqualToAnchor:self.loadingBackground.centerXAnchor],[loading.centerYAnchor constraintEqualToAnchor:self.loadingBackground.centerYAnchor],[loading.widthAnchor constraintEqualToAnchor:self.loadingBackground.widthAnchor constant:-48],[self.loadingLabel.widthAnchor constraintEqualToAnchor:loading.widthAnchor]]];
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.selectButton=[[UIBarButtonItem alloc]initWithTitle:@"Select" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelection)];self.selectButton.tintColor=UIColor.whiteColor;
    self.exportButton=[[UIBarButtonItem alloc]initWithTitle:@"Export selected" style:UIBarButtonItemStylePlain target:self action:@selector(exportSelection)];self.exportButton.tintColor=UIColor.whiteColor;
    self.deleteButton=[[UIBarButtonItem alloc]initWithTitle:@"Delete selected" style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelection)];self.deleteButton.tintColor=UIColor.systemRedColor;
    if(self.level==0) {
        UIBarButtonItem *refresh=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshCatalog)];refresh.tintColor=UIColor.whiteColor;
        self.navigationItem.rightBarButtonItems=@[self.selectButton,refresh];
    }else self.navigationItem.rightBarButtonItem=self.selectButton;
    self.catalogDataSource=[[UITableViewDiffableDataSource alloc]initWithTableView:self.tableView cellProvider:^UITableViewCell *(UITableView *table,NSIndexPath *path,NSString *identifier){
        return [weakSelf catalogCellForTable:table identifier:identifier];
    }];
    [self applyCatalogSnapshot];[self updateToolbar];[self updateLoading];
}
- (void)applyCatalogSnapshot {
    if(!self.catalogDataSource)return;
    NSDiffableDataSourceSnapshot<NSString *,NSString *> *snapshot=NSDiffableDataSourceSnapshot.new;
    NSMutableDictionary *items=NSMutableDictionary.dictionary,*categories=NSMutableDictionary.dictionary;
    if(self.level==1) {
        for(NSDictionary *section in self.releaseSections) {
            NSString *category=section[@"category"];[snapshot appendSectionsWithIdentifiers:@[category]];
            for(NSDictionary *release in section[@"releases"]) {
                // A partial metadata row may temporarily put the same album in
                // different categories. Section-scoped identities remain unique.
                NSString *identity=[NSString stringWithFormat:@"%@|%@",category,release[@"key"]];
                items[identity]=release;categories[identity]=category;[snapshot appendItemsWithIdentifiers:@[identity] intoSectionWithIdentifier:category];
            }
        }
    }else {
        NSArray *rows=self.level==0?self.state.artists:self.scope;
        if(rows.count)[snapshot appendSectionsWithIdentifiers:@[@"library"]];
        for(NSDictionary *row in rows) {
            NSString *identity=row[self.level==0?@"key":@"uri"];items[identity]=row;
            [snapshot appendItemsWithIdentifiers:@[identity] intoSectionWithIdentifier:@"library"];
        }
    }
    NSDiffableDataSourceSnapshot *previous=self.catalogDataSource.snapshot;
    NSMutableArray *retained=NSMutableArray.array;
    for(NSString *identity in previous.itemIdentifiers)if(items[identity])[retained addObject:identity];
    if(@available(iOS 15.0,*))[snapshot reconfigureItemsWithIdentifiers:retained];
    else [snapshot reloadItemsWithIdentifiers:retained];
    // Preserve a surviving visible row's position when rows above it change.
    NSString *anchor=nil;CGFloat relativeY=0;CGPoint oldOffset=self.tableView.contentOffset;
    for(NSIndexPath *path in [self.tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *identity=[self.catalogDataSource itemIdentifierForIndexPath:path];
        if(identity && items[identity]){anchor=identity;relativeY=[self.tableView rectForRowAtIndexPath:path].origin.y-oldOffset.y;break;}
    }
    self.catalogItems=items;self.catalogCategories=categories;
    NSUInteger generation=++self.snapshotGeneration;
    __weak typeof(self) weakSelf=self;
    [self.catalogDataSource applySnapshot:snapshot animatingDifferences:NO completion:^{
        SAPOfflineLibraryController *self=weakSelf;if(!self || generation!=self.snapshotGeneration)return;
        [self.tableView layoutIfNeeded];
        if(!self.tableView.dragging && !self.tableView.decelerating) {
            NSIndexPath *path=anchor?[self.catalogDataSource indexPathForItemIdentifier:anchor]:nil;
            CGFloat y=path?[self.tableView rectForRowAtIndexPath:path].origin.y-relativeY:oldOffset.y;
            CGFloat minimum=-self.tableView.adjustedContentInset.top;
            CGFloat maximum=MAX(minimum,self.tableView.contentSize.height-self.tableView.bounds.size.height+self.tableView.adjustedContentInset.bottom);
            [self.tableView setContentOffset:CGPointMake(oldOffset.x,MIN(maximum,MAX(minimum,y))) animated:NO];
        }
        [self refreshSelection];
    }];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];[self.navigationController setToolbarHidden:YES animated:NO];[self refreshSelection];
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updateBottomControls];[self layoutProgressPanel:NO];}
- (void)viewSafeAreaInsetsDidChange {[super viewSafeAreaInsetsDidChange];[self updateBottomControls];}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {[self updateBottomControls];}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];[self.bottomChrome detach];self.exportToolbar.hidden=YES;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];[self updateBottomControls];[self updateProgressPanel];if(self.level==0 && !self.state.catalogCancel && !self.state.catalogGeneration)[self.state load];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];[self.bottomChrome detach];
    [NSLayoutConstraint deactivateConstraints:self.exportToolbarConstraints?:@[]];self.exportToolbarConstraints=nil;
    [self.exportToolbar removeFromSuperview];
    // A cancelled interactive back gesture must leave the current work intact.
    // Stack removal is handled by didMoveToParentViewController:nil below.
    if(self.navigationController.isBeingDismissed) {
        [self.state cancelWork];[self.navigationController setToolbarHidden:self.state.originalToolbarHidden animated:NO];
    }
}
- (void)dealloc {[_bottomChrome detach];[_exportToolbar removeFromSuperview];if(_level==0)[_state cancelWork];}
- (void)didMoveToParentViewController:(UIViewController *)parent {
    [super didMoveToParentViewController:parent];
    if(!parent && self.level==0) {
        [self.state cancelWork];
        [self.state.navigation setToolbarHidden:self.state.originalToolbarHidden animated:NO];
    }
}
- (void)updateLoading {
    if(!self.loadingLabel)return;
    BOOL empty=self.level==0 && !self.state.tracks.count;
    self.loadingLabel.hidden=!empty;
    if(empty) {
        BOOL loading=!self.state.tracks && self.state.catalogCancel!=nil;
        if(loading)self.loadingLabel.text=self.state.loadTotal?[NSString stringWithFormat:@"Loading downloaded tracks…\n%lu / %lu",(unsigned long)self.state.loadCompleted,(unsigned long)self.state.loadTotal]:@"Loading downloaded tracks…";
        else self.loadingLabel.text=self.state.tracks?@"No downloaded tracks":@"Tap Refresh to load downloaded tracks.";
        if(loading)[self.loadingSpinner startAnimating];else[self.loadingSpinner stopAnimating];
    }else[self.loadingSpinner stopAnimating];
}
- (void)toggleSelection {
    if(self.state.deleteProgress)return;
    self.state.selecting=!self.state.selecting;
    if(!self.state.selecting){[self.state.selectedURIs removeAllObjects];[self.state.selectedArtistKeys removeAllObjects];}
    else if(self.state.exportProgress && !self.state.exportCancelled)[self.state load];
    [self.state refreshSelection];
}
- (void)refreshCatalog {
    if(self.state.deleteProgress)return;
    [self.state load];
}
- (NSArray<NSDictionary *> *)selectedRows {
    return SAPOfflineLibrarySelection(self.scope?:self.state.tracks,self.state.selectedURIs,self.state.selecting);
}
- (NSArray<NSDictionary *> *)newExportRows {
    NSArray *rows=[self selectedRows];if(!self.state.exportProgress)return rows;
    NSMutableArray *newRows=NSMutableArray.array;
    for(NSDictionary *row in rows)if(![self.state.progressModel stateForTrackURI:row[@"uri"]])[newRows addObject:row];
    return newRows;
}
- (void)updateToolbar {
    self.selectButton.title=self.state.selecting?@"Cancel":@"Select";self.selectButton.enabled=!self.state.deleteProgress&&(self.scope?:self.state.tracks).count>0;
    NSUInteger count=[self newExportRows].count;BOOL appending=self.state.exportProgress!=nil;
    self.exportButton.title=[NSString stringWithFormat:@"%@ · %lu",appending?@"Add to export":@"Export selected",(unsigned long)count];
    self.exportButton.enabled=count>0 && !self.state.exportCancelled && !self.state.deleteProgress;
    self.deleteButton.title=self.state.deleteProgress?@"Deleting…":@"Delete selected";self.deleteButton.enabled=count>0&&!self.state.exportProgress&&!self.state.deleteProgress;
    if(self.exportToolbar.items.firstObject!=self.deleteButton)self.exportToolbar.items=@[self.deleteButton,[UIBarButtonItem flexibleSpaceItem],self.exportButton];
    [self updateBottomControls];[self updateProgressPanel];
}
- (void)updateBottomControls {
    if(self.updatingBottomControls || !self.isViewLoaded || !self.view.window || self.navigationController.topViewController!=self)return;
    self.updatingBottomControls=YES;
    UIView *host=self.navigationController.view;[self.bottomChrome attachToView:host];
    BOOL visible=self.state.selecting;
    if(visible && self.exportToolbar.superview!=host) {
        [NSLayoutConstraint deactivateConstraints:self.exportToolbarConstraints?:@[]];[self.exportToolbar removeFromSuperview];[host addSubview:self.exportToolbar];
        self.exportToolbarBottom=[self.exportToolbar.bottomAnchor constraintEqualToAnchor:host.bottomAnchor];
        self.exportToolbarConstraints=@[[self.exportToolbar.leadingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.leadingAnchor constant:16],[self.exportToolbar.trailingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-16],[self.exportToolbar.heightAnchor constraintEqualToConstant:44],self.exportToolbarBottom];
        [NSLayoutConstraint activateConstraints:self.exportToolbarConstraints];
    }
    self.exportToolbar.hidden=!visible;
    CGFloat clearance=[self.bottomChrome coverageInView:host]+12;
    if(visible && fabs(self.exportToolbarBottom.constant+clearance)>.5) {
        self.exportToolbarBottom.constant=-clearance;
        // Player layout events occur inside Vitrine's own animation transaction.
        // Laying out here joins that transaction, rather than starting a timer.
        [host layoutIfNeeded];
    }
    UIEdgeInsets inset=self.tableView.contentInset;
    if(fabs(inset.bottom-self.appliedBottomInset)>.5)self.baseBottomInset=inset.bottom;
    CGFloat automatic=self.tableView.adjustedContentInset.bottom-inset.bottom;
    CGFloat covered=[self.bottomChrome coverageInView:self.tableView]+12+(visible?44:0);
    self.appliedBottomInset=MAX(self.baseBottomInset,covered-automatic);
    if(fabs(inset.bottom-self.appliedBottomInset)>.5){inset.bottom=self.appliedBottomInset;self.tableView.contentInset=inset;}
    UIEdgeInsets indicators=self.tableView.verticalScrollIndicatorInsets;indicators.bottom=self.appliedBottomInset;
    if(!UIEdgeInsetsEqualToEdgeInsets(indicators,self.tableView.verticalScrollIndicatorInsets))self.tableView.verticalScrollIndicatorInsets=indicators;
    self.updatingBottomControls=NO;
}
- (void)progressActionTapped {
    if(self.state.deleteProgress)return;
    if(self.state.exportProgress){
        self.state.exportCancelled=YES;[self.state.exportProgress cancel];
        // Dismiss the session immediately; worker cancellation can finish later.
        [self.state releasePendingPackage];
    }
    else [self.state releasePendingPackage];
}
- (void)progressShareTapped {
    if(self.state.deleteProgress || self.state.exportProgress || !self.state.pendingPackage)return;
    self.state.pendingSave=NO;[self.state reviewPackage];
}
- (void)updateProgressPanel {
    if(self.updatingProgressPanel || !self.isViewLoaded || !self.view.window || self.navigationController.topViewController!=self)return;
    self.updatingProgressPanel=YES;
    NSDictionary *snapshot=[self.state.progressModel snapshotForTracks:self.level==0?nil:self.scope];BOOL visible=[snapshot[@"visible"]boolValue];
    if(!visible) {
        self.displayedProgressModel=nil;
        if(self.progressHeader && self.tableView.tableHeaderView==self.progressHeader)self.tableView.tableHeaderView=nil;
        self.updatingProgressPanel=NO;return;
    }
    if(!self.progressHeader) {
        self.progressHeader=UIView.new;self.progressHeader.autoresizingMask=UIViewAutoresizingFlexibleWidth;
        self.progressPanel=UIView.new;self.progressPanel.backgroundColor=[UIColor colorWithWhite:1 alpha:0.1008];self.progressPanel.translatesAutoresizingMaskIntoConstraints=NO;
        self.progressPanel.layer.cornerRadius=24;self.progressPanel.layer.cornerCurve=kCACornerCurveContinuous;
        self.progressTitle=UILabel.new;self.progressTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];self.progressTitle.textColor=UIColor.labelColor;self.progressTitle.adjustsFontForContentSizeCategory=YES;
        self.progressTitle.numberOfLines=1;self.progressTitle.lineBreakMode=NSLineBreakByTruncatingTail;
        self.progressDetail=UILabel.new;self.progressDetail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.progressDetail.textColor=UIColor.secondaryLabelColor;self.progressDetail.adjustsFontForContentSizeCategory=YES;
        self.progressDetail.numberOfLines=1;self.progressDetail.lineBreakMode=NSLineBreakByTruncatingMiddle;
        for(UILabel *label in @[self.progressTitle,self.progressDetail]) {
            label.translatesAutoresizingMaskIntoConstraints=NO;[label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        }
        self.progressBar=[[UIProgressView alloc]initWithProgressViewStyle:UIProgressViewStyleDefault];self.progressBar.progressTintColor=UIColor.systemGreenColor;self.progressBar.translatesAutoresizingMaskIntoConstraints=NO;
        self.progressAction=[UIButton buttonWithType:UIButtonTypeSystem];self.progressAction.translatesAutoresizingMaskIntoConstraints=NO;
        UIButtonConfiguration *button=[UIButtonConfiguration filledButtonConfiguration];button.buttonSize=UIButtonConfigurationSizeSmall;button.baseForegroundColor=UIColor.whiteColor;button.baseBackgroundColor=UIColor.systemGray4Color;button.cornerStyle=UIButtonConfigurationCornerStyleCapsule;
        button.contentInsets=NSDirectionalEdgeInsetsMake(5,10,5,10);
        button.titleLineBreakMode=NSLineBreakByTruncatingTail;
        button.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];return result;};
        self.progressAction.configuration=button;[self.progressAction addTarget:self action:@selector(progressActionTapped) forControlEvents:UIControlEventTouchUpInside];
        self.progressAction.titleLabel.numberOfLines=1;self.progressAction.titleLabel.adjustsFontSizeToFitWidth=YES;self.progressAction.titleLabel.minimumScaleFactor=0.6;
        self.progressShareAction=[UIButton buttonWithType:UIButtonTypeSystem];self.progressShareAction.translatesAutoresizingMaskIntoConstraints=NO;self.progressShareAction.configuration=[button copy];
        self.progressShareAction.titleLabel.numberOfLines=1;self.progressShareAction.titleLabel.adjustsFontSizeToFitWidth=YES;self.progressShareAction.titleLabel.minimumScaleFactor=0.6;
        [self.progressShareAction setTitle:@"Share" forState:UIControlStateNormal];[self.progressShareAction addTarget:self action:@selector(progressShareTapped) forControlEvents:UIControlEventTouchUpInside];
        self.progressActionHeight=[self.progressAction.heightAnchor constraintEqualToConstant:30];
        self.progressTitleTrailing=[self.progressTitle.trailingAnchor constraintEqualToAnchor:self.progressAction.leadingAnchor constant:-12];
        [self.progressHeader addSubview:self.progressPanel];
        for(UIView *child in @[self.progressTitle,self.progressDetail,self.progressBar,self.progressAction,self.progressShareAction])[self.progressPanel addSubview:child];
        [NSLayoutConstraint activateConstraints:@[
            [self.progressPanel.leadingAnchor constraintEqualToAnchor:self.progressHeader.layoutMarginsGuide.leadingAnchor],
            [self.progressPanel.trailingAnchor constraintEqualToAnchor:self.progressHeader.layoutMarginsGuide.trailingAnchor],
            [self.progressPanel.topAnchor constraintEqualToAnchor:self.progressHeader.topAnchor constant:8],
            [self.progressPanel.bottomAnchor constraintEqualToAnchor:self.progressHeader.bottomAnchor constant:-8],
            [self.progressAction.topAnchor constraintEqualToAnchor:self.progressPanel.topAnchor constant:10],
            [self.progressAction.trailingAnchor constraintEqualToAnchor:self.progressPanel.trailingAnchor constant:-14],
            [self.progressAction.widthAnchor constraintEqualToConstant:76],
            self.progressActionHeight,
            [self.progressShareAction.trailingAnchor constraintEqualToAnchor:self.progressAction.leadingAnchor constant:-8],
            [self.progressShareAction.topAnchor constraintEqualToAnchor:self.progressAction.topAnchor],
            [self.progressShareAction.widthAnchor constraintEqualToAnchor:self.progressAction.widthAnchor],
            [self.progressShareAction.heightAnchor constraintEqualToAnchor:self.progressAction.heightAnchor],
            [self.progressTitle.leadingAnchor constraintEqualToAnchor:self.progressPanel.leadingAnchor constant:16],
            self.progressTitleTrailing,
            [self.progressTitle.centerYAnchor constraintEqualToAnchor:self.progressAction.centerYAnchor],
            [self.progressDetail.leadingAnchor constraintEqualToAnchor:self.progressPanel.leadingAnchor constant:16],
            [self.progressDetail.trailingAnchor constraintEqualToAnchor:self.progressPanel.trailingAnchor constant:-16],
            [self.progressDetail.topAnchor constraintEqualToAnchor:self.progressAction.bottomAnchor constant:8],
            [self.progressBar.leadingAnchor constraintEqualToAnchor:self.progressPanel.leadingAnchor constant:16],
            [self.progressBar.trailingAnchor constraintEqualToAnchor:self.progressPanel.trailingAnchor constant:-16],
            [self.progressBar.topAnchor constraintEqualToAnchor:self.progressDetail.bottomAnchor constant:10],
            [self.progressBar.heightAnchor constraintEqualToConstant:4],
            [self.progressBar.bottomAnchor constraintEqualToAnchor:self.progressPanel.bottomAnchor constant:-14]]];
    }
    NSString *phase=snapshot[@"phase"];NSUInteger done=[snapshot[@"completed"]unsignedIntegerValue],total=[snapshot[@"total"]unsignedIntegerValue],failed=[snapshot[@"failed"]unsignedIntegerValue];
    NSString *title;
    if([phase isEqual:@"packaging"])title=[NSString stringWithFormat:@"Packaging selection · %.0f%%",[snapshot[@"fraction"]doubleValue]*100];
    else if([phase isEqual:@"ready"])title=@"Files ready";
    else if([phase isEqual:@"cancelled"])title=@"Export cancelled";
    else if([phase isEqual:@"failed"])title=@"Export failed";
    else title=[NSString stringWithFormat:@"Preparing files · %lu / %lu",(unsigned long)done,(unsigned long)total];
    NSString *detail=snapshot[@"message"];
    if(![phase isEqual:@"preparing"])detail=[NSString stringWithFormat:@"%lu / %lu files processed · %@",(unsigned long)done,(unsigned long)total,detail];
    self.progressTitle.text=title;self.progressDetail.text=failed?[NSString stringWithFormat:@"%lu failed · %@",(unsigned long)failed,detail]:detail;
    float fraction=[snapshot[@"fraction"]floatValue];
    BOOL animate=self.displayedProgressModel==self.state.progressModel && self.progressBar.window!=nil &&
        fraction>self.progressBar.progress && !UIAccessibilityIsReduceMotionEnabled();
    // Equal targets arrive with status-only updates: leave the running UIKit
    // animation alone. A new operation always establishes its own initial value.
    if(self.displayedProgressModel!=self.state.progressModel || fraction!=self.progressBar.progress || UIAccessibilityIsReduceMotionEnabled())
        [self.progressBar setProgress:fraction animated:animate];
    self.displayedProgressModel=self.state.progressModel;
    BOOL shareReady=!self.state.exportProgress&&self.state.pendingPackage!=nil;
    self.progressShareAction.hidden=!shareReady;
    CGFloat titleTrailing=shareReady?-96:-12;if(fabs(self.progressTitleTrailing.constant-titleTrailing)>.5)self.progressTitleTrailing.constant=titleTrailing;
    [self.progressAction setTitle:self.state.exportProgress?@"Cancel":@"Done" forState:UIControlStateNormal];
    self.progressAction.enabled=!self.state.deleteProgress;self.progressShareAction.enabled=!self.state.deleteProgress;
    [self layoutProgressPanel:YES];
    self.updatingProgressPanel=NO;
}
- (void)layoutProgressPanel:(BOOL)insert {
    if(!self.progressHeader || (!insert && self.tableView.tableHeaderView!=self.progressHeader))return;
    CGFloat width=self.tableView.bounds.size.width;UIEdgeInsets margins=self.tableView.layoutMargins;
    UIEdgeInsets headerMargins=UIEdgeInsetsMake(0,MAX(16,margins.left),0,MAX(16,margins.right));
    if(!UIEdgeInsetsEqualToEdgeInsets(headerMargins,self.progressHeader.layoutMargins))self.progressHeader.layoutMargins=headerMargins;
    // Fixed one-line rows: progress messages never participate in header sizing.
    CGFloat actionHeight=ceil(MAX(30,MAX(self.progressTitle.font.lineHeight,[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1].lineHeight+10)));
    if(fabs(self.progressActionHeight.constant-actionHeight)>.5)self.progressActionHeight.constant=actionHeight;
    CGFloat height=16+10+actionHeight+8+ceil(self.progressDetail.font.lineHeight)+10+4+14;
    CGSize size=CGSizeMake(width,height);BOOL resized=!CGSizeEqualToSize(self.progressHeader.bounds.size,size);
    if(resized)self.progressHeader.frame=(CGRect){CGPointZero,size};
    if(self.tableView.tableHeaderView!=self.progressHeader || resized)self.tableView.tableHeaderView=self.progressHeader;
}
- (void)refreshSelection {
    for(NSIndexPath *path in self.tableView.indexPathsForVisibleRows)[self configureCell:(id)[self.tableView cellForRowAtIndexPath:path] atIndexPath:path];
    for(NSInteger section=0;section<[self numberOfSectionsInTableView:self.tableView];section++) {
        SAPArtistCategoryHeader *header=(id)[self.tableView headerViewForSection:section];if(header)[self configureHeader:header section:section];
    }
    [self updateToolbar];
}
- (void)exportSelection {
    NSArray *rows=[self newExportRows];if(!rows.count)return;
    if(self.state.exportProgress){[self.state appendExportRows:rows];return;}
    UIAlertController *choice=[UIAlertController alertControllerWithTitle:@"Export selected" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakChoice=choice;
    for(NSNumber *save in @[@NO,@YES]) {
        [choice addAction:[UIAlertAction actionWithTitle:save.boolValue?@"Save to Files":@"Share" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
            [weakSelf afterDialog:weakChoice perform:^{[weakSelf.state exportRows:rows save:save.boolValue];}];
        }]];
    }
    [choice addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    choice.popoverPresentationController.barButtonItem=self.exportButton;[self presentViewController:choice animated:YES completion:nil];
}
- (void)deleteSelection {
    NSArray *rows=[self selectedRows];if(!rows.count||self.state.exportProgress||self.state.deleteProgress)return;
    NSString *title=[NSString stringWithFormat:@"Delete %lu selected tracks?",(unsigned long)rows.count];
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:title message:@"Remove these tracks from Spotify's offline storage on this device and from your library? Albums and playlists containing unselected tracks will be kept. Files saved outside Spotify are not deleted." preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakConfirm=confirm;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){[weakSelf afterDialog:weakConfirm perform:^{[weakSelf.state deleteRows:rows];}];}]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}
- (void)afterDialog:(UIAlertController *)dialog perform:(dispatch_block_t)action {
    if(dialog.presentingViewController)[dialog dismissViewControllerAnimated:YES completion:action];else if(action)action();
}
- (NSArray<NSDictionary *> *)artists {
    return self.state.artists ?: @[];
}
- (NSArray<NSDictionary *> *)releases {
    return self.releaseSections ?: @[];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if(self.level==0)return self.state.artists.count?1:0;
    return self.level==1?self.releaseSections.count:(self.scope.count?1:0);
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if(self.level==0)return self.state.artists.count;
    if(self.level==1)return [self.releaseSections[section][@"releases"]count];return self.scope.count;
}
- (NSArray<NSDictionary *> *)rowsInSection:(NSInteger)section {
    if(self.level!=1)return self.scope?:self.state.tracks;
    NSMutableArray *rows=NSMutableArray.array;for(NSDictionary *release in self.releaseSections[section][@"releases"])[rows addObjectsFromArray:release[@"tracks"]];return rows;
}
- (void)configureHeader:(SAPArtistCategoryHeader *)header section:(NSInteger)section {
    NSString *title=self.level==0?@"Artists":self.level==1?self.releaseSections[section][@"category"]:@"Tracks";
    header.categoryTitle.text=[NSString stringWithFormat:@"%@ (%ld)",title,(long)[self tableView:self.tableView numberOfRowsInSection:section]];
    header.catalogProgressLabel.hidden=YES;header.selectionButton.hidden=!self.state.selecting;header.selectionButton.tag=section;
    NSArray *rows=[self rowsInSection:section];header.selectionButton.selected=rows.count>0 && SAPOfflineLibrarySelection(rows,self.state.selectedURIs,YES).count==rows.count;
    [header.selectionButton removeTarget:self action:@selector(toggleSection:) forControlEvents:UIControlEventTouchUpInside];
    [header.selectionButton addTarget:self action:@selector(toggleSection:) forControlEvents:UIControlEventTouchUpInside];
    header.selectionButton.accessibilityLabel=[@"Select " stringByAppendingString:title];
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    SAPArtistCategoryHeader *header=(id)[tableView dequeueReusableHeaderFooterViewWithIdentifier:@"OfflineCategory"];
    if(!header)header=[[SAPArtistCategoryHeader alloc]initWithReuseIdentifier:@"OfflineCategory"];
    [self configureHeader:header section:section];return header;
}
- (void)toggleSection:(UIButton *)button {
    if(self.state.deleteProgress||!self.state.selecting)return;NSArray *rows=[self rowsInSection:button.tag];BOOL all=rows.count>0 && SAPOfflineLibrarySelection(rows,self.state.selectedURIs,YES).count==rows.count;
    if(self.level==0)for(NSDictionary *artist in self.state.artists) {
        if(all)[self.state.selectedArtistKeys removeObject:artist[@"key"]];else[self.state.selectedArtistKeys addObject:artist[@"key"]];
    }else for(NSDictionary *row in rows)[self.state.selectedArtistKeys removeObject:SAPOfflineArtistKey(row)];
    for(NSDictionary *row in rows)if(all)[self.state.selectedURIs removeObject:row[@"uri"]];else[self.state.selectedURIs addObject:row[@"uri"]];
    [self.state refreshSelection];
}
- (void)configureCell:(SAPArtistReleaseCell *)base atIndexPath:(NSIndexPath *)path {
    NSString *identifier=[self.catalogDataSource itemIdentifierForIndexPath:path];
    if(identifier)[self configureCell:base identifier:identifier];
}
- (void)configureCell:(SAPArtistReleaseCell *)base identifier:(NSString *)identifier {
    SAPOfflineArtworkCell *cell=(id)base;if(![cell isKindOfClass:SAPOfflineArtworkCell.class])return;
    NSDictionary *item=self.catalogItems[identifier];if(!item)return;
    NSArray *rows;BOOL artist=self.level==0;NSString *title,*subtitle,*url,*identity;
    if(artist){rows=item[@"tracks"];title=item[@"name"];subtitle=[NSString stringWithFormat:@"%lu tracks",(unsigned long)rows.count];url=item[@"artist_cover_url"];identity=item[@"key"];}
    else if(self.level==1){rows=item[@"tracks"];title=item[@"name"];NSDictionary *first=rows.firstObject;NSString *year=[first[@"year"]integerValue]?[first[@"year"]stringValue]:nil;
        subtitle=[NSString stringWithFormat:@"%@%@%@ · %lu tracks",year?:@"",year?@" · ":@"",self.catalogCategories[identifier],(unsigned long)rows.count];url=item[@"cover_url"];identity=item[@"key"];}
    else {rows=@[item];title=SAPOfflineString(item[@"name"],@"Unknown track");subtitle=SAPOfflineString(item[@"artist_name"],SAPOfflineUnknownArtist);url=item[@"cover_url"];identity=item[@"uri"];}
    UIListContentConfiguration *old=(id)cell.contentConfiguration;
    BOOL same=[cell.imageIdentity isEqual:identity] && [cell.artworkURL?:@"" isEqual:url?:@""];
    UIListContentConfiguration *content=same && [old isKindOfClass:UIListContentConfiguration.class]?[old copy]:[UIListContentConfiguration subtitleCellConfiguration];
    if(!same) {
        [cell cancelArtworkLoad];cell.imageIdentity=identity;cell.artworkURL=url?:@"";
        NSDirectionalEdgeInsets margins=content.directionalLayoutMargins;margins.trailing+=52;content.directionalLayoutMargins=margins;
        content.image=artist?[UIImage systemImageNamed:@"person.crop.circle.fill"]:SAPArtistArtworkPlaceholder();
        content.imageProperties.maximumSize=CGSizeMake(52,52);content.imageProperties.reservedLayoutSize=CGSizeMake(52,52);content.imageProperties.cornerRadius=artist?26:8;
        content.textProperties.numberOfLines=0;content.secondaryTextProperties.numberOfLines=0;
    }
    content.text=title;content.secondaryText=subtitle;cell.contentConfiguration=content;SAPApplyArtistListRowBackground(cell);
    [self configureIndicator:cell rows:rows];
    if(!same && url.length) {
        __weak SAPOfflineArtworkCell *weakCell=cell;
        cell.cancelArtwork=[[SAPArtistArtworkLoader shared]loadURL:url completion:^(UIImage *image){
            SAPOfflineArtworkCell *cell=weakCell;if(!cell || ![cell.imageIdentity isEqual:identity] || ![cell.artworkURL isEqual:url])return;
            cell.cancelArtwork=nil;if(!image)return;UIListContentConfiguration *updated=(id)cell.contentConfiguration;updated.image=image;
            [UIView performWithoutAnimation:^{cell.contentConfiguration=updated;[cell installIndicatorLayout];}];
        }];
    }
}
- (void)configureIndicator:(SAPOfflineArtworkCell *)cell rows:(NSArray<NSDictionary *> *)rows {
    if(![cell isKindOfClass:SAPOfflineArtworkCell.class])return;
    BOOL selected=rows.count>0 && SAPOfflineLibrarySelection(rows,self.state.selectedURIs,YES).count==rows.count;
    NSString *symbol=nil,*label=nil;UIColor *color=UIColor.secondaryLabelColor;
    if(self.state.selecting){symbol=selected?@"checkmark.circle.fill":@"circle";label=selected?@"Selected":@"Not selected";if(selected)color=UIColor.systemGreenColor;}
    else if(self.level<2){symbol=@"chevron.right";label=@"Open";}
    else {
        NSString *status=[self.state.progressModel stateForTrackURI:rows.firstObject[@"uri"]];
        if([status isEqual:@"queued"]){symbol=@"clock";label=@"Queued for export";}
        else if([status isEqual:@"preparing"]){symbol=@"arrow.up.circle";label=@"Preparing export";color=UIColor.systemGreenColor;}
        else if([status isEqual:@"converting"]){symbol=@"arrow.triangle.2.circlepath";label=@"Converting to M4A";color=UIColor.systemGreenColor;}
        else if([status isEqual:@"prepared"]){symbol=@"checkmark.circle";label=@"Prepared";color=UIColor.systemGreenColor;}
        else if([status isEqual:@"failed"]){symbol=@"exclamationmark.circle";label=@"Export failed";color=UIColor.systemRedColor;}
        else if([status isEqual:@"cancelled"]){symbol=@"stop.circle";label=@"Export cancelled";color=UIColor.systemOrangeColor;}
        else if([status isEqual:@"not_exported"]){symbol=@"minus.circle";label=@"Not exported";}
    }
    BOOL created=!cell.staticIndicator;
    if(created)cell.staticIndicator=SAPArtistStateIcon(@"circle",UIColor.secondaryLabelColor,@"Not selected");
    if(created||![(label?:@"")isEqual:cell.staticIndicator.accessibilityLabel?:@""]) {
        cell.staticIndicator.image=symbol?[UIImage systemImageNamed:symbol]:nil;cell.staticIndicator.tintColor=color;cell.staticIndicator.accessibilityLabel=label;
        cell.staticIndicator.hidden=symbol==nil;[cell setDownloadIndicator:cell.staticIndicator];cell.accessoryType=UITableViewCellAccessoryNone;
        cell.accessibilityTraits=UIAccessibilityTraitButton|(self.state.selecting&&selected?UIAccessibilityTraitSelected:0);
    }
}
- (UITableViewCell *)catalogCellForTable:(UITableView *)tableView identifier:(NSString *)identifier {
    SAPOfflineArtworkCell *cell=(id)[tableView dequeueReusableCellWithIdentifier:@"OfflineRelease"];
    if(!cell)cell=[[SAPOfflineArtworkCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"OfflineRelease"];
    [self configureCell:cell identifier:identifier];return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(self.state.deleteProgress)return;
    if (self.level == 0 && !self.state.tracks) return;
    if (self.level == 0 && [self artists].count == 0) return;
    if (self.state.selecting) {
        NSArray *rows = nil;
        if (self.level == 0) rows = [self artists][indexPath.row][@"tracks"];
        else if (self.level == 1) rows = self.releaseSections[indexPath.section][@"releases"][indexPath.row][@"tracks"];
        else if (self.level == 2) rows = @[self.scope[indexPath.row]];
        BOOL all = YES; for (NSDictionary *row in rows) if (![self.state.selectedURIs containsObject:row[@"uri"]]) { all = NO; break; }
        if(self.level==0) {
            NSString *key=[self artists][indexPath.row][@"key"];
            if(all)[self.state.selectedArtistKeys removeObject:key];else[self.state.selectedArtistKeys addObject:key];
        }else for(NSDictionary *row in rows)[self.state.selectedArtistKeys removeObject:SAPOfflineArtistKey(row)];
        for (NSDictionary *row in rows) { NSString *uri = row[@"uri"]; if (all) [self.state.selectedURIs removeObject:uri]; else if (uri) [self.state.selectedURIs addObject:uri]; }
        [self.state refreshSelection];return;
    }
    SAPOfflineLibraryController *next = SAPOfflineLibraryController.new; next.state = self.state;next.artistKey=self.artistKey;
    if (self.level == 0) { NSDictionary *artist = [self artists][indexPath.row]; next.level = 1; next.pageTitle = artist[@"name"]; next.artistKey = artist[@"key"]; next.scope = artist[@"tracks"]; next.releaseSections = [next buildReleaseSections]; }
    else if (self.level == 1) { NSDictionary *release = self.releaseSections[indexPath.section][@"releases"][indexPath.row]; next.level = 2; next.pageTitle = release[@"name"]; next.releaseKey = release[@"key"]; next.scope = release[@"tracks"]; }
    else return;
    next.title = next.pageTitle; [self.navigationController pushViewController:next animated:YES];
}
@end

void SAPShowOfflineLibrary(UIViewController *presenter) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPShowOfflineLibrary(presenter);});return;}
    UINavigationController *navigation=presenter.navigationController;
    if(!navigation || presenter.presentedViewController)return;
    SAPOfflineLibraryState *state=SAPOfflineLibraryState.new;state.navigation=navigation;state.originalToolbarHidden=navigation.toolbarHidden;
    SAPOfflineLibraryController *root=SAPOfflineLibraryController.new;root.state=state;root.level=0;root.title=@"Downloaded tracks";state.root=root;
    [navigation pushViewController:root animated:YES];
}
