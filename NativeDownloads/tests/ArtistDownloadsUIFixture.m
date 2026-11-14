#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "ArtistDownloadsUI.h"
#import "ArtistDownloadSession.h"
#import "PlaylistDownloads.h"
#import "WireProto.h"
#include <assert.h>
void SAPArtistArtworkSetDataProviderForTesting(void (^provider)(NSString *,void (^)(NSData *)));
dispatch_block_t SAPArtistArtworkLoadForTesting(NSString *url,void (^completion)(UIImage *));
static void (^catalogReply)(NSDictionary *,NSString *);
static void (^catalogProgress)(NSUInteger,NSUInteger);
static void (^catalogPreview)(NSDictionary *);
static void (^observer)(NSDictionary *);
static void (^originalArtworkProvider)(NSString *,void (^)(NSData *));
static NSMutableDictionary<NSString *,NSMutableArray *> *heldArtworkReplies;
static NSMutableDictionary<NSString *,NSNumber *> *artworkProviderCallCounts;
static NSMutableDictionary *states;
static __weak UITableViewController *fixturePage;
static BOOL fixtureActive;
static NSUInteger artistCancels,playlistCancels;
static NSString *cancelledArtist,*cancelledPlaylistArtist;
static NSString *fixtureArtist(void){return @"spotify:artist:0000000000000000000001";}
static NSDictionary *fixtureSnapshot(BOOL active){BOOL resumable=NO;for(NSDictionary *state in states.allValues)resumable|=[state[@"can_continue"]boolValue];return @{@"album_states":[states copy],@"active":@(active),@"can_continue":@(resumable),@"can_cancel":@(active||resumable)};}
static NSUInteger sessionAttaches,sessionExtends,sessionRefreshes;
static void flushFixtureUI(void){if(fixturePage)((void(*)(id,SEL))objc_msgSend)(fixturePage,NSSelectorFromString(@"flushPendingStateRefresh"));}
static NSArray *started;
static NSArray<NSDictionary *> *stoppedReleases;
static NSUInteger starts,stops,stopOne,detached,coverRequests;
static NSData *coverPNG;
static NSUInteger nativeCoverReads,nativeCoverCancels;
static BOOL failNativeCover,failMosaicCover;
static NSUInteger mosaicCoverReads;
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *service,NSString *method,NSData *payload,void(^completion)(NSData *,NSString *)){
 assert([service isEqual:@"spotify.image.esperanto.proto.Image"] && [method isEqual:@"GetImage"]);NSArray *fields=SAPProtoFields(payload);assert(SAPProtoString(fields,1).length);NSArray *size=SAPProtoFields(SAPProtoData(SAPProtoFields(SAPProtoData(fields,2)),1));assert(SAPProtoNumber(size,1,0)==128 && SAPProtoNumber(size,2,0)==128);nativeCoverReads++;__block BOOL cancelled=NO;BOOL fail=failNativeCover;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.03*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!cancelled)completion(fail?SAPProtoInteger(1,5):SAPProtoBytes(3,coverPNG),nil);});return ^{if(!cancelled){cancelled=YES;nativeCoverCancels++;}};
}
static NSString *uri(NSUInteger n){return [NSString stringWithFormat:@"spotify:album:%022lu",(unsigned long)n];}
bool SAPDiagnosticsEnabled(void){return true;}
void SAPJournalNoteAction(NSString *name,NSDictionary *facts){}
dispatch_block_t SAPFetchArtistMetadataCancellable(NSString *artist,void(^progress)(NSUInteger,NSUInteger),void(^done)(NSDictionary*,NSString*)){catalogReply=[done copy];catalogProgress=[progress copy];return ^{};}
dispatch_block_t SAPObserveArtistDownloadSession(NSArray *releases,void(^done)(NSDictionary*)) {observer=[done copy];void(^owned)(NSDictionary *)=observer;done(@{@"album_states":[states copy],@"active":@NO});return ^{detached++;if(observer==owned)observer=nil;};}
@interface SAPArtistSessionObservation ()
@property(nonatomic,copy) void (^fixtureReply)(NSDictionary *);
@end
@implementation SAPArtistSessionObservation
- (void)extendReleases:(NSArray *)releases {sessionExtends++;}
- (void)refresh {sessionRefreshes++;if(self.fixtureReply)self.fixtureReply(fixtureSnapshot(fixtureActive));}
- (void)invalidate {if(self.fixtureReply){detached++;if(observer==self.fixtureReply)observer=nil;self.fixtureReply=nil;}}
@end
SAPArtistSessionObservation *SAPObserveArtistSession(NSArray *releases,void(^done)(NSDictionary *)){
 sessionAttaches++;SAPArtistSessionObservation *value=[SAPArtistSessionObservation new];value.fixtureReply=done;observer=value.fixtureReply;done(@{@"album_states":[states copy],@"active":@NO});return value;
}
SAPArtistSessionObservation *SAPObserveArtistSessionForArtist(NSString *artist,NSArray *releases,void(^done)(NSDictionary *)){assert([artist isEqual:fixtureArtist()]);return SAPObserveArtistSession(releases,done);}
void SAPCancelArtistDownloadSession(NSString *artist){artistCancels++;cancelledArtist=artist;}
BOOL SAPReserveArtistDownloadSessionReleases(NSArray *releases,NSString **error){return YES;}
BOOL SAPAppendArtistDownloadSessionReleases(NSArray *releases,NSString **error){started=releases;starts++;return YES;}
dispatch_block_t SAPFetchArtistMetadataProgressively(NSString *artist,void(^progress)(NSUInteger,NSUInteger),void(^preview)(NSDictionary *),void(^done)(NSDictionary *,NSString *)){catalogPreview=[preview copy];return SAPFetchArtistMetadataCancellable(artist,progress,done);}
void SAPStopArtistDownloadSessionRelease(NSString *album){stopOne++;}
void SAPStopArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases){stops++;stoppedReleases=[releases copy];}
void SAPStopArtistDownloadSessionReleasesForArtist(NSString *artist,NSArray *releases){assert([artist isEqual:fixtureArtist()]);SAPStopArtistDownloadSessionReleases(releases);}
static NSUInteger playlistStarts,playlistStops;
static NSArray *stoppedPlaylistReleases;
static NSString *pickedPlaylist,*pickedName;
static void (^playlistObserver)(NSDictionary *);
static void (^itemObserver)(NSDictionary *);
static NSDictionary *itemStates;
static NSUInteger itemDetaches,itemAttaches;
@implementation SAPReleaseItemObservation
- (void)updateReleases:(NSArray *)releases {}
- (void)invalidate {if(itemObserver){itemDetaches++;itemObserver=nil;}}
@end
SAPReleaseItemObservation *SAPObserveReleaseItems(NSArray *releases,void(^completion)(NSDictionary *)){itemAttaches++;itemObserver=[completion copy];completion(@{@"album_states":itemStates?:@{}});return [SAPReleaseItemObservation new];}
static NSUInteger continued,playlistContinued;
BOOL SAPContinueArtistDownloadSessionReleases(NSArray *releases,NSString **error){continued++;return YES;}
BOOL SAPContinuePlaylistReleaseDownloads(NSArray *releases,NSString **error){playlistContinued++;return YES;}
BOOL SAPContinueArtistDownloads(NSString *artist,NSArray *releases,NSString **error){assert([artist isEqual:fixtureArtist()]);return SAPContinueArtistDownloadSessionReleases(releases,error);}
BOOL SAPContinuePlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases,NSString **error){assert([artist isEqual:fixtureArtist()]);return SAPContinuePlaylistReleaseDownloads(releases,error);}
void SAPCancelPlaylistReleaseDownloadsForArtist(NSString *artist){playlistCancels++;cancelledPlaylistArtist=artist;}
static void emitItems(NSUInteger done){itemStates=@{uri(3):@{@"state":done==3?@"downloaded":@"partial",@"phase":done==3?@"downloaded":@"downloading",@"active":@(done!=3),@"downloaded_tracks":@(done),@"total_tracks":@3,@"progress":@((double)done/3),@"playlist_download":@YES,@"playlist_name":@"Other playlist",@"download_source":@"native_items"}};if(itemObserver)itemObserver(@{@"album_states":itemStates});flushFixtureUI();}
dispatch_block_t SAPFetchWritablePlaylists(void(^completion)(NSArray *,NSString *)) {
    dispatch_async(dispatch_get_main_queue(),^{completion(@[@{@"uri":@"spotify:playlist:0000000000000000000001",@"name":@"Existing playlist",@"track_count":@12,@"cover_uri":@"spotify:mosaic:0123456789abcdef0123456789abcdef01234567",@"cover_url":@"https://i.scdn.co/image/0123456789abcdef0123456789abcdef01234567"},@{@"uri":@"spotify:playlist:0000000000000000000002",@"name":@"Other playlist",@"track_count":@4,@"cover_uri":@"spotify:image:ab67616d00001e020123456789abcdef01234567",@"cover_url":@""}],nil);});return ^{};
}
BOOL SAPStartPlaylistReleaseDownload(NSArray *releases,NSString *uri,NSString *name,NSString **error){playlistStarts++;started=releases;pickedPlaylist=uri;pickedName=name;if(playlistObserver)playlistObserver(@{@"active":@YES,@"can_cancel":@YES,@"jobs":@[@{@"active":@YES,@"message":[NSString stringWithFormat:@"Downloading %@… 2 / 31 tracks",name],@"context_state":@{@"downloaded_tracks":@2,@"total_tracks":@31}}]});return YES;}
dispatch_block_t SAPObservePlaylistReleaseDownloads(NSArray *releases,void(^completion)(NSDictionary *)){playlistObserver=[completion copy];completion(@{@"active":@NO,@"jobs":@[]});return ^{playlistObserver=nil;};}
BOOL SAPStartPlaylistReleaseDownloadForArtist(NSString *artist,NSArray *releases,NSString *uri,NSString *name,NSString **error){assert([artist isEqual:fixtureArtist()]);return SAPStartPlaylistReleaseDownload(releases,uri,name,error);}
dispatch_block_t SAPObservePlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases,void(^completion)(NSDictionary *)){assert([artist isEqual:fixtureArtist()]);return SAPObservePlaylistReleaseDownloads(releases,completion);}
void SAPStopPlaylistReleaseDownloads(NSArray *releases){assert(0 && "Artist UI must use artist-scoped playlist Stop");}
void SAPStopPlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases){assert([artist isEqual:fixtureArtist()]);playlistStops++;stoppedPlaylistReleases=[releases copy];}
static void invoke(UIBarButtonItem *item){assert(item.enabled);if(item.primaryAction){[item.primaryAction performWithSender:item target:nil];return;}assert(item.target);((void(*)(id,SEL))objc_msgSend)(item.target,item.action);}
static UIBarButtonItem *selectionControl(UITableViewController *page){
 for(UIBarButtonItem *item in page.navigationItem.rightBarButtonItems)if([item.title isEqual:@"Select"]||[item.title isEqual:@"Cancel"])return item;
 for(UIBarButtonItem *item in page.toolbarItems)if([item.title isEqual:@"Select"])return item;assert(0);return nil;
}
static void emit(BOOL active){assert(observer);fixtureActive=active;observer(fixtureSnapshot(active));flushFixtureUI();}
static NSDictionary *catalog(void){NSMutableArray*sections=[NSMutableArray array];NSArray*titles=@[@"Albums",@"EPs",@"Singles",@"Singles & EPs",@"Compilations",@"Appears on"];
 for(NSUInteger i=0;i<titles.count;i++)[sections addObject:@{@"title":titles[i],@"releases":@[@{@"uri":uri(i+1),@"name":i==0?@"A longer album title that wraps onto multiple lines in the download list":[NSString stringWithFormat:@"Release %lu",(unsigned long)i+1],@"year":@2026,@"category":titles[i],@"type":@(i==5?4:1),@"cover_url":@"https://i.scdn.co/image/0123456789abcdef0123456789abcdef01234567"}]}];return @{@"sections":sections,@"release_count":@6};}
