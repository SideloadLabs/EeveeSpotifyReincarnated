#import "PlaylistPickerController.h"
#import "ArtistDownloadComponents.h"
#import "ArtistArtworkLoader.h"
#import "PlaylistDownloads.h"
#import <objc/runtime.h>

@interface SAPPlaylistPickerController ()
@property(nonatomic,strong) NSArray *playlists,*filtered;
@property(nonatomic,strong) UISearchController *search;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) NSCache<NSString *,UIImage *> *knownCovers;
@property(nonatomic,strong) NSHashTable<SAPArtistReleaseCell *> *artworkCells;
@property(nonatomic,copy) dispatch_block_t cancelLoad;
@property(nonatomic) NSUInteger generation;
@end
@implementation SAPPlaylistPickerController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Existing playlist";self.knownCovers=[NSCache new];self.knownCovers.countLimit=64;self.knownCovers.totalCostLimit=4*1024*1024;self.artworkCells=[NSHashTable weakObjectsHashTable];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.tableView.backgroundColor=UIColor.blackColor;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;
    self.search=[[UISearchController alloc]initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"Search playlists";self.navigationItem.searchController=self.search;self.definesPresentationContext=YES;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadPlaylists)];
    self.statusLabel=[UILabel new];self.statusLabel.numberOfLines=0;self.statusLabel.textAlignment=NSTextAlignmentCenter;self.statusLabel.textColor=UIColor.secondaryLabelColor;
    [self loadPlaylists];
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self.navigationController setToolbarHidden:YES animated:animated];}
- (void)dealloc {if(_cancelLoad)_cancelLoad();}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController || self.navigationController.isBeingDismissed){self.generation++;if(self.cancelLoad)self.cancelLoad();self.cancelLoad=nil;for(SAPArtistReleaseCell *cell in self.artworkCells)[cell cancelArtworkLoad];}}
- (void)loadPlaylists {
    if(self.cancelLoad)self.cancelLoad();NSUInteger generation=++self.generation;self.statusLabel.text=@"Loading playlists…";self.tableView.backgroundView=self.statusLabel;self.navigationItem.rightBarButtonItem.enabled=NO;
    __weak typeof(self) weak=self;self.cancelLoad=SAPFetchWritablePlaylists(^(NSArray *playlists,NSString *error){
        typeof(self) page=weak;if(!page || page.generation!=generation)return;page.cancelLoad=nil;page.playlists=playlists?:@[];page.navigationItem.rightBarButtonItem.enabled=YES;
        [page updateSearchResultsForSearchController:page.search];if(error.length){page.statusLabel.text=error;page.tableView.backgroundView=page.statusLabel;}
    });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)search {
    NSString *text=search.searchBar.text?:@"";NSMutableArray *rows=[NSMutableArray array];for(NSDictionary *entry in self.playlists)if(!text.length || [entry[@"name"]localizedCaseInsensitiveContainsString:text])[rows addObject:entry];
    self.filtered=rows;self.statusLabel.text=self.playlists.count?@"No matching playlists.":@"No playlists you can add tracks to were found.";self.tableView.backgroundView=rows.count?nil:self.statusLabel;[self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return self.filtered.count;}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    SAPArtistReleaseCell *cell=[table dequeueReusableCellWithIdentifier:@"PlaylistDestination"];if(!cell)cell=[[SAPArtistReleaseCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"PlaylistDestination"];
    [self.artworkCells addObject:cell];NSDictionary *playlist=self.filtered[path.row];NSString *uri=playlist[@"uri"],*imageURI=[playlist[@"cover_uri"]length]?playlist[@"cover_uri"]:playlist[@"cover_url"];
    NSString *identity=imageURI.length?[NSString stringWithFormat:@"%@|%@|%lu",uri,imageURI,(unsigned long)self.generation]:uri;BOOL same=[objc_getAssociatedObject(cell,&SAPArtistArtworkURLKey)isEqual:identity];
    UIImage *known=[self.knownCovers objectForKey:uri];if(!same)[cell cancelArtworkLoad];objc_setAssociatedObject(cell,&SAPArtistArtworkURLKey,identity,OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIListContentConfiguration *old=(id)cell.contentConfiguration,*content=[UIListContentConfiguration subtitleCellConfiguration];content.text=playlist[@"name"];content.secondaryText=playlist[@"track_count"]?[NSString stringWithFormat:@"%@ tracks",playlist[@"track_count"]]:@"Playlist";content.image=known?:same?old.image:SAPArtistArtworkPlaceholder();content.imageProperties.maximumSize=CGSizeMake(52,52);content.imageProperties.reservedLayoutSize=CGSizeMake(52,52);content.imageProperties.cornerRadius=8;cell.contentConfiguration=content;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if(!same && imageURI.length){__weak SAPArtistReleaseCell *weakCell=cell;__weak typeof(self) weak=self;cell.cancelArtwork=[[SAPArtistArtworkLoader shared]loadPlaylistURI:imageURI completion:^(UIImage *image){typeof(self) page=weak;SAPArtistReleaseCell *current=weakCell;if(!page || !current || ![objc_getAssociatedObject(current,&SAPArtistArtworkURLKey)isEqual:identity])return;current.cancelArtwork=nil;if(image){[page.knownCovers setObject:image forKey:uri cost:(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4];UIListContentConfiguration *updated=(id)current.contentConfiguration;updated.image=image;current.contentConfiguration=updated;}}];}
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {[table deselectRowAtIndexPath:path animated:YES];if(self.onChoose)self.onChoose(self.filtered[path.row],self);}
@end

