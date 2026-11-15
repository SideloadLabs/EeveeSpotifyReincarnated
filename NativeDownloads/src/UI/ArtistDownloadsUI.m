#import "ArtistListAppearance.h"
#import "ArtistDownloadsUI.h"
#import "ArtistCatalogAppend.h"
#import "ArtistMetadata.h"
#import "ArtistDownloadSession.h"
#import "PlaylistDownloads.h"
#import "ArtistArtworkLoader.h"
#import "ArtistDownloadComponents.h"
#import "PlaylistPickerController.h"
#import "TrackJournal.h"
#import "Diagnostics.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

static BOOL SAPArtistDownloadsIsDismissing(UIViewController *controller) {
    for(UIViewController *ancestor=controller;ancestor;ancestor=ancestor.parentViewController)
        if(ancestor.isBeingDismissed)return YES;
    return NO;
}

static void SAPAfterDialogDismissal(UIAlertController *dialog,dispatch_block_t completion) {
    if(dialog.isBeingDismissed && dialog.transitionCoordinator){[dialog.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context){completion();}];return;}
    if(dialog.presentingViewController && !dialog.isBeingDismissed){[dialog dismissViewControllerAnimated:YES completion:completion];return;}
    dispatch_async(dispatch_get_main_queue(),completion);
}