static void tap(UITableViewController *page,NSUInteger section){[page.tableView.delegate tableView:page.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:section]];}
static void assertPlaylistRowStop(UITableViewController *page,dispatch_block_t done){
 states[uri(3)]=@{@"state":@"not_downloaded",@"active":@NO};emit(NO);emitItems(2);NSUInteger previousStops=playlistStops,previousSingleStops=stopOne;tap(page,2);UIAlertController *dialog=(id)page.presentedViewController;assert([dialog isKindOfClass:UIAlertController.class] && [dialog.title isEqual:@"Stop playlist download?"]);
 UIBarButtonItem *toolbarStop=[page valueForKey:@"stopControl"];[toolbarStop.primaryAction performWithSender:toolbarStop target:nil];assert(playlistStops==previousStops);
 void(^stop)(UIAlertAction *)=[dialog.actions.lastObject valueForKey:@"handler"];
 [dialog dismissViewControllerAnimated:NO completion:^{stop(dialog.actions.lastObject);assert(playlistStops==previousStops+1 && stopOne==previousSingleStops && stoppedPlaylistReleases.count==1 && [stoppedPlaylistReleases.firstObject[@"uri"]isEqual:uri(3)]);done();}];
}
static void assertCoalescedRendering(UITableViewController *page,dispatch_block_t done){
 flushFixtureUI();NSUInteger before=[[page valueForKey:@"stateRefreshCount"]unsignedIntegerValue];
 for(int n=0;n<50;n++){states[uri(1)]=@{@"state":@"partial",@"phase":@"downloading",@"active":@YES,@"progress":@((n+1)/100.)};observer(@{@"album_states":[states copy],@"active":@YES,@"can_continue":@NO});}
 assert([[page valueForKey:@"stateRefreshCount"]unsignedIntegerValue]==before);
 dispatch_async(dispatch_get_main_queue(),^{assert([[page valueForKey:@"stateRefreshCount"]unsignedIntegerValue]==before+1);NSDictionary *latest=[page valueForKey:@"sessionSnapshot"][@"album_states"][uri(1)];assert(fabs([latest[@"progress"]doubleValue]-.5)<.001);done();});
}
static UIView *findCategoryButton(UIView *view,NSUInteger section){
 if([view isKindOfClass:UIButton.class] && [view.accessibilityIdentifier isEqual:@"PixieArtistCategorySelection"] && view.tag==(NSInteger)section)return view;
 for(UIView *child in view.subviews){UIView *found=findCategoryButton(child,section);if(found)return found;}
 return nil;
}
static UIButton *categoryButton(UITableViewController *page,NSUInteger section){
 UIView *header=[page.tableView headerViewForSection:section];assert(header);UIButton *button=(id)findCategoryButton(header,section);assert(button);return button;
}
static UILabel *firstNonemptyLabel(UIView *view){
 if([view isKindOfClass:UILabel.class]&&((UILabel *)view).text.length)return (id)view;
 for(UIView *child in view.subviews){UILabel *label=firstNonemptyLabel(child);if(label)return label;}
 return nil;
}
static UIView *albumIndicator(UITableViewCell *cell){
 [cell layoutIfNeeded];for(UIView *view in cell.contentView.subviews)if([view.accessibilityIdentifier isEqual:@"PixieAlbumStatus"])return view.subviews.firstObject;
 return nil;
}
static NSArray<CAShapeLayer *> *progressShapeLayers(UIView *view){
 NSMutableArray<CAShapeLayer *> *layers=[NSMutableArray array];
 for(CALayer *layer in view.layer.sublayers)if([layer isKindOfClass:CAShapeLayer.class])[layers addObject:(id)layer];
 return [layers copy];
}
static void assertFooterStable(UITableViewController *page,UIView *footer,UILabel *label,CGRect footerBounds,CGRect labelBounds,CGRect labelFrame){
 assert(page.tableView.tableFooterView==footer && [firstNonemptyLabel(footer) isEqual:label]);
 assert(CGRectEqualToRect(footer.bounds,footerBounds) && CGRectEqualToRect(label.bounds,labelBounds) && CGRectEqualToRect(label.frame,labelFrame));
}
static NSUInteger nonemptyLabelCount(UIView *view){
 NSUInteger count=[view isKindOfClass:UILabel.class]&&((UILabel *)view).text.length?1:0;
 for(UIView *child in view.subviews)count+=nonemptyLabelCount(child);
 return count;
}
static UILabel *categoryTitleLabel(UIView *view){
 if([view isKindOfClass:UILabel.class]&&((UILabel *)view).text.length)return (id)view;
 for(UIView *child in view.subviews){UILabel *label=categoryTitleLabel(child);if(label)return label;}
 return nil;
}
static void checkCategoryHeader(UITableViewController *page,NSUInteger section,NSString *expectedTitle){
 UITableViewHeaderFooterView *header=[page.tableView headerViewForSection:section];assert(header);[header layoutIfNeeded];[header.contentView layoutIfNeeded];
 UIButton *button=categoryButton(page,section);UILabel *label=categoryTitleLabel(header);assert(nonemptyLabelCount(header)==1 && [label.text isEqual:expectedTitle]);
 CGRect titleFrame=[header convertRect:label.bounds fromView:label],buttonFrame=[header convertRect:button.bounds fromView:button];
 assert(button.frame.size.width==44 && button.frame.size.height==44);
 assert(CGRectGetMinX(buttonFrame)>=0 && CGRectGetMinY(buttonFrame)>=0 && CGRectGetMaxX(buttonFrame)<=CGRectGetWidth(header.bounds) && CGRectGetMaxY(buttonFrame)<=CGRectGetHeight(header.bounds));
 assert(CGRectGetMaxX(titleFrame)<=CGRectGetMinX(buttonFrame)-7.5);
 assert(!button.backgroundColor || CGColorGetAlpha(button.backgroundColor.CGColor)==0);
}
static void toggleCategory(UITableViewController *page,NSUInteger section){[categoryButton(page,section) sendActionsForControlEvents:UIControlEventTouchUpInside];}
static void withCover(UITableViewController *page,NSUInteger attempts,dispatch_block_t done){
 UITableViewCell*cell=[page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
 UIImage*image=((UIListContentConfiguration*)cell.contentConfiguration).image;
 if(image.size.width==120 && coverRequests>=1){done();return;}assert(attempts>0);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.03*NSEC_PER_SEC),dispatch_get_main_queue(),^{withCover(page,attempts-1,done);});
}
static void checkTextClearance(UIView *view,UITableViewCell *cell,CGRect indicator) {
 if([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) {
  CGRect rect=[cell convertRect:view.bounds fromView:view];assert(CGRectGetMaxX(rect)<=CGRectGetMinX(indicator)-7.5);
 }
 for(UIView *child in view.subviews)checkTextClearance(child,cell,indicator);
}
static CGPoint indicatorCenter(UITableViewCell *cell){
 [cell layoutIfNeeded];UIView *host=nil;for(UIView *view in cell.contentView.subviews)if([view.accessibilityIdentifier isEqual:@"PixieAlbumStatus"])host=view;
 assert(host && host.bounds.size.width==40 && host.bounds.size.height==40);
 CGRect frame=[cell convertRect:host.bounds fromView:host];assert(fabs(CGRectGetMidY(frame)-CGRectGetMidY(cell.bounds))<.5);
 assert(fabs(CGRectGetMaxX(frame)-CGRectGetMaxX(cell.layoutMarginsGuide.layoutFrame))<.5);
 checkTextClearance(cell.contentView,cell,frame);
 UIView *glyph=host.subviews.firstObject;assert(glyph);CGPoint center=[cell convertPoint:CGPointMake(CGRectGetMidX(glyph.bounds),CGRectGetMidY(glyph.bounds)) fromView:glyph];
 assert(fabs(center.x-CGRectGetMidX(frame))<.5 && fabs(center.y-CGRectGetMidY(frame))<.5);return center;
}
static void assertSelectionDoesNotShrinkIndicators(UITableViewController *page){
 NSIndexPath *firstPath=[NSIndexPath indexPathForRow:0 inSection:0];
 CAShapeLayer *initialRing=progressShapeLayers(albumIndicator([page.tableView cellForRowAtIndexPath:firstPath])).lastObject;
 CGRect ringBounds=CGPathGetBoundingBox(initialRing.path);
 for(NSUInteger n=0;n<100;n++){
  invoke(selectionControl(page));invoke(selectionControl(page));[page.tableView layoutIfNeeded];
  UITableViewCell *cell=[page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];UIView *ring=albumIndicator(cell);[ring layoutIfNeeded];
  assert(CGSizeEqualToSize(ring.bounds.size,CGSizeMake(40,40)));
  UIImageView *arrow=(id)ring.subviews.firstObject;assert([arrow isKindOfClass:UIImageView.class] && CGSizeEqualToSize(arrow.bounds.size,CGSizeMake(16,16)));
  CAShapeLayer *currentRing=progressShapeLayers(ring).lastObject;assert(CGRectEqualToRect(CGPathGetBoundingBox(currentRing.path),ringBounds));
  UIView *complete=albumIndicator([page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]]);assert(CGSizeEqualToSize(complete.bounds.size,CGSizeMake(32,32)));
  assert([selectionControl(page).title isEqual:@"Select"] && ![page.toolbarItems containsObject:selectionControl(page)]);
 }
}
static void checkPlaylistArtwork(UITableViewController *picker,NSUInteger attempts,dispatch_block_t completion){
 [picker.tableView layoutIfNeeded];UITableViewCell *cell=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];UIImage *image=((UIListContentConfiguration *)cell.contentConfiguration).image;if(image.size.width!=120 || nativeCoverReads<1 || mosaicCoverReads<1){assert(attempts>0);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.02*NSEC_PER_SEC),dispatch_get_main_queue(),^{checkPlaylistArtwork(picker,attempts-1,completion);});return;}
 NSUInteger readsBefore=nativeCoverReads,mosaicBefore=mosaicCoverReads;
 for(NSUInteger reload=0;reload<12;reload++){[picker.navigationItem.searchController.searchResultsUpdater updateSearchResultsForSearchController:picker.navigationItem.searchController];[picker.tableView layoutIfNeeded];cell=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];assert(((UIListContentConfiguration *)cell.contentConfiguration).image.size.width==120);}
 assert(nativeCoverReads==readsBefore && mosaicCoverReads==mosaicBefore);
 NSMutableArray *rows=[[picker valueForKey:@"playlists"]mutableCopy];NSMutableDictionary *changed=[rows[0]mutableCopy];changed[@"cover_uri"]=@"spotify:mosaic:abcdef0123456789abcdef0123456789abcdef01";rows[0]=changed;[picker setValue:rows forKey:@"playlists"];failMosaicCover=YES;[picker.navigationItem.searchController.searchResultsUpdater updateSearchResultsForSearchController:picker.navigationItem.searchController];[picker.tableView layoutIfNeeded];
 assert(((UIListContentConfiguration *)[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].contentConfiguration).image.size.width==120);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.12*NSEC_PER_SEC),dispatch_get_main_queue(),^{assert(nativeCoverReads==readsBefore && mosaicCoverReads==mosaicBefore+1);assert(((UIListContentConfiguration *)[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].contentConfiguration).image.size.width==120);failMosaicCover=NO;completion();});
}
static void awaitCondition(BOOL(^condition)(void),NSUInteger attempts,dispatch_block_t done){if(condition()){done();return;}assert(attempts>0);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.02*NSEC_PER_SEC),dispatch_get_main_queue(),^{awaitCondition(condition,attempts-1,done);});}
static void withAlert(UITableViewController *page,NSUInteger attempts,void(^done)(UIAlertController *)) {
 UIViewController *shown=page.presentedViewController?:page.navigationController.presentedViewController;
 if([shown isKindOfClass:UIAlertController.class] && !shown.isBeingPresented && !shown.isBeingDismissed && !shown.transitionCoordinator){done((id)shown);return;}assert(attempts>0);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.02*NSEC_PER_SEC),dispatch_get_main_queue(),^{withAlert(page,attempts-1,done);});
}
static void assertScopedCancel(UITableViewController *page,dispatch_block_t done){
 emit(YES);assert([page.toolbarItems.firstObject.title isEqual:@"Cancel"] && [selectionControl(page).title isEqual:@"Select"]);
 invoke(selectionControl(page));assert([selectionControl(page).title isEqual:@"Cancel"] && [page.toolbarItems.firstObject.title isEqual:@"Stop"] && [page.toolbarItems.lastObject.title hasPrefix:@"Download selected"]);
 for(UIBarButtonItem *item in page.toolbarItems)assert(![item.accessibilityLabel isEqual:@"Cancel downloads"]);
 invoke(selectionControl(page));invoke(page.toolbarItems.firstObject);
 withAlert(page,250,^(UIAlertController *dialog){
  assert([dialog.message isEqual:@"Cancel all unfinished downloads for this artist?"] && dialog.actions.count==2);
  assert([dialog.actions.firstObject.title isEqual:@"Keep downloading"] && dialog.actions.lastObject.style==UIAlertActionStyleDestructive);
  NSUInteger beforeArtist=artistCancels,beforePlaylist=playlistCancels;void(^cancel)(UIAlertAction *)=[dialog.actions.lastObject valueForKey:@"handler"];
  [dialog dismissViewControllerAnimated:NO completion:^{cancel(dialog.actions.lastObject);flushFixtureUI();assert(artistCancels==beforeArtist+1 && playlistCancels==beforePlaylist+1 && [cancelledArtist isEqual:fixtureArtist()] && [cancelledPlaylistArtist isEqual:fixtureArtist()]);done();}];
 });
}
static void waitForArtworkProvider(NSString *url,NSUInteger expected,NSUInteger attempts,dispatch_block_t done){
 if([artworkProviderCallCounts[url]unsignedIntegerValue]>=expected){done();return;}assert(attempts>0);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.01*NSEC_PER_SEC),dispatch_get_main_queue(),^{waitForArtworkProvider(url,expected,attempts-1,done);});
}
static void replyToArtwork(NSString *url,NSUInteger index){NSArray *replies=heldArtworkReplies[url];assert(index<replies.count);((void (^)(NSData *))replies[index])(coverPNG);}
static void runArtworkCancellationTests(dispatch_block_t done){
 heldArtworkReplies=[NSMutableDictionary dictionary];artworkProviderCallCounts=[NSMutableDictionary dictionary];
 SAPArtistArtworkSetDataProviderForTesting(^(NSString *url,void(^reply)(NSData *)){
  dispatch_async(dispatch_get_main_queue(),^{
   artworkProviderCallCounts[url]=@([artworkProviderCallCounts[url]unsignedIntegerValue]+1);
   NSMutableArray *replies=heldArtworkReplies[url];if(!replies)heldArtworkReplies[url]=replies=[NSMutableArray array];[replies addObject:[reply copy]];
  });
 });
 NSString *sharedURL=@"https://i.scdn.co/image/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
 __block NSUInteger cancelledConsumerDeliveries=0,remainingConsumerDeliveries=0;
 __block UIImage *remainingConsumerImage=nil;
 dispatch_block_t cancelFirst=SAPArtistArtworkLoadForTesting(sharedURL,^(__unused UIImage *image){cancelledConsumerDeliveries++;});
 SAPArtistArtworkLoadForTesting(sharedURL,^(UIImage *image){remainingConsumerDeliveries++;remainingConsumerImage=image;});
 waitForArtworkProvider(sharedURL,1,200,^{
  cancelFirst();replyToArtwork(sharedURL,0);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.08*NSEC_PER_SEC),dispatch_get_main_queue(),^{
   assert(cancelledConsumerDeliveries==0 && remainingConsumerDeliveries==1 && remainingConsumerImage);
   NSString *restartURL=@"https://i.scdn.co/image/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
   __block NSUInteger oldConsumerDeliveries=0,newConsumerDeliveries=0;__block UIImage *newImage=nil;
   dispatch_block_t cancelOld=SAPArtistArtworkLoadForTesting(restartURL,^(__unused UIImage *image){oldConsumerDeliveries++;});
   waitForArtworkProvider(restartURL,1,200,^{
    cancelOld();SAPArtistArtworkLoadForTesting(restartURL,^(UIImage *image){newConsumerDeliveries++;newImage=image;});
    waitForArtworkProvider(restartURL,2,200,^{
     replyToArtwork(restartURL,0);replyToArtwork(restartURL,1);
     dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.08*NSEC_PER_SEC),dispatch_get_main_queue(),^{
      assert(oldConsumerDeliveries==0 && newConsumerDeliveries==1 && newImage);
      __block NSUInteger cancelledCacheDelivery=0;
      dispatch_block_t cancelCached=SAPArtistArtworkLoadForTesting(sharedURL,^(__unused UIImage *image){cancelledCacheDelivery++;});cancelCached();
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.08*NSEC_PER_SEC),dispatch_get_main_queue(),^{
       assert(cancelledCacheDelivery==0);SAPArtistArtworkSetDataProviderForTesting(originalArtworkProvider);done();
      });
     });
    });
   });
  });
 });
}
static void finish(NSString *message){NSURL*d=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;[message writeToURL:[d URLByAppendingPathComponent:@"artist-picker-result.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];}
@interface ArtistPickerFixtureScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong)UIWindow*window;
@end
@implementation ArtistPickerFixtureScene
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
 states=[NSMutableDictionary dictionary];for(NSUInteger n=1;n<=6;n++)states[uri(n)]=@{@"state":@"not_downloaded",@"active":@NO};states[uri(2)]=@{@"state":@"downloaded",@"active":@NO};
 UIImage*image=[[[UIGraphicsImageRenderer alloc]initWithSize:CGSizeMake(40,40)]imageWithActions:^(UIGraphicsImageRendererContext*c){[UIColor.systemRedColor setFill];UIRectFill(CGRectMake(0,0,40,40));}];coverPNG=UIImagePNGRepresentation(image);
 originalArtworkProvider=^(NSString*url,void(^done)(NSData*)){assert(!NSThread.isMainThread);coverRequests++;BOOL mosaic=[url hasPrefix:@"https://mosaic.scdn.co/300/"];if(mosaic)mosaicCoverReads++;BOOL fail=mosaic&&failMosaicCover;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.03*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{done(fail?nil:coverPNG);});};SAPArtistArtworkSetDataProviderForTesting(originalArtworkProvider);
 self.window=[[UIWindow alloc]initWithWindowScene:(id)scene];UIViewController*root=[UIViewController new];root.view.backgroundColor=UIColor.blackColor;self.window.rootViewController=root;[self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
  SAPShowArtistDownloads(@"spotify:artist:0000000000000000000001",@"Fixture artist",root);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
   awaitCondition(^BOOL{UINavigationController *ready=(id)root.presentedViewController;return ready && [[ready.topViewController valueForKey:@"itemsVisible"]boolValue] && !ready.isBeingPresented;},250,^{
   UINavigationController*nav=(id)root.presentedViewController;UITableViewController*page=(id)nav.topViewController;fixturePage=page;assert(catalogReply);UIActivityIndicatorView *spinner=[page valueForKey:@"loadingSpinner"];assert(spinner.isAnimating && page.tableView.numberOfSections==0 && !page.tableView.tableFooterView);catalogProgress(7,723);[page.view layoutIfNeeded];UIView *loading=[page valueForKey:@"loadingContainer"];[loading layoutIfNeeded];UILabel *label=[page valueForKey:@"loadingLabel"];CGRect text=[loading convertRect:label.bounds fromView:label],indicator=[loading convertRect:spinner.bounds fromView:spinner];assert([label.text containsString:@"7 / 723"] && CGRectGetMinX(text)>=23.5 && CGRectGetMaxX(text)<=CGRectGetWidth(loading.bounds)-23.5 && CGRectGetMinY(indicator)>=CGRectGetMaxY(text)+11.5);NSMutableArray *scope=[NSMutableArray array];for(NSDictionary *group in catalog()[@"sections"])[scope addObjectsFromArray:group[@"releases"]];
   catalogPreview(@{@"sections":@[catalog()[@"sections"][2]],@"release_count":@1,@"observation_releases":scope});[page.view layoutIfNeeded];assert(page.tableView.numberOfSections==1 && !spinner.isAnimating && selectionControl(page).enabled);UITableViewHeaderFooterView *firstHeader=[page.tableView headerViewForSection:0];UILabel *loadCounter=[firstHeader valueForKey:@"catalogProgressLabel"];assert([loadCounter.text isEqual:@"Loading 7/723"] && !loadCounter.hidden);CGFloat loadingHeight=firstHeader.bounds.size.height;
   invoke(selectionControl(page));tap(page,0);assert([[[page valueForKey:@"selectedReleaseURIs"]allObjects]containsObject:uri(3)]);
   catalogProgress(20,723);catalogPreview(@{@"sections":@[catalog()[@"sections"][1],catalog()[@"sections"][2]],@"release_count":@2,@"observation_releases":scope});[page.view layoutIfNeeded];assert([[[page valueForKey:@"selectedReleaseURIs"]allObjects]containsObject:uri(3)] && [page.toolbarItems.lastObject.title isEqual:@"Download selected · 1"]);firstHeader=[page.tableView headerViewForSection:0];assert([[[firstHeader valueForKey:@"catalogProgressLabel"]text]isEqual:@"Loading 20/723"] && fabs(firstHeader.bounds.size.height-loadingHeight)<.5);
   invoke(selectionControl(page));catalogReply(catalog(),nil);[page.tableView setContentOffset:CGPointMake(0,-page.tableView.adjustedContentInset.top) animated:NO];[page.view layoutIfNeeded];assert(page.tableView.numberOfSections==6 && !spinner.isAnimating && !page.tableView.backgroundView && page.tableView.tableFooterView);
   assert(nav.toolbarHidden && [selectionControl(page).title isEqual:@"Select"]);
   assert([page.navigationItem.leftBarButtonItem.tintColor isEqual:UIColor.whiteColor] && nav.navigationBar.barStyle==UIBarStyleBlack && page.traitCollection.userInterfaceStyle==UIUserInterfaceStyleDark);
   [page.view layoutIfNeeded];UITableViewCell *first=[page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];CGPoint initial=indicatorCenter(first);
   tap(page,0);assert(starts==1);tap(page,1);assert(starts==1);
   ((void(*)(id,SEL,id))objc_msgSend)(page,NSSelectorFromString(@"startReleases:"),@[catalog()[@"sections"][1][@"releases"][0]]);assert(starts==1);
   states[uri(1)]=@{@"state":@"partial",@"phase":@"waiting",@"active":@YES,@"downloaded_tracks":@0,@"total_tracks":@10,@"progress":@0};emit(YES);
   assert([((UIListContentConfiguration *)first.contentConfiguration).secondaryText containsString:@"Waiting for Spotify"]);
   states[uri(1)]=@{@"state":@"partial",@"phase":@"downloading",@"active":@YES,@"downloaded_tracks":@5,@"total_tracks":@10,@"progress":@.5};emit(YES);
   assert([((UIListContentConfiguration *)first.contentConfiguration).secondaryText containsString:@"Downloading"]);CGPoint activeCenter=indicatorCenter(first);assert(fabs(initial.x-activeCenter.x)<.5);
   assertSelectionDoesNotShrinkIndicators(page);
   assert([page.navigationItem.rightBarButtonItem.title isEqual:@"Select"] && [page.toolbarItems.firstObject.title isEqual:@"Cancel"] && [page.toolbarItems.lastObject.title isEqual:@"Stop"] && ![page.toolbarItems containsObject:selectionControl(page)]);
   UIBarButtonItem *toolbarStop=page.toolbarItems.lastObject;assert(toolbarStop.primaryAction);
   [toolbarStop.primaryAction performWithSender:nil target:nil];assert(!stops && !playlistStops);
   [nav setToolbarHidden:YES animated:NO];[toolbarStop.primaryAction performWithSender:toolbarStop target:nil];assert(!stops && !playlistStops);[nav setToolbarHidden:NO animated:NO];
   invoke(toolbarStop);assert(stops==1 && playlistStops==1 && !stoppedPlaylistReleases);
   states[uri(1)]=@{@"state":@"not_downloaded",@"active":@NO,@"can_continue":@YES,@"stopped_visual":@{@"progress":@.5,@"downloaded_tracks":@5,@"total_tracks":@10}};emit(NO);
   NSArray *stoppedShapes=progressShapeLayers(albumIndicator(first));assert(stoppedShapes.count==2 && fabs(((CAShapeLayer *)stoppedShapes.lastObject).strokeEnd-.5)<.001 && [albumIndicator(first).accessibilityLabel containsString:@"Stopped"]);assert([((UIListContentConfiguration *)first.contentConfiguration).secondaryText containsString:@"Stopped"]);
   states[uri(1)]=@{@"state":@"not_downloaded",@"active":@NO,@"can_continue":@YES,@"stopped_visual":@{@"progress":@0,@"downloaded_tracks":@0,@"total_tracks":@1}};emit(NO);stoppedShapes=progressShapeLayers(albumIndicator(first));assert(stoppedShapes.count==2 && ((CAShapeLayer *)stoppedShapes.lastObject).strokeEnd==0 && [albumIndicator(first).accessibilityLabel containsString:@"Stopped"]);
   assert([page.toolbarItems.lastObject.title isEqual:@"Continue"] && !nav.toolbarHidden);invoke(page.toolbarItems.lastObject);assert(continued==1 && playlistContinued==1);
   states[uri(1)]=@{@"state":@"partial",@"phase":@"downloading",@"active":@YES,@"downloaded_tracks":@5,@"total_tracks":@10,@"progress":@.5};emit(YES);
   invoke(selectionControl(page));assert([selectionControl(page).title isEqual:@"Cancel"] && !page.toolbarItems.lastObject.enabled);
   tap(page,0);tap(page,1);toggleCategory(page,2);assert(starts==1 && stopOne==0 && page.toolbarItems.lastObject.enabled && [page.toolbarItems.lastObject.title isEqual:@"Download selected · 3"]);
   assert(categoryButton(page,0).selected && categoryButton(page,1).selected && categoryButton(page,2).selected);checkCategoryHeader(page,0,@"Albums (1)");
   invoke(selectionControl(page));assert([selectionControl(page).title isEqual:@"Select"]);tap(page,0);assert(stopOne==1);
   invoke(selectionControl(page));tap(page,0);tap(page,1);toggleCategory(page,2);
   invoke(page.toolbarItems.lastObject);withAlert(page,300,^(UIAlertController *menu){
    assert(menu.preferredStyle==UIAlertControllerStyleActionSheet && menu.actions.count==4);
    NSArray *titles=[menu.actions valueForKey:@"title"];assert(([titles isEqual:@[@"Download separately",@"New playlist",@"Existing playlist",@"Cancel"]]));
    NSArray *selectedForPlaylist=[page valueForKey:@"selectedReleases"];void(^action)(UIAlertAction*)=[menu.actions.firstObject valueForKey:@"handler"];assert(action);action(menu.actions.firstObject);
    awaitCondition(^BOOL{return starts==2;},250,^{assert(starts==2 && started.count==2 && [started[0][@"uri"]isEqual:uri(1)] && [started[1][@"uri"]isEqual:uri(3)]);
    assert([selectionControl(page).title isEqual:@"Select"] && ![page.toolbarItems.lastObject.title hasPrefix:@"Download selected"]);
     // Exercise the name form directly, avoiding UIKit's automatic action-sheet
     // dismissal timing when invoking a stored action handler in a fixture.
     ((void(*)(id,SEL,id))objc_msgSend)(page,NSSelectorFromString(@"newPlaylist:"),selectedForPlaylist);
     withAlert(page,300,^(UIAlertController *form){
      assert(form.textFields.count==1 && !form.actions.lastObject.enabled);UITextField *field=form.textFields.firstObject;field.text=@"  ";[field sendActionsForControlEvents:UIControlEventEditingChanged];assert(!form.actions.lastObject.enabled);field.text=@"My releases";[field sendActionsForControlEvents:UIControlEventEditingChanged];assert(form.actions.lastObject.enabled);
      void(^create)(UIAlertAction*)=[form.actions.lastObject valueForKey:@"handler"];create(form.actions.lastObject);awaitCondition(^BOOL{return playlistStarts==1;},250,^{assert(playlistStarts==1 && !pickedPlaylist && [pickedName isEqual:@"My releases"]);
      assert([selectionControl(page).title isEqual:@"Select"] && !page.tableView.tableHeaderView);
       ((void(*)(id,SEL,id))objc_msgSend)(page,NSSelectorFromString(@"existingPlaylist:"),selectedForPlaylist);
       dispatch_after(dispatch_time(DISPATCH_TIME_NOW,.5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        UITableViewController *picker=(id)nav.topViewController;assert(picker!=page && [picker.title isEqual:@"Existing playlist"] && [picker.tableView.dataSource tableView:picker.tableView numberOfRowsInSection:0]==2);
        checkPlaylistArtwork(picker,250,^{
        UISearchController *search=picker.navigationItem.searchController;search.searchBar.text=@"other";[search.searchResultsUpdater updateSearchResultsForSearchController:search];assert([picker.tableView.dataSource tableView:picker.tableView numberOfRowsInSection:0]==1);
        [picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        withAlert(picker,300,^(UIAlertController *confirm){
         assert([confirm.message containsString:@"Other playlist"] && playlistStarts==1);void(^add)(UIAlertAction*)=[confirm.actions.lastObject valueForKey:@"handler"];[confirm dismissViewControllerAnimated:NO completion:^{add(confirm.actions.lastObject);}];
         dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1.0*NSEC_PER_SEC),dispatch_get_main_queue(),^{
          assert(playlistStarts==2 && [pickedPlaylist isEqual:@"spotify:playlist:0000000000000000000002"] && started.count==3);
          assert(root.presentedViewController==nav && nav.presentingViewController==root && nav.topViewController==page && [selectionControl(page).title isEqual:@"Select"] && !nav.toolbarHidden && [page.toolbarItems.firstObject.title isEqual:@"Cancel"] && [page.toolbarItems.lastObject.title isEqual:@"Stop"]);
          assert(!page.tableView.tableHeaderView && itemObserver);NSUInteger foregroundAttaches=itemAttaches,foregroundDetaches=itemDetaches;[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];assert(itemAttaches==foregroundAttaches+1 && itemDetaches==foregroundDetaches+1 && page.tableView.numberOfSections==6);emitItems(2);
          UITableViewCell *releaseCell=[page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];assert(releaseCell);
          NSString *progressText=((UIListContentConfiguration *)releaseCell.contentConfiguration).secondaryText;
          assert([progressText containsString:@"2 / 3 tracks"] && [progressText containsString:@"In Other playlist"]);
          UIView *ring=albumIndicator(releaseCell);NSArray *shapes=progressShapeLayers(ring);assert(shapes.count==2);
          assert(fabs(((CAShapeLayer *)shapes.lastObject).strokeEnd-2./3)<.001 && CGColorEqualToColor(((CAShapeLayer *)shapes.lastObject).strokeColor,[UIColor colorWithRed:1 green:.66 blue:.18 alpha:1].CGColor));
          NSUInteger leasesBeforeScroll=itemAttaches;NSString *subtitleBeforeScroll=((UIListContentConfiguration *)releaseCell.contentConfiguration).secondaryText;
          for(NSUInteger scroll=0;scroll<80;scroll++){[page.tableView.delegate scrollViewDidEndDecelerating:page.tableView];assert(albumIndicator(releaseCell)==ring && [releaseCell.contentView.subviews filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIView *view,NSDictionary *bindings){return [view.accessibilityIdentifier isEqual:@"PixieAlbumStatus"];}]].count==1);}
          assert(itemAttaches==leasesBeforeScroll && [((UIListContentConfiguration *)releaseCell.contentConfiguration).secondaryText isEqual:subtitleBeforeScroll]);
          emitItems(3);assert(![[[page valueForKey:@"sessionSnapshot"][@"album_states"][uri(3)]objectForKey:@"state"]isEqual:@"downloaded"]);states[uri(3)]=@{@"state":@"downloaded",@"active":@NO};emit(NO);UIImageView *complete=(id)albumIndicator(releaseCell);assert([complete isKindOfClass:UIImageView.class] && [complete.tintColor isEqual:UIColor.systemGreenColor]);
          NSUInteger separateBeforeCached=starts;((void(*)(id,SEL,id))objc_msgSend)(page,NSSelectorFromString(@"startReleases:"),@[catalog()[@"sections"][2][@"releases"][0]]);assert(starts==separateBeforeCached);
          // Selection remains usable while the first playlist continues downloading.
          invoke(selectionControl(page));tap(page,3);assert([page.toolbarItems.lastObject.title isEqual:@"Download selected · 1"] && [page.toolbarItems.firstObject.title isEqual:@"Stop"]);
          invoke(selectionControl(page));assert([page.toolbarItems.firstObject.title isEqual:@"Cancel"] && [page.toolbarItems.lastObject.title isEqual:@"Stop"]);
          playlistObserver(@{@"active":@YES,@"can_cancel":@YES,@"jobs":@[@{@"active":@YES,@"queued":@YES,@"submitted":@NO,@"release_uris":@[uri(4)],@"playlist_name":@"Other playlist",@"message":@"Queued: Other playlist"}]});flushFixtureUI();
          UITableViewCell *queuedCell=[page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:3]];assert([((UIListContentConfiguration *)queuedCell.contentConfiguration).secondaryText containsString:@"Queued"]);
          states[uri(1)]=@{@"state":@"downloaded",@"active":@NO};emit(NO);

          withCover(page,100,^{
           UITableViewCell *cell=[page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];CGPoint center=indicatorCenter(cell);assert(fabs(center.x-initial.x)<.5);
           [nav.view layoutIfNeeded];
           UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc]initWithBounds:nav.view.bounds];UIImage *screen=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){[nav.view drawViewHierarchyInRect:nav.view.bounds afterScreenUpdates:YES];}];NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;[UIImagePNGRepresentation(screen)writeToURL:[docs URLByAppendingPathComponent:@"artist-picker.png"] atomically:YES];
          playlistObserver(@{@"active":@NO,@"jobs":@[]});flushFixtureUI();assert(nav.toolbarHidden && [page.navigationItem.rightBarButtonItem.title isEqual:@"Select"] && ![page.toolbarItems containsObject:selectionControl(page)]);
           invoke(selectionControl(page));tap(page,2);NSMutableDictionary *expanded=[catalog()mutableCopy];NSMutableArray *groups=[expanded[@"sections"]mutableCopy];NSMutableDictionary *singles=[groups[2]mutableCopy];NSDictionary *newer=@{@"uri":uri(99),@"name":@"Newer late arrival",@"year":@2027,@"category":@"Singles",@"type":@2,@"cover_url":@""};singles[@"releases"]=@[newer,singles[@"releases"][0]];groups[2]=singles;expanded[@"sections"]=groups;expanded[@"release_count"]=@7;[page setValue:expanded forKey:@"pendingCatalog"];((void(*)(id,SEL))objc_msgSend)(page,NSSelectorFromString(@"applyPendingCatalog"));NSArray *appended=[page valueForKey:@"sections"][2][@"releases"];assert([appended[0][@"uri"]isEqual:uri(3)] && [appended[1][@"uri"]isEqual:uri(99)] && [[[page valueForKey:@"selectedReleaseURIs"]allObjects]containsObject:uri(3)]);invoke(selectionControl(page));
           assertScopedCancel(page,^{assertCoalescedRendering(page,^{assertPlaylistRowStop(page,^{invoke(page.navigationItem.leftBarButtonItem);assert(detached>=1);
assert(sessionAttaches==1);
assert(sessionExtends>=2);
assert(sessionRefreshes>=1);
assert(!observer);
assert(!playlistObserver);
assert(!itemObserver);
assert(itemDetaches>0);runArtworkCancellationTests(^{finish(@"PASS: centered multiline artist load text with spinner below, initial empty loading state, progressive Singles-first and EP-first headers keep the same height with inline counters, selection survives inserted categories and a newer late row appends after the existing row, spinner stops at first ready rows, Continue after confirmed Stop and fresh item observation on foreground, normal row start/stop, confirmed downloaded context and playlist-file releases skipped separately, downloaded releases retained for playlist selection, outer sheet retained when confirmation was already dismissed, native GetImage request size for plain images and Spotify CDN mosaic rendering without native GetImage failures, 12 playlist reloads without placeholder replacement and failed refresh preserving the prior cover, Select/Cancel and category/row selection, automatic selection exit after separate and playlist starts, native album status centering, native per-release item progress and green completion, 80 scroll callbacks without stream replacement or indicator reset, Select stays in navigation for ordinary starts; repeat selection during active batch downloads and Select returning to the navigation bar, visible Stop after returning from picker, visible Queued row state, create/search/confirm flows, artwork and observer cleanup; 100 Select cycles retain fixed ring, glyph and completed icon dimensions; scoped Cancel confirmation and top-right Select/bottom controls\n");});});});});
          });
         });
        });
        });
       });
      });
     });
    });
   });
  });
  });
 });
}
@end
@interface ArtistPickerFixtureDelegate : UIResponder <UIApplicationDelegate>@end
@implementation ArtistPickerFixtureDelegate @end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ArtistPickerFixtureDelegate.class));}}
