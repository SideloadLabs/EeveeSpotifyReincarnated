#import <Foundation/Foundation.h>
#import "PlaylistDownloads.h"
#import "PlaylistArtwork.h"
#import "WireProto.h"
#include <assert.h>
#include <stdbool.h>
bool SAPDiagnosticsEnabled(void){return true;}
void SAPPlaylistForgetInactiveMembershipForTesting(void);
static NSString *album(int n){return [NSString stringWithFormat:@"spotify:album:%022d",n];}
static NSString *track(int n){return [NSString stringWithFormat:@"spotify:track:%022d",n];}
static NSString *playlist(int n){return [NSString stringWithFormat:@"spotify:playlist:%022d",n];}
static NSData *s(unsigned n,NSString *v){return SAPProtoBytes(n,[v dataUsingEncoding:NSUTF8StringEncoding]);}
static BOOL valid(NSString *u,NSString *prefix){return [u hasPrefix:prefix] && u.length==prefix.length+22;}
BOOL SAPIsAlbumURI(NSString *u){return valid(u,@"spotify:album:");}
BOOL SAPIsPlaylistURI(NSString *u){return valid(u,@"spotify:playlist:");}
void SAPJournalNoteAction(NSString *name,NSDictionary *facts){}
static NSMutableDictionary *albumTracks,*playlistItems,*members,*nativeObservers,*itemStreams,*nativeItems;
static NSMutableArray *calls,*libraryPages;
static NSArray *submitted;
static NSDictionary *snapshot;
static NSString *createdURI;
static BOOL allowAdd,holdMetadata,holdAppend,holdCreate,uncertainCreate,ambiguousAppend,failAppend,changePlaylistDuringRead;
static NSUInteger creates,adds,saves,stops,reads,cancels,loadingReplies,nativeStarts;
static NSMutableDictionary *nativeStates;
static NSMutableSet *closedFeeds,*disabledContexts,*pendingNativeAdds,*pendingNativeStops,*heldNativeCompletions;
static NSMutableDictionary *nativeOwners,*albumAddCounts,*reservedLeases;
static NSMutableArray *nativeSubmissionOrder;
static BOOL holdNativeAdd;
static NSUInteger playlistStarts;
static BOOL holdNativeStop;
static NSUInteger forgottenIntents;
static void emitNative(NSString *uri);
static void (^heldMetadata)(void),(^heldMutation)(void);
static NSData *status(void){return SAPProtoBytes(1,SAPProtoInteger(1,200));}
static NSData *contents(NSString *uri,NSArray *all,NSUInteger start){
 NSMutableData *metadata=[s(1,uri)mutableCopy];[metadata appendData:s(2,@"Fixture playlist")];[metadata appendData:SAPProtoInteger(6,all.count)];[metadata appendData:SAPProtoInteger(17,1)];[metadata appendData:SAPProtoBytes(18,SAPProtoInteger(1,allowAdd))];
 NSMutableData *data=[SAPProtoBytes(2,SAPProtoBytes(1,metadata))mutableCopy];[data appendData:SAPProtoInteger(4,all.count)];[data appendData:SAPProtoInteger(7,changePlaylistDuringRead&&start?2:1)];
 for(NSUInteger i=start;i<MIN(start+250,all.count);i++)[data appendData:SAPProtoBytes(1,s(18,all[i]))];
 NSMutableData *out=[status()mutableCopy];[out appendData:SAPProtoBytes(2,data)];return out;
}
static NSData *libraryEntry(NSString *uri,BOOL writable,NSUInteger count){
 NSMutableData *info=[s(2,@"Saved playlist")mutableCopy];[info appendData:s(3,uri)];[info appendData:s(6,@"spotify:image:0123456789abcdef0123456789abcdef01234567")];
 NSMutableData *extra=[SAPProtoInteger(9,writable)mutableCopy];NSMutableData *kind=[SAPProtoInteger(1,4)mutableCopy];[kind appendData:SAPProtoInteger(2,count)];[extra appendData:SAPProtoBytes(12,kind)];
 NSMutableData *entry=[SAPProtoBytes(1,info)mutableCopy];[entry appendData:SAPProtoBytes(4,extra)];return SAPProtoBytes(2,entry);
}
static NSData *libraryPage(NSUInteger remaining,NSArray *entries){
 NSMutableData *out=[SAPProtoBytes(1,SAPProtoInteger(9,remaining))mutableCopy];[out appendData:SAPProtoInteger(98,200)];for(NSData *entry in entries)[out appendData:entry];return out;
}
NSArray *SAPParseArtistAlbumTrackURIs(NSData *response,NSString *uri,NSString **reason){if(![[[NSString alloc]initWithData:response encoding:NSUTF8StringEncoding]isEqual:uri])return nil;return albumTracks[uri];}
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *service,NSString *method,NSData *payload,void(^done)(NSData*,NSString*)){
 reads++;NSArray *fields=SAPProtoFields(payload);[calls addObject:@{@"service":service,@"method":method,@"payload":payload}];__block BOOL cancelled=NO;
 dispatch_block_t deliver=^{
  if(cancelled)return;
  if([method isEqual:@"GetEntity"]){NSString *uri=SAPProtoString(fields,1);done([uri dataUsingEncoding:NSUTF8StringEncoding],nil);}
  else if([method isEqual:@"Contains"]){NSString *uri=SAPProtoString(fields,3);NSMutableData *entry=[s(1,uri)mutableCopy];if([members[uri]boolValue])[entry appendData:SAPProtoInteger(2,1)];NSMutableData *reply=[SAPProtoInteger(98,200)mutableCopy];[reply appendData:SAPProtoBytes(2,entry)];done(reply,nil);}
  else if([service containsString:@"PlaylistDataService"]){if(loadingReplies){loadingReplies--;NSMutableData *loading=[status()mutableCopy];[loading appendData:SAPProtoBytes(2,SAPProtoInteger(6,1))];done(loading,nil);return;}NSString *uri=SAPProtoString(fields,1);NSArray *query=SAPProtoFields(SAPProtoData(fields,2)),*range=SAPProtoFields(SAPProtoData(query,4));assert(SAPProtoNumber(range,2,0)==250 && SAPProtoNumber(query,8,0)==1 && SAPProtoNumber(query,17,0)==1);done(contents(uri,playlistItems[uri]?:@[],SAPProtoNumber(range,1,0)),nil);}
  else {assert([method isEqual:@"All"] && [service containsString:@"YourLibraryService"]);assert(libraryPages.count);NSData *data=libraryPages.firstObject;[libraryPages removeObjectAtIndex:0];done(data,nil);}
 };
 if(holdMetadata && [method isEqual:@"GetEntity"])heldMetadata=[deliver copy];else dispatch_async(dispatch_get_main_queue(),deliver);
 return ^{if(!cancelled){cancelled=YES;cancels++;}};
}
void SAPAddAlbumToLibraryOnce(NSString *uri,void(^done)(NSData*,NSString*)){saves++;members[uri]=@YES;dispatch_async(dispatch_get_main_queue(),^{done([NSData data],nil);});}
void SAPCallPlaylistModificationOnce(BOOL root,NSData *payload,void(^done)(NSData*,NSString*)){
 NSArray *outer=SAPProtoFields(payload),*request=SAPProtoFields(SAPProtoData(outer,2));NSString *op=SAPProtoString(request,1);
 dispatch_block_t perform;
 if(root){assert([op isEqual:@"create"] && SAPProtoString(request,4).length && SAPProtoNumber(request,5,0)==1 && SAPProtoNumber(request,12,0)==1);creates++;createdURI=playlist(100+creates);playlistItems[createdURI]=[NSMutableArray array];NSMutableData *response=[SAPProtoInteger(1,1)mutableCopy];[response appendData:s(2,createdURI)];NSMutableData *reply=[status()mutableCopy];[reply appendData:SAPProtoBytes(2,response)];perform=^{done(uncertainCreate?nil:reply,uncertainCreate?@"timeout":nil);};}
 else {adds++;assert([op isEqual:@"add"] && [SAPProtoString(request,3)isEqual:@"end"]);NSString *uri=SAPProtoString(outer,1);NSMutableArray *batch=[NSMutableArray array];for(NSDictionary *f in request)if([f[@"number"]intValue]==7)[batch addObject:[[NSString alloc]initWithData:f[@"value"] encoding:NSUTF8StringEncoding]];assert(batch.count>0 && batch.count<=100);
  perform=^{if(!failAppend){NSMutableArray *items=[playlistItems[uri]mutableCopy]?:[NSMutableArray array];[items addObjectsFromArray:batch];playlistItems[uri]=items;if(nativeObservers[uri])emitNative(uri);}done(ambiguousAppend?nil:status(),ambiguousAppend?@"timeout":nil);};
 }
 if((holdAppend&&!root)||(holdCreate&&root))heldMutation=[perform copy];else dispatch_async(dispatch_get_main_queue(),perform);
}
static NSData *itemData(NSArray *uris){NSMutableData *out=[NSMutableData data];for(NSString *uri in uris){NSDictionary *state=nativeItems[uri];NSMutableData *item=[s(1,uri)mutableCopy];[item appendData:SAPProtoInteger(2,[state[@"code"]unsignedIntegerValue])];[item appendData:SAPProtoInteger(4,[state[@"percent"]unsignedIntegerValue])];[out appendData:SAPProtoBytes(1,item)];}return out;}
dispatch_block_t SAPSubscribeReadOnlyService(NSString *service,NSString *method,NSData *payload,void(^reply)(NSData*,NSString*)){
 assert([service containsString:@"offline_esperanto"] && [method isEqual:@"SubscribeItems"]);NSMutableArray *uris=[NSMutableArray array];for(NSDictionary *field in SAPProtoFields(payload))if([field[@"number"]intValue]==1)[uris addObject:[[NSString alloc]initWithData:field[@"value"] encoding:NSUTF8StringEncoding]];assert(uris.count>0&&uris.count<=256);NSString *key=NSUUID.UUID.UUIDString;itemStreams[key]=@{@"uris":uris,@"callback":[reply copy]};dispatch_async(dispatch_get_main_queue(),^{if(itemStreams[key])reply(itemData(uris),nil);});return ^{[itemStreams removeObjectForKey:key];};
}
static void emitItem(NSString *uri,NSUInteger code,NSUInteger percent){nativeItems[uri]=@{@"code":@(code),@"percent":@(percent)};for(NSDictionary *stream in [itemStreams.allValues copy])if([stream[@"uris"]containsObject:uri])((void(^)(NSData*,NSString*))stream[@"callback"])(itemData(@[uri]),nil);}
static NSArray *contextTracks(NSString *uri){return SAPIsAlbumURI(uri)?albumTracks[uri]:playlistItems[uri];}
static BOOL fullContext(NSString *uri){NSArray *tracks=contextTracks(uri);if(!tracks.count)return NO;for(NSString *trackURI in tracks)if([nativeItems[trackURI][@"code"]unsignedIntegerValue]!=3)return NO;return YES;}
static void publishNative(NSString *uri){NSDictionary *state=nativeStates[uri];for(void(^callback)(NSDictionary *) in [nativeObservers[uri]allValues])callback(@{@"album_states":@{uri:state}});}
static void emitNative(NSString *uri){
 BOOL disabled=[disabledContexts containsObject:uri],pending=[pendingNativeAdds containsObject:uri],stopping=[pendingNativeStops containsObject:uri];
 BOOL full=!disabled && ![heldNativeCompletions containsObject:uri] && fullContext(uri);
 BOOL owned=!disabled && (pending||stopping||!full);
 NSDictionary *state=@{@"owned":@(owned),@"download_submitted":@(!disabled),@"submission_pending":@(pending),@"active":@(!disabled&&(!full||pending||stopping)),@"state":full?@"downloaded":disabled?@"not_downloaded":@"partial",@"phase":stopping?@"stopping":disabled?@"idle":full?@"downloaded":@"downloading",@"stop_pending":@(stopping),@"stopping":@(stopping)};
 nativeStates[uri]=state;if(full&&!owned)[nativeOwners removeObjectForKey:uri];publishNative(uri);
}
BOOL SAPReserveArtistDownloadSessionReleases(NSArray *items,NSString **error){
 if(!reservedLeases)reservedLeases=[NSMutableDictionary dictionary];
 for(NSDictionary *item in items){assert([item[@"artist_uri"]length] && [item[@"owner_token"]length]);}
 reservedLeases[items.firstObject[@"owner_token"]]=items;return YES;
}
BOOL SAPAppendArtistDownloadSessionReleases(NSArray *items,NSString **error){
 submitted=[items copy];
 for(NSDictionary *item in items){NSString *uri=item[@"uri"],*artistURI=item[@"artist_uri"],*ownerToken=item[@"owner_token"];
  if(artistURI){NSMutableSet *owners=nativeOwners[uri];if(!owners)nativeOwners[uri]=owners=[NSMutableSet set];[owners addObject:@[artistURI,ownerToken?:@""]];}
  BOOL alreadyOwned=[nativeStates[uri][@"owned"]boolValue],alreadyFull=[nativeStates[uri][@"state"]isEqual:@"downloaded"];
  if(!alreadyOwned&&!alreadyFull){nativeStarts++;[nativeSubmissionOrder addObject:uri];if(SAPIsAlbumURI(uri))albumAddCounts[uri]=@([albumAddCounts[uri]unsignedIntegerValue]+1);else playlistStarts++;[disabledContexts removeObject:uri];if(holdNativeAdd)[pendingNativeAdds addObject:uri];}
  emitNative(uri);
 }
 return YES;
}
dispatch_block_t SAPObserveArtistDownloadSession(NSArray *items,void(^done)(NSDictionary*)){
 NSString *uri=items.firstObject[@"uri"],*token=NSUUID.UUID.UUIDString;NSMutableDictionary *callbacks=nativeObservers[uri];if(!callbacks)nativeObservers[uri]=callbacks=[NSMutableDictionary dictionary];callbacks[token]=[done copy];
 done(@{@"album_states":@{uri:nativeStates[uri]?:@{}}});
 return ^{NSMutableDictionary *live=nativeObservers[uri];[live removeObjectForKey:token];if(!live.count)[nativeObservers removeObjectForKey:uri];};
}
static void finishNativeStop(NSString *uri){[pendingNativeStops removeObject:uri];[disabledContexts addObject:uri];[nativeOwners removeObjectForKey:uri];emitNative(uri);}
static void sendNativeStop(NSString *uri){stops++;if(!holdNativeStop){finishNativeStop(uri);return;}[pendingNativeStops addObject:uri];emitNative(uri);}
void SAPStopArtistDownloadSessionRelease(NSString *uri){
 if([disabledContexts containsObject:uri])return;
 if([pendingNativeAdds containsObject:uri]){[pendingNativeStops addObject:uri];emitNative(uri);return;}
 if([pendingNativeStops containsObject:uri])return;sendNativeStop(uri);
}
BOOL SAPCancelArtistDownloadOwner(NSString *artistURI,NSString *ownerToken){
 BOOL pending=NO;[reservedLeases removeObjectForKey:ownerToken];NSArray *owner=@[artistURI,ownerToken];
 for(NSString *uri in [nativeOwners.allKeys copy]){NSMutableSet *owners=nativeOwners[uri];if(![owners containsObject:owner])continue;[owners removeObject:owner];if(!owners.count){[nativeOwners removeObjectForKey:uri];SAPStopArtistDownloadSessionRelease(uri);pending|=[nativeStates[uri][@"owned"]boolValue] && ([pendingNativeAdds containsObject:uri] || [pendingNativeStops containsObject:uri]);}}
 return pending;
}
void SAPCancelArtistDownloadSession(NSString *artistURI){
 NSMutableSet *tokens=[NSMutableSet set];for(NSSet *owners in nativeOwners.allValues)for(NSArray *owner in owners)if([owner[0]isEqual:artistURI])[tokens addObject:owner[1]];
 for(NSString *token in tokens)SAPCancelArtistDownloadOwner(artistURI,token);
}
static BOOL hasNativeOwner(NSString *uri,NSString *artistURI){for(NSArray *owner in nativeOwners[uri])if([owner[0]isEqual:artistURI])return YES;return NO;}
static void acceptNativeAdd(NSString *uri){assert([pendingNativeAdds containsObject:uri]);[pendingNativeAdds removeObject:uri];if([pendingNativeStops containsObject:uri])sendNativeStop(uri);else emitNative(uri);}
void SAPClosePlaylistDownloadFeed(NSString *uri){[closedFeeds addObject:uri];emitNative(uri);}
void SAPForgetPlaylistDownloadIntent(NSString *uri){if(![nativeStates[uri][@"owned"]boolValue])forgottenIntents++;}
static void pump(double seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];}
static void waitFor(BOOL(^test)(void)){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];while(!test() && end.timeIntervalSinceNow>0)pump(.002);assert(test());}
static BOOL active(void){return [snapshot[@"active"]boolValue];}
static NSArray *releases(int base){return @[@{@"uri":album(base),@"name":@"Album",@"category":@"Albums"},@{@"uri":album(base+1),@"name":@"Single",@"category":@"Singles"}];}
static dispatch_block_t observe(NSArray *items){return SAPObservePlaylistReleaseDownloads(items,^(NSDictionary *s){snapshot=s;});}
static void reset(void){loadingReplies=0;submitted=nil;allowAdd=YES;holdNativeAdd=holdNativeStop=NO;holdMetadata=holdAppend=holdCreate=uncertainCreate=ambiguousAppend=failAppend=changePlaylistDuringRead=NO;heldMetadata=nil;heldMutation=nil;}
static NSString *artist(int n){return [NSString stringWithFormat:@"spotify:artist:%022d",n];}
static void completeTracks(NSArray *tracks){for(NSString *uri in tracks)emitItem(uri,3,100);for(NSString *uri in [nativeObservers.allKeys copy])emitNative(uri);pump(.01);}
static NSArray *oneAlbum(int n,int count){NSMutableArray *tracks=[NSMutableArray array];for(int i=0;i<count;i++)[tracks addObject:track(n+i)];albumTracks[album(n)]=tracks;return @[@{@"uri":album(n),@"name":@"Ordered album"}];}
static NSArray *combine(NSArray *a,NSArray *b){return [a arrayByAddingObjectsFromArray:b];}
int main(void){@autoreleasepool{
 albumTracks=[NSMutableDictionary dictionary];playlistItems=[NSMutableDictionary dictionary];members=[NSMutableDictionary dictionary];nativeObservers=[NSMutableDictionary dictionary];itemStreams=[NSMutableDictionary dictionary];nativeItems=[NSMutableDictionary dictionary];calls=[NSMutableArray array];libraryPages=[NSMutableArray array];nativeStates=[NSMutableDictionary dictionary];closedFeeds=[NSMutableSet set];disabledContexts=[NSMutableSet set];pendingNativeAdds=[NSMutableSet set];pendingNativeStops=[NSMutableSet set];heldNativeCompletions=[NSMutableSet set];nativeOwners=[NSMutableDictionary dictionary];albumAddCounts=[NSMutableDictionary dictionary];nativeSubmissionOrder=[NSMutableArray array];reset();NSString *error=nil;
 NSArray *choice=combine(combine(oneAlbum(1000,5),oneAlbum(1100,3)),combine(oneAlbum(1200,2),oneAlbum(1300,1)));playlistItems[playlist(1)]=@[];__block NSDictionary *a=nil;dispatch_block_t detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(1),choice,^(NSDictionary *v){a=v;});
 NSUInteger firstPlaylistStarts=playlistStarts;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(1),choice,playlist(1),@"Ordered",&error));waitFor(^BOOL{return itemStreams.count && nativeObservers[album(1000)]!=nil;});assert([playlistItems[playlist(1)]isEqual:albumTracks[album(1000)]]);assert(!nativeObservers[playlist(1)] && playlistStarts==firstPlaylistStarts);
 completeTracks(@[track(1000),track(1001),track(1002),track(1003)]);assert([playlistItems[playlist(1)]count]==5);completeTracks(@[track(1004)]);waitFor(^BOOL{return nativeObservers[album(1100)]!=nil;});assert([playlistItems[playlist(1)]count]==8);completeTracks(albumTracks[album(1100)]);waitFor(^BOOL{return nativeObservers[album(1200)]!=nil;});assert([playlistItems[playlist(1)]count]==10);completeTracks(albumTracks[album(1200)]);waitFor(^BOOL{return nativeObservers[album(1300)]!=nil;});assert([playlistItems[playlist(1)]count]==11);assert(playlistStarts==firstPlaylistStarts);completeTracks(albumTracks[album(1300)]);waitFor(^BOOL{return ![a[@"active"]boolValue];});
 NSArray *expected=combine(combine(albumTracks[album(1000)],albumTracks[album(1100)]),combine(albumTracks[album(1200)],albumTracks[album(1300)]));assert([playlistItems[playlist(1)]isEqual:expected]);for(int releaseNumber=1000;releaseNumber<=1300;releaseNumber+=100)assert([albumAddCounts[album(releaseNumber)]unsignedIntegerValue]==1);assert(playlistStarts==firstPlaylistStarts+1);assert(([nativeSubmissionOrder isEqual:@[album(1000),album(1100),album(1200),album(1300),playlist(1)]]));assert(itemStreams.count==0);detachA();
 puts("PASS: each ordered release receives one native album registration; later releases wait for completion and the playlist is enabled once after all albums");

 reset();choice=combine(oneAlbum(2000,6),oneAlbum(2200,3));playlistItems[playlist(2)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(2),choice,^(NSDictionary *v){a=v;});assert(SAPStartPlaylistReleaseDownloadForArtist(artist(2),choice,playlist(2),@"Cancel",&error));waitFor(^BOOL{return nativeObservers[album(2000)]!=nil && itemStreams.count;});completeTracks(@[track(2000)]);NSUInteger stopsBefore=stops;SAPCancelPlaylistReleaseDownloadsForArtist(artist(2));waitFor(^BOOL{return !nativeObservers[album(2000)] && ![a[@"active"]boolValue];});assert(![a[@"can_continue"]boolValue] && [playlistItems[playlist(2)]count]==6 && stops==stopsBefore+1 && itemStreams.count==0);assert([nativeItems[track(2000)][@"code"]unsignedIntegerValue]==3 && [nativeItems[track(2001)][@"code"]unsignedIntegerValue]!=3);assert(!albumAddCounts[album(2200)] && !nativeObservers[playlist(2)]);assert(SAPContinuePlaylistReleaseDownloadsForArtist(artist(2),choice,&error));pump(.02);assert([playlistItems[playlist(2)]count]==6 && stops==stopsBefore+1);detachA();
 puts("PASS: hard Cancel stops the owned album, removes later intent and Continue, closes leases, and preserves playlist rows and cached files");

 reset();NSArray *bChoice=combine(oneAlbum(3000,4),oneAlbum(3100,3));choice=combine(oneAlbum(2300,4),oneAlbum(2400,3));playlistItems[playlist(3)]=@[];__block NSDictionary *b=nil;detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(3),choice,^(NSDictionary *v){a=v;});dispatch_block_t detachB=SAPObservePlaylistReleaseDownloadsForArtist(artist(4),bChoice,^(NSDictionary *v){b=v;});assert(SAPStartPlaylistReleaseDownloadForArtist(artist(3),choice,playlist(3),@"Shared destination",&error));waitFor(^BOOL{return nativeObservers[album(2300)]!=nil;});assert(SAPStartPlaylistReleaseDownloadForArtist(artist(4),bChoice,playlist(3),@"Shared destination",&error));pump(.01);holdNativeStop=YES;stopsBefore=stops;SAPCancelPlaylistReleaseDownloadsForArtist(artist(3));assert([b[@"active"]boolValue] && stops==stopsBefore+1);pump(.02);assert([playlistItems[playlist(3)]count]==4 && !nativeObservers[album(3000)]);finishNativeStop(album(2300));holdNativeStop=NO;waitFor(^BOOL{return nativeObservers[album(3000)]!=nil;});assert([playlistItems[playlist(3)]isEqual:combine(albumTracks[album(2300)],albumTracks[album(3000)])]);completeTracks(combine(albumTracks[album(2300)],albumTracks[album(3000)]));waitFor(^BOOL{return nativeObservers[album(3100)]!=nil;});completeTracks(albumTracks[album(3100)]);waitFor(^BOOL{return ![b[@"active"]boolValue];});assert(stops==stopsBefore+1);detachA();detachB();
 puts("PASS: a queued artist sharing a destination waits for native Stop confirmation, then continues without deleting or reordering existing rows");

 reset();choice=combine(oneAlbum(4000,4),oneAlbum(4100,3));playlistItems[playlist(4)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(5),choice,^(NSDictionary *v){a=v;});assert(SAPStartPlaylistReleaseDownloadForArtist(artist(5),choice,playlist(4),@"Stop resume",&error));waitFor(^BOOL{return nativeObservers[album(4000)]!=nil;});completeTracks(@[track(4000)]);SAPStopPlaylistReleaseDownloads(choice);waitFor(^BOOL{return [a[@"can_continue"]boolValue];});assert(SAPContinuePlaylistReleaseDownloadsForArtist(artist(5),choice,&error));waitFor(^BOOL{return nativeObservers[album(4000)]!=nil;});assert([playlistItems[playlist(4)]count]==4);completeTracks(@[track(4001),track(4002),track(4003)]);waitFor(^BOOL{return nativeObservers[album(4100)]!=nil;});assert([playlistItems[playlist(4)]count]==7);completeTracks(albumTracks[album(4100)]);waitFor(^BOOL{return ![a[@"active"]boolValue];});assert([playlistItems[playlist(4)]isEqual:combine(albumTracks[album(4000)],albumTracks[album(4100)])]);detachA();
 puts("PASS: Stop/Continue resumes native album registration after rereading playlist membership, without duplicate appends");

 reset();choice=combine(oneAlbum(5000,4),oneAlbum(5100,3));playlistItems[playlist(5)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(6),choice,^(NSDictionary *v){a=v;});holdAppend=YES;NSUInteger startsBefore=nativeStarts;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(6),choice,playlist(5),@"In flight",&error));waitFor(^BOOL{return heldMutation!=nil;});SAPCancelPlaylistReleaseDownloadsForArtist(artist(6));heldMutation();pump(.03);assert([playlistItems[playlist(5)]count]==4 && nativeStarts==startsBefore && ![a[@"active"]boolValue]);holdAppend=NO;detachA();
 puts("PASS: Cancel during an append settles its original callback without enabling album downloads or appending a later release");
 reset();choice=oneAlbum(6000,4);playlistItems[playlist(6)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(7),choice,^(NSDictionary *v){a=v;});holdMetadata=YES;NSUInteger mutations=adds;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(7),choice,playlist(6),@"Before metadata",&error));waitFor(^BOOL{return heldMetadata!=nil;});SAPCancelPlaylistReleaseDownloadsForArtist(artist(7));heldMetadata();pump(.03);assert(adds==mutations && ![a[@"active"]boolValue]);holdMetadata=NO;detachA();

 reset();choice=combine(oneAlbum(9000,2),oneAlbum(9100,4));playlistItems[playlist(8)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(9),choice,^(NSDictionary *v){a=v;});assert(SAPStartPlaylistReleaseDownloadForArtist(artist(9),choice,playlist(8),@"Cancel pending release",&error));waitFor(^BOOL{return nativeObservers[album(9000)]!=nil;});holdAppend=YES;completeTracks(albumTracks[album(9000)]);waitFor(^BOOL{return heldMutation!=nil;});stopsBefore=stops;SAPCancelPlaylistReleaseDownloadsForArtist(artist(9));heldMutation();waitFor(^BOOL{return ![a[@"active"]boolValue];});assert([playlistItems[playlist(8)]count]==6 && !albumAddCounts[album(9100)] && stops==stopsBefore && ![a[@"can_continue"]boolValue] && itemStreams.count==0);holdAppend=NO;detachA();
 puts("PASS: Cancel between releases settles only the already-sent append and never starts the canceled next album");

 reset();choice=combine(oneAlbum(7000,513),oneAlbum(8000,1));playlistItems[playlist(7)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(8),choice,^(NSDictionary *v){a=v;});mutations=adds;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(8),choice,playlist(7),@"Large album",&error));waitFor(^BOOL{return nativeObservers[album(7000)]!=nil && itemStreams.count==3;});assert(adds==mutations+6 && [playlistItems[playlist(7)]count]==513);completeTracks(albumTracks[album(7000)]);waitFor(^BOOL{return nativeObservers[album(8000)]!=nil;});assert([playlistItems[playlist(7)]count]==514);completeTracks(albumTracks[album(8000)]);waitFor(^BOOL{return ![a[@"active"]boolValue];});detachA();
 puts("PASS: large releases use bounded append chunks and item streams without interleaving another release");

 reset();choice=oneAlbum(10000,3);playlistItems[playlist(10)]=@[track(10000)];completeTracks(albumTracks[album(10000)]);[heldNativeCompletions addObject:album(10000)];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(10),choice,^(NSDictionary *v){a=v;});firstPlaylistStarts=playlistStarts;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(10),choice,playlist(10),@"Cached files",&error));waitFor(^BOOL{return nativeObservers[album(10000)]!=nil && itemStreams.count;});pump(.02);assert([a[@"active"]boolValue] && [albumAddCounts[album(10000)]unsignedIntegerValue]==1 && playlistStarts==firstPlaylistStarts);assert([playlistItems[playlist(10)]isEqual:albumTracks[album(10000)]]);[heldNativeCompletions removeObject:album(10000)];emitNative(album(10000));waitFor(^BOOL{return ![a[@"active"]boolValue];});assert(playlistStarts==firstPlaylistStarts+1);detachA();
 puts("PASS: cached files alone cannot complete a release; native album registration is still requested and confirmed, while existing playlist tracks stay deduplicated");

 reset();choice=oneAlbum(11000,2);bChoice=oneAlbum(11100,2);playlistItems[playlist(11)]=@[];playlistItems[playlist(12)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(11),choice,^(NSDictionary *v){a=v;});detachB=SAPObservePlaylistReleaseDownloadsForArtist(artist(12),bChoice,^(NSDictionary *v){b=v;});firstPlaylistStarts=playlistStarts;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(11),choice,playlist(11),@"Artist A",&error));assert(SAPStartPlaylistReleaseDownloadForArtist(artist(12),bChoice,playlist(12),@"Artist B",&error));waitFor(^BOOL{return nativeObservers[album(11000)]!=nil && nativeObservers[album(11100)]!=nil;});assert(playlistStarts==firstPlaylistStarts);completeTracks(combine(albumTracks[album(11000)],albumTracks[album(11100)]));waitFor(^BOOL{return ![a[@"active"]boolValue] && ![b[@"active"]boolValue];});assert(playlistStarts==firstPlaylistStarts+2);detachA();detachB();
 puts("PASS: two artists with different playlists register their current albums concurrently without reserving both slots for playlist feeds");

 reset();choice=combine(oneAlbum(12000,2),oneAlbum(12100,2));playlistItems[playlist(13)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(13),choice,^(NSDictionary *v){a=v;});holdNativeAdd=YES;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(13),choice,playlist(13),@"Pending Add",&error));waitFor(^BOOL{return nativeObservers[album(12000)]!=nil;});stopsBefore=stops;SAPCancelPlaylistReleaseDownloadsForArtist(artist(13));pump(.01);assert(stops==stopsBefore && nativeObservers[album(12000)]!=nil && [pendingNativeStops containsObject:album(12000)]);acceptNativeAdd(album(12000));waitFor(^BOOL{return ![a[@"active"]boolValue] && !nativeObservers[album(12000)];});assert(stops==stopsBefore+1 && !albumAddCounts[album(12100)] && [playlistItems[playlist(13)]count]==2 && ![a[@"can_continue"]boolValue]);assert([albumAddCounts[album(12000)]unsignedIntegerValue]==1);detachA();holdNativeAdd=NO;
 puts("PASS: Cancel waits for the original pending album Add ACK, then stops once without replaying Add or keeping Continue intent");

 reset();choice=oneAlbum(13000,2);playlistItems[playlist(14)]=@[];playlistItems[playlist(15)]=@[];detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(14),choice,^(NSDictionary *v){a=v;});detachB=SAPObservePlaylistReleaseDownloadsForArtist(artist(15),choice,^(NSDictionary *v){b=v;});assert(SAPStartPlaylistReleaseDownloadForArtist(artist(14),choice,playlist(14),@"Shared album A",&error));assert(SAPStartPlaylistReleaseDownloadForArtist(artist(15),choice,playlist(15),@"Shared album B",&error));waitFor(^BOOL{return [nativeObservers[album(13000)]count]==2;});stopsBefore=stops;SAPCancelPlaylistReleaseDownloadsForArtist(artist(14));waitFor(^BOOL{return ![a[@"active"]boolValue];});assert([b[@"active"]boolValue] && stops==stopsBefore && hasNativeOwner(album(13000),artist(15)) && !hasNativeOwner(album(13000),artist(14)));completeTracks(albumTracks[album(13000)]);waitFor(^BOOL{return ![b[@"active"]boolValue];});assert([albumAddCounts[album(13000)]unsignedIntegerValue]==1 && ![a[@"can_continue"]boolValue]);detachA();detachB();
 puts("PASS: canceling one artist detaches only its shared album ownership, preserving the other artist and one native registration");
 reset();choice=oneAlbum(14000,3);detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(16),choice,^(NSDictionary *v){a=v;});NSUInteger createsBefore=creates;firstPlaylistStarts=playlistStarts;assert(SAPStartPlaylistReleaseDownloadForArtist(artist(16),choice,nil,@"New release playlist",&error));waitFor(^BOOL{return nativeObservers[album(14000)]!=nil;});NSString *newPlaylist=[createdURI copy];assert(creates==createsBefore+1 && [playlistItems[newPlaylist]isEqual:albumTracks[album(14000)]] && playlistStarts==firstPlaylistStarts);completeTracks(albumTracks[album(14000)]);waitFor(^BOOL{return ![a[@"active"]boolValue];});assert([albumAddCounts[album(14000)]unsignedIntegerValue]==1 && playlistStarts==firstPlaylistStarts+1 && creates==createsBefore+1);detachA();
 puts("PASS: a newly created playlist follows the same native album registration and final playlist enabling path without repeating creation");
 assert(itemStreams.count==0 && nativeObservers.count==0);
 // A native Stop followed by a native restart remains observable. Full item
 // totals alone cannot advance; the later native completion does, without Add replay.
 reset();choice=combine(oneAlbum(15000,2),oneAlbum(15100,1));playlistItems[playlist(16)]=@[];
 detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(17),choice,^(NSDictionary *v){a=v;});
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(17),choice,playlist(16),@"Native restart",&error));
 assert([[[reservedLeases allValues]lastObject]count]==2);
 waitFor(^BOOL{return nativeObservers[album(15000)]!=nil;});
 [heldNativeCompletions addObject:album(15000)];completeTracks(albumTracks[album(15000)]);
 nativeStates[album(15000)]=@{@"state":@"not_downloaded",@"active":@NO,@"owned":@NO,@"native_cancelled":@YES};publishNative(album(15000));
 assert([a[@"active"]boolValue] && !albumAddCounts[album(15100)]);
 assert([[[a[@"jobs"]lastObject]objectForKey:@"message"]containsString:@"Stopped in Spotify"]);
 [heldNativeCompletions removeObject:album(15000)];emitNative(album(15000));
 waitFor(^BOOL{return nativeObservers[album(15100)]!=nil;});
 assert([albumAddCounts[album(15000)]unsignedIntegerValue]==1);
 completeTracks(albumTracks[album(15100)]);waitFor(^BOOL{return ![a[@"active"]boolValue];});
 assert(!reservedLeases.count);detachA();
 puts("PASS: full playlist batch is reserved on acceptance and released on completion; native Stop and restart are observed without replay, preserving later release order");

 // A row Stop is restricted to that artist's matching tasks, even when another
 // artist owns the same native album and the first artist has another queued job.
 reset();NSArray *shared=oneAlbum(16000,2),*aOnly=oneAlbum(16100,1),*bOnly=oneAlbum(16200,1);
 choice=combine(shared,aOnly);bChoice=combine(shared,bOnly);playlistItems[playlist(17)]=@[];playlistItems[playlist(18)]=@[];
 detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(18),choice,^(NSDictionary *v){a=v;});
 detachB=SAPObservePlaylistReleaseDownloadsForArtist(artist(19),bChoice,^(NSDictionary *v){b=v;});
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(18),choice,playlist(17),@"Shared release A",&error));
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(19),bChoice,playlist(18),@"Shared release B",&error));
 waitFor(^BOOL{return [nativeObservers[album(16000)]count]==2;});
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(18),aOnly,playlist(17),@"Queued A",&error));
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(19),shared,playlist(18),@"Queued B",&error));
 assert([[a[@"jobs"]lastObject][@"queued"]boolValue] && [[b[@"jobs"]lastObject][@"queued"]boolValue]);
 stopsBefore=stops;SAPStopPlaylistReleaseDownloadsForArtist(artist(18),@[]);
 assert(![a[@"can_continue"]boolValue] && [a[@"active"]boolValue] && stops==stopsBefore);
 SAPStopPlaylistReleaseDownloadsForArtist(artist(18),shared);
 waitFor(^BOOL{return nativeObservers[album(16100)]!=nil;});
 assert([a[@"can_continue"]boolValue] && [a[@"active"]boolValue]);
 assert([b[@"active"]boolValue] && ![b[@"can_continue"]boolValue] && [[b[@"jobs"]lastObject][@"queued"]boolValue]);
 assert(stops==stopsBefore && hasNativeOwner(album(16000),artist(19)) && !hasNativeOwner(album(16000),artist(18)));
 assert([albumAddCounts[album(16000)]unsignedIntegerValue]==1 && [nativeObservers[album(16000)]count]==1);
 SAPStopPlaylistReleaseDownloadsForArtist(artist(18),nil);
 waitFor(^BOOL{return ![a[@"active"]boolValue];});
 assert([a[@"can_continue"]boolValue] && [b[@"active"]boolValue] && ![b[@"can_continue"]boolValue]);
 assert(stops==stopsBefore+1 && hasNativeOwner(album(16000),artist(19)));
 assert(SAPContinuePlaylistReleaseDownloadsForArtist(artist(18),choice,&error));
 waitFor(^BOOL{return [nativeObservers[album(16000)]count]==2;});
 assert([[a[@"jobs"]lastObject][@"queued"]boolValue] && [[b[@"jobs"]lastObject][@"queued"]boolValue]);
 completeTracks(combine(combine(albumTracks[album(16000)],albumTracks[album(16100)]),albumTracks[album(16200)]));
 waitFor(^BOOL{return ![a[@"active"]boolValue] && ![b[@"active"]boolValue];});
 assert([playlistItems[playlist(17)]isEqual:combine(albumTracks[album(16000)],albumTracks[album(16100)])]);
 assert([playlistItems[playlist(18)]isEqual:combine(albumTracks[album(16000)],albumTracks[album(16200)])]);
 assert([albumAddCounts[album(16000)]unsignedIntegerValue]==1 && ![a[@"can_continue"]boolValue]);detachA();detachB();
 puts("PASS: artist row Stop preserves unrelated tasks and shared native album ownership; Stop All affects only that artist, and both same-playlist queues finish after Continue without duplicate tracks");

 // Queued tasks sharing one destination also retain their separate artist scope.
 reset();choice=combine(oneAlbum(17000,2),oneAlbum(17100,1));bChoice=choice;playlistItems[playlist(19)]=@[];
 detachA=SAPObservePlaylistReleaseDownloadsForArtist(artist(20),choice,^(NSDictionary *v){a=v;});
 detachB=SAPObservePlaylistReleaseDownloadsForArtist(artist(21),bChoice,^(NSDictionary *v){b=v;});
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(20),choice,playlist(19),@"Same target A",&error));
 waitFor(^BOOL{return nativeObservers[album(17000)]!=nil;});
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(20),choice,playlist(19),@"Queued target A",&error));
 assert(SAPStartPlaylistReleaseDownloadForArtist(artist(21),bChoice,playlist(19),@"Queued target B",&error));
 assert([[a[@"jobs"]lastObject][@"queued"]boolValue] && [[b[@"jobs"]lastObject][@"queued"]boolValue]);
 SAPStopPlaylistReleaseDownloadsForArtist(artist(20),nil);
 assert(![a[@"active"]boolValue] && [a[@"can_continue"]boolValue]);
 assert([b[@"active"]boolValue] && [[b[@"jobs"]lastObject][@"queued"]boolValue] && ![b[@"can_continue"]boolValue]);
 waitFor(^BOOL{return hasNativeOwner(album(17000),artist(21));});
 assert(SAPContinuePlaylistReleaseDownloadsForArtist(artist(20),choice,&error));
 assert([a[@"active"]boolValue] && [[a[@"jobs"]firstObject][@"queued"]boolValue] && [[a[@"jobs"]lastObject][@"queued"]boolValue]);
 completeTracks(combine(albumTracks[album(17000)],albumTracks[album(17100)]));
 waitFor(^BOOL{return ![a[@"active"]boolValue] && ![b[@"active"]boolValue];});
 assert([playlistItems[playlist(19)]isEqual:combine(albumTracks[album(17000)],albumTracks[album(17100)])]);detachA();detachB();
 assert(itemStreams.count==0 && nativeObservers.count==0 && !reservedLeases.count);
 puts("PASS: Stop All stops active and queued tasks only for artist A; artist B's queued task survives on the same playlist and Continue A resumes both accepted tasks in order");
 return 0;
}}