@interface SAPArtistDownloadsController : UITableViewController
@property(nonatomic,copy) NSString *artistURI,*artistName,*loadError,*loadProgress;
@property(nonatomic,strong) NSDictionary *catalog,*sessionSnapshot,*playlistSnapshot,*playlistItemSnapshot;
@property(nonatomic) BOOL loading,selecting,pendingStateRefresh;
#ifdef SAP_TESTING
@property(nonatomic) NSUInteger stateRefreshCount;
#endif
@property(nonatomic,strong) NSMutableSet *selectedReleaseURIs;
@property(nonatomic,weak) UIAlertAction *nameConfirmation;
@property(nonatomic,copy) NSArray *catalogReleases;
@property(nonatomic,strong) UIBarButtonItem *downloadControl,*stopControl,*continueControl,*cancelControl,*retryControl,*toolbarSpace,*selectControl;
@property(nonatomic,strong) UILabel *loadingLabel,*footerLabel;
@property(nonatomic,strong) UIView *footerContainer,*loadingContainer;
@property(nonatomic,strong) UIActivityIndicatorView *loadingSpinner;
@property(nonatomic) BOOL itemsVisible;
@property(nonatomic) NSUInteger itemObservationGeneration;
@property(nonatomic,copy) NSString *footerText;
@property(nonatomic) CGFloat footerWidth;
@property(nonatomic,strong) NSHashTable<SAPArtistReleaseCell *> *artworkCells;
@property(nonatomic) NSUInteger loadGeneration,sessionObservationGeneration,loadCompleted,loadTotal;
@property(nonatomic,strong) NSDictionary *pendingCatalog;
@property(nonatomic,copy) dispatch_block_t cancelCatalog,detachPlaylistObserver;
@property(nonatomic,strong) SAPArtistSessionObservation *sessionObservation;
@property(nonatomic,strong) SAPReleaseItemObservation *itemObservation;
@property(nonatomic,strong) id foregroundObserver;
@end
@implementation SAPArtistDownloadsController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.artistName.length?self.artistName:@"Artist downloads";
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.tableView.backgroundColor=UIColor.clearColor;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;
    if(@available(iOS 16.0,*))self.tableView.selfSizingInvalidation=UITableViewSelfSizingInvalidationEnabled;
    self.tableView.sectionHeaderHeight=UITableViewAutomaticDimension;self.tableView.estimatedSectionHeaderHeight=52;
    self.selectedReleaseURIs=[NSMutableSet set];self.artworkCells=[NSHashTable weakObjectsHashTable];
    self.downloadControl=[[UIBarButtonItem alloc]initWithTitle:@"Download selected" style:UIBarButtonItemStylePlain target:self action:@selector(downloadSelected)];
    __weak typeof(self) weakStopPage=self;
    self.stopControl=[[UIBarButtonItem alloc]initWithPrimaryAction:[UIAction actionWithTitle:@"Stop" image:nil identifier:@"pixie.artist.downloads.stop" handler:^(UIAction *action){
        typeof(self) page=weakStopPage;if(!page)return;
        BOOL senderMatches=action.sender==page.stopControl;
        BOOL visible=page.itemsVisible && page.viewIfLoaded.window!=nil && !page.navigationController.toolbarHidden && [page.toolbarItems containsObject:page.stopControl];
        BOOL top=page.navigationController.topViewController==page;
        BOOL modal=page.presentedViewController!=nil || page.navigationController.presentedViewController!=nil || SAPArtistDownloadsIsDismissing(page);
        BOOL accepted=senderMatches && visible && top && !modal && page.stopControl.enabled;
        NSArray *scope=page.catalog[@"observation_releases"]?:page.allReleases;
        if(SAPDiagnosticsEnabled())SAP_JOURNAL_ACTION(accepted?@"artist_stop_all":@"artist_stop_all_ignored",@{@"artist_uri":page.artistURI?:@"",@"caller":@"Stop UIBarButtonItem primaryAction handler",@"action_origin":@"bar_button_primary_action",@"requested_reason":@"stop_artist_downloads",@"sender_matches":@(senderMatches),@"visible":@(visible),@"top_controller":@(top),@"presented_modal":@(modal),@"control_enabled":@(page.stopControl.enabled),@"selecting":@(page.selecting),@"release_count":@(scope.count),@"call_stack":NSThread.callStackSymbols});
        if(!accepted)return;
        SAPStopPlaylistReleaseDownloadsForArtist(page.artistURI,nil);SAPStopArtistDownloadSessionReleasesForArtist(page.artistURI,scope);
    }]];
    self.cancelControl=[[UIBarButtonItem alloc]initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(confirmCancelDownloads)];self.cancelControl.accessibilityLabel=@"Cancel downloads";
    self.continueControl=[[UIBarButtonItem alloc]initWithTitle:@"Continue" style:UIBarButtonItemStylePlain target:self action:@selector(continueDownloads)];
    self.selectControl=[[UIBarButtonItem alloc]initWithTitle:@"Select" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelection)];
    self.retryControl=[[UIBarButtonItem alloc]initWithTitle:@"Retry" style:UIBarButtonItemStylePlain target:self action:@selector(loadCatalog)];self.toolbarSpace=[UIBarButtonItem flexibleSpaceItem];
    self.loadingLabel=[UILabel new];self.loadingLabel.numberOfLines=0;self.loadingLabel.textAlignment=NSTextAlignmentCenter;self.loadingLabel.textColor=UIColor.secondaryLabelColor;
    self.loadingLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.loadingLabel.adjustsFontForContentSizeCategory=YES;
    self.loadingContainer=[UIView new];self.loadingSpinner=[[UIActivityIndicatorView alloc]initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.loadingSpinner.color=UIColor.whiteColor;self.loadingSpinner.hidesWhenStopped=YES;
    UIStackView *loadingStack=[[UIStackView alloc]initWithArrangedSubviews:@[self.loadingLabel,self.loadingSpinner]];loadingStack.axis=UILayoutConstraintAxisVertical;loadingStack.alignment=UIStackViewAlignmentCenter;loadingStack.spacing=12;loadingStack.translatesAutoresizingMaskIntoConstraints=NO;[self.loadingContainer addSubview:loadingStack];
    [NSLayoutConstraint activateConstraints:@[[loadingStack.centerXAnchor constraintEqualToAnchor:self.loadingContainer.centerXAnchor],[loadingStack.centerYAnchor constraintEqualToAnchor:self.loadingContainer.centerYAnchor],[loadingStack.widthAnchor constraintEqualToAnchor:self.loadingContainer.widthAnchor constant:-48],[self.loadingLabel.widthAnchor constraintEqualToAnchor:loadingStack.widthAnchor]]];
    self.footerLabel=[UILabel new];self.footerLabel.numberOfLines=0;self.footerLabel.textColor=UIColor.secondaryLabelColor;self.footerLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.footerContainer=[UIView new];[self.footerContainer addSubview:self.footerLabel];
    [self.navigationController setToolbarHidden:NO animated:NO];
    UIBarButtonItem *back=[[UIBarButtonItem alloc]initWithImage:[UIImage systemImageNamed:@"xmark"] style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    back.tintColor=UIColor.whiteColor;back.accessibilityLabel=@"Back";self.navigationItem.leftBarButtonItem=back;
    __weak typeof(self) weak=self;
    self.foregroundObserver=[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){typeof(self) page=weak;if(page.itemsVisible && page.viewIfLoaded.window){[page detachItems];[page attachItems];if(page.sessionObservation)[page.sessionObservation refresh];else[page bindSession];}}];
    [self loadCatalog];
}
- (NSArray *)sections {return self.catalog[@"sections"]?:@[];}
- (NSArray *)allReleases {return self.catalogReleases?:@[];}
- (NSDictionary *)stateFor:(NSString *)uri {
    NSDictionary *native=self.sessionSnapshot[@"album_states"][uri]?:@{@"state":@"unknown"};
    NSDictionary *items=self.playlistItemSnapshot[@"album_states"][uri];
    BOOL registered=[native[@"state"]isEqual:@"downloaded"];
    if(registered){NSMutableDictionary *live=[(items?:native)mutableCopy];live[@"state"]=@"downloaded";live[@"phase"]=@"downloaded";live[@"progress"]=@1;live[@"active"]=@NO;return live;}
    if([native[@"active"]boolValue]){
        if(!items)return native;NSMutableDictionary *live=[native mutableCopy];
        for(NSString *key in @[@"progress",@"downloaded_tracks",@"total_tracks",@"known_tracks",@"playlist_download",@"playlist_uri",@"playlist_name"])if(items[key])live[key]=items[key];return live;
    }
    for(NSDictionary *job in [self.playlistSnapshot[@"jobs"]reverseObjectEnumerator])if([job[@"active"]boolValue] && ([job[@"queued"]boolValue] || ![job[@"submitted"]boolValue]) && [job[@"release_uris"]containsObject:uri])return @{@"state":@"partial",@"phase":[job[@"queued"]boolValue]?@"queued":@"preparing",@"active":@YES,@"progress":@0,@"playlist_name":job[@"playlist_name"]?:@"Playlist",@"playlist_download":@YES,@"download_source":@"playlist"};
    NSMutableDictionary *live=[(items?:native)mutableCopy];
    if([items[@"state"]isEqual:@"downloaded"]){
        // File availability is not the album's native offline registration.
        BOOL known=[native[@"state"]length] && ![native[@"state"]isEqual:@"unknown"];
        live[@"state"]=[items[@"active"]boolValue]?@"partial":known?@"not_downloaded":@"unknown";
        live[@"phase"]=[items[@"active"]boolValue]?@"registering":known?@"unregistered":@"unverified";
        if([native[@"phase"]isEqual:@"failed"]){live[@"phase"]=@"failed";live[@"error"]=native[@"error"]?:@"Album registration failed.";}
    }
    if([native[@"can_continue"]boolValue] || [native[@"stop_pending"]boolValue]){
        for(NSString *key in @[@"can_continue",@"stop_pending",@"stopped_visual"])if(native[key])live[key]=native[key];
    }
    // A stopped preparation may not yet have a native item membership lease.
    if(![live[@"active"]boolValue])for(NSDictionary *job in [self.playlistSnapshot[@"jobs"]reverseObjectEnumerator])if([job[@"can_continue"]boolValue] && [job[@"release_uris"]containsObject:uri]){
        live[@"can_continue"]=@YES;if(![live[@"stopped_visual"]count])live[@"stopped_visual"]=job[@"stopped_visuals"][uri]?:@{};break;
    }
    return live;
}
- (void)detach {self.sessionObservationGeneration++;self.pendingStateRefresh=NO;[self.sessionObservation invalidate];self.sessionObservation=nil;dispatch_block_t stop=self.detachPlaylistObserver;self.detachPlaylistObserver=nil;if(stop)stop();[self detachItems];}
- (void)cancelCatalogLoad {self.loadGeneration++;dispatch_block_t stop=self.cancelCatalog;self.cancelCatalog=nil;if(stop)stop();}
- (void)cancelArtworkLoads {for(SAPArtistReleaseCell *cell in self.artworkCells)[cell cancelArtworkLoad];}
- (void)close {[self cancelArtworkLoads];[self cancelCatalogLoad];[self detach];[self dismissViewControllerAnimated:YES completion:nil];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];self.itemsVisible=NO;[self.loadingSpinner stopAnimating];[self detachItems];if(SAPArtistDownloadsIsDismissing(self)){[self cancelArtworkLoads];[self cancelCatalogLoad];[self detach];}}
- (void)dealloc {if(_foregroundObserver)[NSNotificationCenter.defaultCenter removeObserver:_foregroundObserver];for(SAPArtistReleaseCell *cell in _artworkCells)[cell cancelArtworkLoad];if(_cancelCatalog)_cancelCatalog();[_sessionObservation invalidate];if(_detachPlaylistObserver)_detachPlaylistObserver();[_itemObservation invalidate];}
- (void)bindSession {
    if(!self.allReleases.count)return;
    if(self.sessionObservation){[self.sessionObservation extendReleases:self.allReleases];return;}
    NSUInteger generation=++self.sessionObservationGeneration;__weak typeof(self) weak=self;
    self.sessionObservation=SAPObserveArtistSessionForArtist(self.artistURI,self.allReleases,^(NSDictionary *snapshot){typeof(self) page=weak;if(!page || page.sessionObservationGeneration!=generation)return;page.sessionSnapshot=snapshot;[page requestStateRefresh];});
}
- (void)requestStateRefresh {
    if(self.pendingStateRefresh)return;self.pendingStateRefresh=YES;__weak typeof(self) weak=self;
    dispatch_async(dispatch_get_main_queue(),^{[weak flushPendingStateRefresh];});
}
- (void)flushPendingStateRefresh {
    if(!self.pendingStateRefresh)return;self.pendingStateRefresh=NO;
    // Keep the newest evidence while hidden or covered by the destination picker.
    // UIKit work resumes from that evidence when this page becomes visible.
    if(!self.itemsVisible || !self.viewIfLoaded.window || self.navigationController.topViewController!=self)return;
#ifdef SAP_TESTING
    self.stateRefreshCount++;
#endif
    [self refreshVisibleStates];[self updateControls];
}
- (void)applyPendingCatalog {
    if(!self.pendingCatalog || !self.viewIfLoaded.window || SAPArtistDownloadsIsDismissing(self) || self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating || self.presentedViewController || self.navigationController.topViewController!=self)return;
    NSDictionary *next=self.pendingCatalog;self.pendingCatalog=nil;NSIndexPath *top=[self.tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)].firstObject;
    NSString *anchor=top?self.sections[top.section][@"releases"][top.row][@"uri"]:nil;CGFloat relative=top?[self.tableView rectForRowAtIndexPath:top].origin.y-self.tableView.contentOffset.y:0;
    NSDictionary *old=self.catalog;
    // Retain the visible order. Newly resolved rows append within their
    // category instead of inserting a newer date above an existing row.
    NSMutableArray *merged=[NSMutableArray array];
    for(NSString *title in @[@"Albums",@"EPs",@"Singles",@"Singles & EPs",@"Compilations",@"Appears on"]){
        NSArray *existing=nil,*incoming=nil;for(NSDictionary *group in old[@"sections"])if([group[@"title"]isEqual:title])existing=group[@"releases"];for(NSDictionary *group in next[@"sections"])if([group[@"title"]isEqual:title])incoming=group[@"releases"];
        NSMutableArray *rows=[NSMutableArray arrayWithArray:existing?:@[]];NSMutableSet *seen=[NSMutableSet set];for(NSDictionary *row in rows)[seen addObject:row[@"uri"]];for(NSDictionary *row in incoming)if(![seen containsObject:row[@"uri"]]){[rows addObject:row];[seen addObject:row[@"uri"]];}
        if(rows.count)[merged addObject:@{@"title":title,@"releases":rows}];
    }
    NSMutableDictionary *display=[next mutableCopy];display[@"sections"]=merged;self.catalog=display;NSMutableArray *all=[NSMutableArray array];for(NSDictionary *section in self.sections)[all addObjectsFromArray:section[@"releases"]];self.catalogReleases=all;
    NSMutableSet *present=[NSMutableSet set];for(NSDictionary *release in all)[present addObject:release[@"uri"]];[self.selectedReleaseURIs intersectSet:present];
    BOOL changed=![old[@"sections"]isEqual:display[@"sections"]];
    if(changed)[UIView performWithoutAnimation:^{
        NSDictionary *changes=SAPArtistCatalogAppendChanges(old[@"sections"]?:@[],display[@"sections"]);
        if(changes){
            [self.tableView performBatchUpdates:^{
                if([changes[@"sections"]count])[self.tableView insertSections:changes[@"sections"] withRowAnimation:UITableViewRowAnimationNone];
                if([changes[@"rows"]count])[self.tableView insertRowsAtIndexPaths:changes[@"rows"] withRowAnimation:UITableViewRowAnimationNone];
            } completion:nil];
            // Section tags and the loading counter follow their new indexes,
            // without rebuilding cells or restarting their cover requests.
            for(NSUInteger section=0;section<self.sections.count;section++){
                SAPArtistCategoryHeader *header=(id)[self.tableView headerViewForSection:section];
                if(header)[self configureCategoryHeader:header section:section];
            }
        }else [self.tableView reloadData];
        [self.tableView layoutIfNeeded];if(anchor){for(NSUInteger section=0;section<self.sections.count;section++){NSArray *rows=self.sections[section][@"releases"];for(NSUInteger row=0;row<rows.count;row++)if([rows[row][@"uri"]isEqual:anchor]){CGFloat minimum=-self.tableView.adjustedContentInset.top,maximum=MAX(minimum,self.tableView.contentSize.height-self.tableView.bounds.size.height+self.tableView.adjustedContentInset.bottom);CGFloat target=[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]].origin.y-relative;[self.tableView setContentOffset:CGPointMake(self.tableView.contentOffset.x,MIN(maximum,MAX(minimum,target))) animated:NO];return;}}}}];
    [self updateControls];__weak typeof(self) weak=self;
    NSArray *scope=self.catalog[@"observation_releases"]?:self.allReleases;
    if(!self.detachPlaylistObserver && scope.count)self.detachPlaylistObserver=SAPObservePlaylistReleaseDownloadsForArtist(self.artistURI,scope,^(NSDictionary *snapshot){typeof(self) page=weak;if(!page)return;page.playlistSnapshot=snapshot;[page requestStateRefresh];});
    if(changed)[self bindSession];[self attachItems];
}
- (void)loadCatalog {
    if(self.loading)return;[self detach];self.loading=YES;self.loadError=nil;self.loadProgress=nil;self.loadCompleted=self.loadTotal=0;self.catalog=nil;self.catalogReleases=@[];self.pendingCatalog=nil;[self.selectedReleaseURIs removeAllObjects];
    NSUInteger generation=++self.loadGeneration;[self.tableView reloadData];[self updateControls];__weak typeof(self) weak=self;
    SAP_JOURNAL_ACTION(@"artist_catalog_requested",@{@"artist_uri":self.artistURI?:@""});
    self.cancelCatalog=SAPFetchArtistMetadataProgressively(self.artistURI,^(NSUInteger completed,NSUInteger total){typeof(self) page=weak;if(!page || generation!=page.loadGeneration)return;page.loadCompleted=completed;page.loadTotal=total;page.loadProgress=total?[NSString stringWithFormat:@"Reading release details… %lu / %lu",(unsigned long)completed,(unsigned long)total]:nil;[page updateControls];},^(NSDictionary *catalog){typeof(self) page=weak;if(!page || generation!=page.loadGeneration)return;page.pendingCatalog=catalog;[page applyPendingCatalog];},^(NSDictionary *catalog,NSString *error){typeof(self) page=weak;if(!page || generation!=page.loadGeneration)return;page.cancelCatalog=nil;page.loading=NO;page.loadError=error;page.pendingCatalog=catalog?:@{};[page applyPendingCatalog];[page updateControls];SAP_JOURNAL_ACTION(@"artist_catalog_result",@{@"artist_uri":page.artistURI?:@"",@"release_count":catalog[@"release_count"]?:@0,@"error":error?:@""});});
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self updateControls];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];self.itemsVisible=YES;[self applyPendingCatalog];[self refreshVisibleStates];[self updateControls];[self attachItems];}
- (void)refreshSelectionViews {
    [UIView performWithoutAnimation:^{
        for(NSIndexPath *path in self.tableView.indexPathsForVisibleRows)[self configureCell:[self.tableView cellForRowAtIndexPath:path] release:self.sections[path.section][@"releases"][path.row]];
        for(NSUInteger section=0;section<self.sections.count;section++){SAPArtistCategoryHeader *header=(id)[self.tableView headerViewForSection:section];if(header)[self configureCategoryHeader:header section:section];}
    }];[self updateControls];
}
- (void)toggleSelection {self.selecting=!self.selecting;if(!self.selecting)[self.selectedReleaseURIs removeAllObjects];[self refreshSelectionViews];}
- (void)finishSelection {
    if(!self.selecting)return;self.selecting=NO;[self.selectedReleaseURIs removeAllObjects];[self refreshSelectionViews];
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updateFooterLayout];}
- (void)detachItems {self.itemObservationGeneration++;[self.itemObservation invalidate];self.itemObservation=nil;self.playlistItemSnapshot=nil;}
- (void)refreshVisibleStates {
    if(self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating)return;
    [UIView performWithoutAnimation:^{for(NSIndexPath *path in self.tableView.indexPathsForVisibleRows)[self configureCell:[self.tableView cellForRowAtIndexPath:path] release:self.sections[path.section][@"releases"][path.row]];}];
}
- (void)attachItems {
    if(!self.itemsVisible || !self.allReleases.count)return;
    if(self.itemObservation){[self.itemObservation updateReleases:self.allReleases];return;}
    NSUInteger generation=self.itemObservationGeneration;__weak typeof(self) weak=self;
    // One observation per open catalog. Scrolling never replaces native leases
    // or discards item states; only changed visible rows are rendered.
    NSArray *scope=[(self.catalog[@"observation_releases"]?:@[])arrayByAddingObjectsFromArray:self.allReleases];
    self.itemObservation=SAPObserveReleaseItems(scope,^(NSDictionary *snapshot){typeof(self) page=weak;if(!page || generation!=page.itemObservationGeneration || !page.itemsVisible)return;page.playlistItemSnapshot=snapshot;[page requestStateRefresh];});
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scroll {[self applyPendingCatalog];[self refreshVisibleStates];[self updateFooterLayout];}
- (void)scrollViewDidEndDragging:(UIScrollView *)scroll willDecelerate:(BOOL)decelerate {if(!decelerate){[self applyPendingCatalog];[self refreshVisibleStates];[self updateFooterLayout];}}
- (void)updateFooterLayout {
    if(self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating)return;
    if(!self.allReleases.count){if(self.tableView.tableFooterView)self.tableView.tableFooterView=nil;self.footerWidth=0;return;}
    CGFloat width=MAX(240,self.tableView.bounds.size.width-48);
    if(self.footerWidth==width && self.tableView.tableFooterView==self.footerContainer)return;
    self.footerWidth=width;CGSize size=[self.footerLabel sizeThatFits:CGSizeMake(width,CGFLOAT_MAX)];
    CGRect frame=CGRectMake(0,0,width+48,size.height+32);self.footerLabel.frame=CGRectMake(24,12,width,size.height);
    if(!CGRectEqualToRect(self.footerContainer.frame,frame) || self.tableView.tableFooterView!=self.footerContainer){self.footerContainer.frame=frame;self.tableView.tableFooterView=self.footerContainer;}
}
- (void)updateControls {
    BOOL active=[self.sessionSnapshot[@"active"]boolValue] || [self.playlistSnapshot[@"active"]boolValue];
    BOOL resumable=[self.sessionSnapshot[@"can_continue"]boolValue] || [self.playlistSnapshot[@"can_continue"]boolValue];
    // Older or unavailable producers may omit the summary flag.
    if(!self.sessionSnapshot[@"can_continue"])for(NSDictionary *value in [self.sessionSnapshot[@"album_states"]allValues])if([value[@"can_continue"]boolValue]){resumable=YES;break;}
    if(!self.playlistSnapshot[@"can_continue"])for(NSDictionary *job in self.playlistSnapshot[@"jobs"])if([job[@"can_continue"]boolValue]){resumable=YES;break;}
    self.selectControl.title=self.selecting?@"Cancel":@"Select";self.selectControl.enabled=self.allReleases.count>0;
    BOOL retry=!self.loading && !active && (self.loadError || [self.catalog[@"load_warning"]length]);
    BOOL cancelable=[self.sessionSnapshot[@"can_cancel"]boolValue] || [self.playlistSnapshot[@"can_cancel"]boolValue];
    self.cancelControl.enabled=cancelable;
    NSArray *right=retry?@[self.selectControl,self.retryControl]:@[self.selectControl];if(![self.navigationItem.rightBarButtonItems isEqual:right])self.navigationItem.rightBarButtonItems=right;
    NSUInteger selected=self.selectedReleaseURIs.count;self.downloadControl.title=[NSString stringWithFormat:@"Download selected · %lu",(unsigned long)selected];self.downloadControl.enabled=selected>0;
    NSMutableArray *items=[NSMutableArray array];
    if(self.selecting){if(active)[items addObject:self.stopControl];[items addObjectsFromArray:@[self.toolbarSpace,self.downloadControl]];}
    else {if(cancelable)[items addObject:self.cancelControl];[items addObject:self.toolbarSpace];if(resumable)[items addObject:self.continueControl];if(active)[items addObject:self.stopControl];}
    if(![self.toolbarItems isEqual:items])self.toolbarItems=items;
    if(self.navigationController.topViewController==self)[self.navigationController setToolbarHidden:!active&&!self.selecting&&!resumable&&!cancelable animated:NO];
    NSString *loading=self.allReleases.count?nil:self.loading?(self.loadProgress?:@"Loading releases…"):self.loadError?:@"Spotify returned no music releases for this artist.";
    if(![self.loadingLabel.text isEqual:loading])self.loadingLabel.text=loading;
    if(self.loading && !self.allReleases.count){if(!self.loadingSpinner.isAnimating)[self.loadingSpinner startAnimating];}else if(self.loadingSpinner.isAnimating)[self.loadingSpinner stopAnimating];
    UIView *background=loading?self.loadingContainer:nil;if(self.tableView.backgroundView!=background)self.tableView.backgroundView=background;
    NSString *text=@"Tap a release to download it or stop its download. Use Select to choose individual releases or whole categories, then download separately or through a new or existing playlist. Stop pauses downloads associated with this list. Continue resumes stopped work after a fresh Spotify status check. Cancel stops unfinished downloads for this artist. Downloads stay inside Spotify.";
    if(self.loading)text=[text stringByAppendingString:@" More releases are loading. Category selection applies to loaded releases."];
    if([self.sessionSnapshot[@"error"]length])text=[text stringByAppendingFormat:@"\n%@",self.sessionSnapshot[@"error"]];
    if([self.catalog[@"load_warning"]length])text=[text stringByAppendingFormat:@"\n%@",self.catalog[@"load_warning"]];
    for(NSDictionary *job in self.playlistSnapshot[@"jobs"])if([job[@"error"]length] || ([job[@"active"]boolValue] && ![job[@"context_state"]count]))text=[text stringByAppendingFormat:@"\n%@",job[@"message"]?:job[@"error"]];
    if(![self.footerText isEqual:text]) {self.footerText=text;self.footerLabel.text=text;self.footerWidth=0;}
    [self updateLoadingHeader];[self updateFooterLayout];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return self.sections.count;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return [self.sections[section][@"releases"]count];}
- (NSString *)categoryTitleForSection:(NSUInteger)section {NSDictionary *group=self.sections[section];return [NSString stringWithFormat:@"%@ (%lu)",group[@"title"],(unsigned long)[group[@"releases"]count]];}
- (void)updateLoadingHeader {
    if(!self.sections.count)return;SAPArtistCategoryHeader *header=(id)[self.tableView headerViewForSection:0];if(!header)return;
    BOOL visible=self.loading && self.allReleases.count>0;header.catalogProgressLabel.hidden=!visible;header.catalogProgressLabel.text=visible?[NSString stringWithFormat:@"Loading %lu/%lu",(unsigned long)self.loadCompleted,(unsigned long)self.loadTotal]:nil;
}
- (void)configureCategoryHeader:(SAPArtistCategoryHeader *)header section:(NSUInteger)section {
    NSDictionary *group=self.sections[section];header.categoryTitle.text=[self categoryTitleForSection:section];
    BOOL progress=section==0 && self.loading;header.catalogProgressLabel.hidden=!progress;header.catalogProgressLabel.text=progress?[NSString stringWithFormat:@"Loading %lu/%lu",(unsigned long)self.loadCompleted,(unsigned long)self.loadTotal]:nil;
    UIButton *button=header.selectionButton;button.tag=section;button.hidden=!self.selecting;
    BOOL all=YES,any=NO;for(NSDictionary *release in group[@"releases"]){BOOL selected=[self.selectedReleaseURIs containsObject:release[@"uri"]];all&=selected;any|=selected;}button.selected=all;
    [button setImage:[UIImage systemImageNamed:any&&!all?@"minus.circle":@"circle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20.4 weight:UIImageSymbolWeightRegular]] forState:UIControlStateNormal];
    button.accessibilityLabel=[NSString stringWithFormat:self.loading?@"Select loaded %@":@"Select %@",group[@"title"]];
    button.accessibilityValue=button.selected?@"Selected":@"Not selected";
    button.accessibilityTraits=UIAccessibilityTraitButton|(button.selected?UIAccessibilityTraitSelected:0);
    [button removeTarget:self action:@selector(toggleCategory:) forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(toggleCategory:) forControlEvents:UIControlEventTouchUpInside];
}
- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    SAPArtistCategoryHeader *header=[table dequeueReusableHeaderFooterViewWithIdentifier:@"ArtistCategory"];
    if(!header)header=[[SAPArtistCategoryHeader alloc]initWithReuseIdentifier:@"ArtistCategory"];
    [self configureCategoryHeader:header section:section];return header;
}
- (void)toggleCategory:(UIButton *)button {
    NSUInteger section=(NSUInteger)button.tag;if(!self.selecting || section>=self.sections.count)return;NSArray *releases=self.sections[section][@"releases"];BOOL all=YES;
    for(NSDictionary *release in releases)all&=[self.selectedReleaseURIs containsObject:release[@"uri"]];
    for(NSDictionary *release in releases)if(all)[self.selectedReleaseURIs removeObject:release[@"uri"]];else[self.selectedReleaseURIs addObject:release[@"uri"]];
    [self refreshSelectionViews];
}
- (NSArray *)selectedReleases {NSMutableArray *releases=[NSMutableArray array];for(NSDictionary *release in self.allReleases)if([self.selectedReleaseURIs containsObject:release[@"uri"]])[releases addObject:release];return releases;}
- (void)configureCell:(UITableViewCell *)cell release:(NSDictionary *)release {
    SAPArtistReleaseCell *releaseCell=(id)cell;NSDictionary *renderState=[self stateFor:release[@"uri"]];BOOL renderSelected=[self.selectedReleaseURIs containsObject:release[@"uri"]];
    if([releaseCell.renderedRelease isEqual:release] && [releaseCell.renderedState isEqual:renderState] && releaseCell.renderedSelecting==self.selecting && releaseCell.renderedSelected==renderSelected)return;
    if(![releaseCell.renderedRelease[@"uri"]isEqual:release[@"uri"]])releaseCell.progressIndicator=nil;
    releaseCell.renderedRelease=release;releaseCell.renderedState=renderState;releaseCell.renderedSelecting=self.selecting;releaseCell.renderedSelected=renderSelected;
    if(!cell)return;
    NSString *coverURL=release[@"cover_url"],*coverID=SAPArtistArtworkIdentifier(coverURL);
    BOOL same=[objc_getAssociatedObject(cell,&SAPArtistArtworkURLKey)isEqual:coverID];
    UIListContentConfiguration *old=(id)cell.contentConfiguration;
    BOOL reuseContent=[old isKindOfClass:UIListContentConfiguration.class] && same && [old.text isEqual:release[@"name"]];
    UIListContentConfiguration *content=reuseContent?[old copy]:[UIListContentConfiguration subtitleCellConfiguration];
    if(!reuseContent){
        // Preserve native text styling and layout when only progress changes.
        NSDirectionalEdgeInsets margins=content.directionalLayoutMargins;margins.trailing+=52;content.directionalLayoutMargins=margins;
        content.text=release[@"name"];content.textProperties.numberOfLines=0;content.secondaryTextProperties.numberOfLines=0;
        UIFont *font=content.secondaryTextProperties.font?:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        UIFontDescriptor *digits=[font.fontDescriptor fontDescriptorByAddingAttributes:@{UIFontDescriptorFeatureSettingsAttribute:@[@{UIFontFeatureTypeIdentifierKey:@(kNumberSpacingType),UIFontFeatureSelectorIdentifierKey:@(kMonospacedNumbersSelector)}]}];
        content.secondaryTextProperties.font=[UIFont fontWithDescriptor:digits size:font.pointSize];
        content.image=same&&old.image?old.image:SAPArtistArtworkPlaceholder();content.imageProperties.maximumSize=CGSizeMake(52,52);content.imageProperties.reservedLayoutSize=CGSizeMake(52,52);content.imageProperties.cornerRadius=8;
    }
    NSString *category=SAPArtistReleaseCategoryTitle(release);
    NSString *subtitle=[release[@"year"]integerValue]?[NSString stringWithFormat:@"%@ · %@",release[@"year"],category]:category;
    NSDictionary *state=renderState;NSString *kind=state[@"state"];
    BOOL selected=[self.selectedReleaseURIs containsObject:release[@"uri"]];
    UIView *indicator=self.selecting?SAPArtistStateIcon(selected?@"checkmark.circle.fill":@"circle",selected?UIColor.systemGreenColor:UIColor.secondaryLabelColor,selected?@"Selected":@"Not selected"):[(SAPArtistReleaseCell *)cell indicatorForState:state];
    cell.accessibilityTraits=UIAccessibilityTraitButton|(self.selecting&&selected?UIAccessibilityTraitSelected:0);
    NSString *phase=state[@"phase"];
    if([kind isEqual:@"downloaded"]) {subtitle=[subtitle stringByAppendingString:@" · Downloaded"];}
    else if([state[@"can_continue"]boolValue])subtitle=[subtitle stringByAppendingString:@" · Stopped"];
    else if([phase isEqual:@"failed"]){}
    else if([phase isEqual:@"unverified"])subtitle=[subtitle stringByAppendingString:@" · Checking album offline status…"];
    else if([phase isEqual:@"unregistered"])subtitle=[subtitle stringByAppendingString:@" · Tracks available; album not downloaded"];
    else if([phase isEqual:@"registering"])subtitle=[subtitle stringByAppendingString:@" · Registering album for offline…"];
    else if([phase isEqual:@"stopping"] || [state[@"stopping"]boolValue])subtitle=[subtitle stringByAppendingString:@" · Stopping…"];
    else if([phase isEqual:@"queued"])subtitle=[subtitle stringByAppendingString:@" · Queued"];
    else if([phase isEqual:@"preparing"])subtitle=[subtitle stringByAppendingString:@" · Preparing…"];
    else if([phase isEqual:@"waiting"])subtitle=[subtitle stringByAppendingString:@" · Waiting for Spotify…"];
    else if([kind isEqual:@"partial"]) {
        NSUInteger done=[state[@"downloaded_tracks"]unsignedIntegerValue],total=[state[@"total_tracks"]unsignedIntegerValue];
        if([phase isEqual:@"downloading"] || (!phase.length && [state[@"active"]boolValue])) {
            NSString *progress=total?[SAPArtistTrackCounter(done,total) stringByAppendingString:@" · Downloading…"]:@"Downloading…";
            subtitle=[subtitle stringByAppendingFormat:@" · %@",progress];
        } else {
            NSString *progress=total?[SAPArtistTrackCounter(done,total) stringByAppendingString:@" · Partially downloaded"]:@"Partially downloaded";
            subtitle=[subtitle stringByAppendingFormat:@" · %@",progress];
        }
    } else if([phase isEqual:@"downloading"] || (!phase.length && [state[@"active"]boolValue]))subtitle=[subtitle stringByAppendingString:@" · Downloading…"];
    if([state[@"playlist_download"]boolValue])subtitle=[subtitle stringByAppendingFormat:@" · In %@",state[@"playlist_name"]?:@"playlist"];
    if([state[@"error"]length])subtitle=[subtitle stringByAppendingFormat:@" · %@",state[@"error"]];
    if(!reuseContent || ![old.secondaryText isEqual:subtitle]){content.secondaryText=subtitle;cell.contentConfiguration=content;}
    cell.accessoryType=UITableViewCellAccessoryNone;
    SAPApplyArtistListRowBackground(cell);
    [(SAPArtistReleaseCell *)cell setDownloadIndicator:indicator];
    if(!same)[(SAPArtistReleaseCell *)cell cancelArtworkLoad];
    objc_setAssociatedObject(cell,&SAPArtistArtworkURLKey,coverID,OBJC_ASSOCIATION_COPY_NONATOMIC);
    if(coverID && !same) {
        __weak typeof(self) weak=self;__weak UITableViewCell *weakCell=cell;
        ((SAPArtistReleaseCell *)cell).cancelArtwork=[[SAPArtistArtworkLoader shared]loadURL:coverURL completion:^(UIImage *image){
            UITableViewCell *current=weakCell;if(!weak.viewIfLoaded.window || !current || ![objc_getAssociatedObject(current,&SAPArtistArtworkURLKey)isEqual:coverID])return;
            ((SAPArtistReleaseCell *)current).cancelArtwork=nil;
            if(!image){objc_setAssociatedObject(current,&SAPArtistArtworkURLKey,nil,OBJC_ASSOCIATION_COPY_NONATOMIC);return;}
            UIListContentConfiguration *updated=(id)current.contentConfiguration;updated.image=image;[UIView performWithoutAnimation:^{current.contentConfiguration=updated;[(SAPArtistReleaseCell *)current installIndicatorLayout];}];
        }];
    }
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"ArtistRelease"];if(!cell)cell=[[SAPArtistReleaseCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ArtistRelease"];
    [self.artworkCells addObject:(SAPArtistReleaseCell *)cell];
    [self configureCell:cell release:self.sections[path.section][@"releases"][path.row]];return cell;
}
- (void)afterDialog:(UIAlertController *)dialog perform:(dispatch_block_t)action {
    __weak typeof(self) weak=self;SAPAfterDialogDismissal(dialog,^{typeof(self) page=weak;if(!page)return;[page applyPendingCatalog];if(action)action();});
}
- (void)startReleases:(NSArray *)releases {
    if(!releases.count)return;NSMutableArray *pending=[NSMutableArray array];for(NSDictionary *release in releases){NSString *uri=release[@"uri"];BOOL downloaded=[[self stateFor:uri][@"state"]isEqual:@"downloaded"];if(!downloaded){NSMutableDictionary *owned=[release mutableCopy];owned[@"artist_uri"]=self.artistURI;[pending addObject:owned];}}
    SAP_JOURNAL_ACTION(@"artist_separate_selection_filtered",@{@"selected":@(releases.count),@"already_downloaded":@(releases.count-pending.count),@"remaining":@(pending.count)});
    if(!pending.count){[self finishSelection];[self updateControls];return;}NSString *error=nil;if(SAPAppendArtistDownloadSessionReleases(pending,&error)){[self finishSelection];[self updateControls];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not start download" message:error preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];__weak typeof(self) weakPage=self;dispatch_async(dispatch_get_main_queue(),^{[weakPage applyPendingCatalog];});NSDictionary *release=self.sections[path.section][@"releases"][path.row];NSDictionary *state=[self stateFor:release[@"uri"]];
    if(self.selecting){NSString *uri=release[@"uri"];if([self.selectedReleaseURIs containsObject:uri])[self.selectedReleaseURIs removeObject:uri];else[self.selectedReleaseURIs addObject:uri];[self refreshSelectionViews];return;}
    if([state[@"stopping"]boolValue] || [state[@"state"]isEqual:@"downloaded"])return;
    if([state[@"active"]boolValue] && [state[@"playlist_download"]boolValue]){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Stop playlist download?" message:[NSString stringWithFormat:@"This release is downloading through \"%@\". Other releases in that playlist will also stop.",state[@"playlist_name"]?:@"Playlist"] preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){if(SAPDiagnosticsEnabled())SAP_JOURNAL_ACTION(@"artist_playlist_row_stop",@{@"artist_uri":self.artistURI?:@"",@"release_uri":release[@"uri"]?:@"",@"caller":@"tableView:didSelectRowAtIndexPath:/Stop UIAlertAction handler",@"action_origin":@"alert_action_handler",@"requested_reason":@"stop_artist_playlist_tasks_containing_release",@"call_stack":NSThread.callStackSymbols});SAPStopPlaylistReleaseDownloadsForArtist(self.artistURI,@[release]);}]];[self presentViewController:alert animated:YES completion:nil];return;
    }
    if([state[@"active"]boolValue])SAPStopArtistDownloadSessionRelease(release[@"uri"]);else[self startReleases:@[release]];
}
- (void)continueDownloads {
    NSArray *scope=self.catalog[@"observation_releases"]?:self.allReleases;NSString *error=nil;
    if(!SAPContinueArtistDownloads(self.artistURI,scope,&error) || !SAPContinuePlaylistReleaseDownloadsForArtist(self.artistURI,scope,&error)){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not continue" message:error?:@"Spotify has not confirmed that the previous operation stopped." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
    }
    [self updateControls];
}
- (void)confirmCancelDownloads {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Cancel downloads?" message:@"Cancel all unfinished downloads for this artist?" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep downloading" style:UIAlertActionStyleCancel handler:nil]];__weak typeof(self) weak=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel downloads" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){typeof(self) page=weak;if(!page)return;SAPCancelPlaylistReleaseDownloadsForArtist(page.artistURI);SAPCancelArtistDownloadSession(page.artistURI);[page requestStateRefresh];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showError:(NSString *)error {UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not start playlist download" message:error preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
- (void)startPlaylist:(NSArray *)releases uri:(NSString *)uri name:(NSString *)name {
    NSString *error=nil;if(!SAPStartPlaylistReleaseDownloadForArtist(self.artistURI,releases,uri,name,&error)){[self showError:error];return;}
    [self finishSelection];[self updateControls];[self attachItems];
}
- (void)playlistNameChanged:(UITextField *)field {NSString *name=[field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];self.nameConfirmation.enabled=name.length>0 && name.length<=200;}
- (void)newPlaylist:(NSArray *)releases {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"New playlist" message:[NSString stringWithFormat:@"Save %lu selected releases to Your Library, add their tracks in release order and download the playlist.",(unsigned long)releases.count] preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weak=self;[alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"Playlist name";field.autocapitalizationType=UITextAutocapitalizationTypeSentences;[field addTarget:weak action:@selector(playlistNameChanged:) forControlEvents:UIControlEventEditingChanged];}];
    __weak UIAlertController *weakAlert=alert;[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action){[weak afterDialog:weakAlert perform:nil];}]];
    UIAlertAction *confirm=[UIAlertAction actionWithTitle:@"Create and download" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){NSString *name=[weakAlert.textFields.firstObject.text copy];[weak afterDialog:weakAlert perform:^{[weak startPlaylist:releases uri:nil name:name];}];}];confirm.enabled=NO;self.nameConfirmation=confirm;[alert addAction:confirm];[self presentViewController:alert animated:YES completion:nil];
}
- (void)existingPlaylist:(NSArray *)releases {
    SAPPlaylistPickerController *picker=[SAPPlaylistPickerController new];__weak typeof(self) weak=self;
    picker.onChoose=^(NSDictionary *playlist,UIViewController *presenter){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Add and download?" message:[NSString stringWithFormat:@"Add %lu selected releases to \"%@\" and download this playlist? Existing tracks stay in place. Tracks already in the playlist will not be added again.",(unsigned long)releases.count,playlist[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakAlert=alert;[alert addAction:[UIAlertAction actionWithTitle:@"Add and download" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){typeof(self) page=weak;if(!page)return;SAPAfterDialogDismissal(weakAlert,^{typeof(self) current=weak;if(!current)return;UINavigationController *navigation=current.navigationController;[navigation popToViewController:current animated:YES];dispatch_block_t start=^{if(navigation.topViewController==current && !SAPArtistDownloadsIsDismissing(navigation))[current startPlaylist:releases uri:playlist[@"uri"] name:playlist[@"name"]];};if(navigation.transitionCoordinator)[navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context){start();}];else start();});}]];[presenter presentViewController:alert animated:YES completion:nil];
    };[self.navigationController pushViewController:picker animated:YES];
}
- (void)downloadSelected {
    NSArray *releases=self.selectedReleases;if(!releases.count)return;__weak typeof(self) weak=self;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Download selected" message:[NSString stringWithFormat:@"%lu releases selected",(unsigned long)releases.count] preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIAlertController *weakMenu=menu;[menu addAction:[UIAlertAction actionWithTitle:@"Download separately" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:^{[weak startReleases:releases];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"New playlist" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:^{[weak newPlaylist:releases];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Existing playlist" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:^{[weak existingPlaylist:releases];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:nil];}]];menu.popoverPresentationController.barButtonItem=self.downloadControl;[self presentViewController:menu animated:YES completion:nil];
}
@end
@interface SAPArtistDownloadsSheetController : UIViewController
@property(nonatomic,strong) UINavigationController *navigationContent;
- (instancetype)initWithNavigationContent:(UINavigationController *)navigation;
@end
@implementation SAPArtistDownloadsSheetController
- (instancetype)initWithNavigationContent:(UINavigationController *)navigation {
    if((self=[super initWithNibName:nil bundle:nil]))_navigationContent=navigation;
    return self;
}
- (void)loadView {
    UIVisualEffectView *material=SAPArtistListMaterial();
    if(@available(iOS 26.0,*))material.cornerConfiguration=[UICornerConfiguration configurationWithUniformRadius:UICornerRadius.containerConcentricRadius];
    self.view=material;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    UIVisualEffectView *material=(UIVisualEffectView *)self.view;
    UINavigationController *navigation=self.navigationContent;
    [self addChildViewController:navigation];
    navigation.view.translatesAutoresizingMaskIntoConstraints=NO;
    [material.contentView addSubview:navigation.view];
    [NSLayoutConstraint activateConstraints:@[
        [navigation.view.leadingAnchor constraintEqualToAnchor:material.contentView.leadingAnchor],
        [navigation.view.trailingAnchor constraintEqualToAnchor:material.contentView.trailingAnchor],
        [navigation.view.topAnchor constraintEqualToAnchor:material.contentView.topAnchor],
        [navigation.view.bottomAnchor constraintEqualToAnchor:material.contentView.bottomAnchor]
    ]];
    [navigation didMoveToParentViewController:self];
}
- (UIViewController *)childViewControllerForStatusBarStyle {return self.navigationContent;}
- (UIViewController *)childViewControllerForStatusBarHidden {return self.navigationContent;}
@end

void SAPShowArtistDownloads(NSString *artistURI,NSString *artistName,UIViewController *presenter) {
    if(!NSThread.isMainThread) {dispatch_async(dispatch_get_main_queue(),^{SAPShowArtistDownloads(artistURI,artistName,presenter);});return;}
    if(![presenter isKindOfClass:UIViewController.class] || !presenter.viewIfLoaded.window)return;
    while(presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)presenter=presenter.presentedViewController;
    if([presenter isKindOfClass:SAPArtistDownloadsController.class] || [presenter isKindOfClass:SAPArtistDownloadsSheetController.class])return;
    SAPArtistDownloadsController *page=[SAPArtistDownloadsController new];page.artistURI=artistURI;page.artistName=artistName;
    UINavigationController *navigation=[[UINavigationController alloc]initWithRootViewController:page];navigation.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    navigation.view.backgroundColor=UIColor.clearColor;
    navigation.navigationBar.tintColor=UIColor.whiteColor;
    UIViewController *sheetContent=navigation;
    if(@available(iOS 26.1,*))sheetContent=[[SAPArtistDownloadsSheetController alloc]initWithNavigationContent:navigation];
    sheetContent.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    sheetContent.modalPresentationStyle=UIModalPresentationPageSheet;
    if(@available(iOS 15.0,*)) {
        UISheetPresentationController *sheet=sheetContent.sheetPresentationController;
        sheet.detents=@[UISheetPresentationControllerDetent.largeDetent];
        sheet.selectedDetentIdentifier=UISheetPresentationControllerDetentIdentifierLarge;
        sheet.prefersGrabberVisible=YES;
        // Only the root material renders glass; the presentation adds no second effect.
        if(@available(iOS 26.1,*))sheet.backgroundEffect=[UIColorEffect effectWithColor:UIColor.clearColor];
    }
    [presenter presentViewController:sheetContent animated:YES completion:nil];
}
