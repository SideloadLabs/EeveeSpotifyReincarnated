#import <Foundation/Foundation.h>
#import "OfflineLibraryDelete.h"
#import "WireProto.h"
#import "TrackDownload.h"
#import "DiagnosticTrace.h"
#include <assert.h>
static BOOL tracing;
static uint64_t traceGeneration=1;
static NSUInteger traceBegins,eventsBeforeReset;
static NSMutableArray *traceEvents;
bool SAPTraceIsActive(void){return tracing;}
uint64_t SAPTraceGeneration(void){return traceGeneration;}
SAPTraceID SAPTraceBegin(NSString *kind,NSString *source,NSDictionary *facts){assert(tracing);traceBegins++;return 100+traceBegins;}
void SAPTraceEventAtGeneration(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts,uint64_t generation){
 if(!tracing||generation!=traceGeneration)return;
 assert(operation==100+traceBegins);[traceEvents addObject:@{@"stage":@(stage),@"facts":facts,@"operation":@(operation)}];
}
static NSDictionary *traceEvent(NSString *stage){for(NSDictionary *event in traceEvents)if([event[@"stage"]isEqual:stage])return event[@"facts"];return nil;}
static NSData *join(NSArray *values){NSMutableData *d=NSMutableData.data;for(NSData *v in values)[d appendData:v];return d;}
static NSData *text(unsigned n,NSString *s){return SAPProtoBytes(n,[s dataUsingEncoding:NSUTF8StringEncoding]);}
static NSString *uri(NSUInteger n,NSString *kind){const char *a="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";char s[23];memset(s,'0',22);s[22]=0;for(int i=21;n;i--){s[i]=a[n%62];n/=62;}return [NSString stringWithFormat:@"spotify:%@:%s",kind,s];}
static NSData *gid(NSUInteger n){uint8_t b[16]={0};b[14]=n>>8;b[15]=n;return [NSData dataWithBytes:b length:16];}
static NSData *item(NSString *u,NSUInteger s){return join(@[text(1,u),SAPProtoInteger(2,s)]);}
static NSUInteger mode,mutations,resetAlbum,resetPlaylist,trackRemoves,libraryRemoves,cancelReads,reads,completions;
static NSProgress *cancelDuringSkips;static NSUInteger readsAtCancel;
static BOOL albumHeld,playlistHeld;static NSMutableDictionary *states,*saved;static NSMutableArray *pending;static NSMutableSet *removedLibrary;
static void setUp(NSUInteger m){mode=m;mutations=resetAlbum=resetPlaylist=trackRemoves=libraryRemoves=cancelReads=reads=completions=0;traceBegins=0;traceEvents=NSMutableArray.array;albumHeld=(m==0||m==1||m==7||m==13||m>=20);playlistHeld=(m==2||m==3||m==14);states=[@{uri(1,@"track"):@3,uri(2,@"track"):@3}mutableCopy];saved=[@{uri(1,@"track"):@YES,uri(2,@"track"):@YES,uri(20,@"album"):@YES}mutableCopy];pending=NSMutableArray.array;removedLibrary=NSMutableSet.set;}
static void clearUnheld(void){if(!albumHeld&&!playlistHeld)for(NSString *u in states.allKeys)states[u]=@0;}
static NSData *metadata(void){
 NSMutableArray *tracks=NSMutableArray.array;
 for(NSUInteger n=1;n<=(mode==33?1:2);n++){
  NSData *track;
  if(mode>=25){
   track=SAPProtoBytes(1,mode==26?[NSData dataWithBytes:(uint8_t[]){1} length:1]:gid(mode==28?1:mode==29&&n==2?3:n));
   if(mode==27)track=join(@[track,text(36,uri(999,@"track"))]);
   if(mode==30)track=SAPProtoInteger(1,n);
   if(mode==31)track=join(@[track,SAPProtoBytes(1,gid(n))]);
  }else track=join(@[text(36,uri(n,@"track")),text(2,@"Song"),SAPProtoInteger(5,n),SAPProtoInteger(7,mode==20?0:1000)]);
  [tracks addObject:mode==32?SAPProtoInteger(3,1):SAPProtoBytes(3,track)];
 }
 NSData *album=SAPProtoBytes(3,join(@[SAPProtoBytes(1,gid(mode==7?999:20)),text(2,mode==23?@"":@"Album"),SAPProtoBytes(11,join(tracks))]));
 return SAPProtoBytes(1,mode==24?join(@[SAPProtoInteger(1,14),album]):album);
}
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *s,NSString *method,NSData *payload,void(^reply)(NSData *,NSString *)){
 assert(NSThread.isMainThread);reads++;NSArray *fields=SAPProtoFields(payload);NSData *response=nil;NSString *error=nil;
 if([method isEqual:@"GetContexts"]){
  assert(SAPProtoNumber(SAPProtoFields(SAPProtoData(fields,1)),1,0)==1);NSMutableData *d=NSMutableData.data;
  for(NSString *kind in @[@"album",@"playlist"]){BOOL held=[kind isEqual:@"album"]?albumHeld:playlistHeld;if(!held)continue;NSString *u=uri(20,kind);
   [d appendData:SAPProtoBytes(1,join(@[SAPProtoBytes(1,item(u,mode==34?4:mode==35?2:mode==36?5:3)),SAPProtoBytes(2,item(uri(1,@"track"),3)),(mode==33?NSData.data:SAPProtoBytes(2,item(uri(2,@"track"),3)))]))];}response=d;
  if(mode==19){NSMutableData *many=NSMutableData.data;for(NSUInteger n=1;n<=300;n++)[many appendData:SAPProtoBytes(1,join(@[SAPProtoBytes(1,item(uri(1000+n,@"album"),3)),SAPProtoBytes(2,item(uri(n,@"track"),3)),SAPProtoBytes(2,item(uri(50000,@"track"),3))]))];response=many;}
  if(mode==4)response=[NSData dataWithBytes:(uint8_t[]){0x0a,0xff} length:2];
 }else if([method isEqual:@"GetItems"]){
  assert(fields.count<=128);NSMutableData *d=NSMutableData.data;for(NSDictionary *f in fields){NSString *u=[[NSString alloc]initWithData:f[@"value"]encoding:NSUTF8StringEncoding];assert(f[@"number"]&&[f[@"number"]intValue]==1);if(mode==5)continue;
   NSUInteger state=mode==9&&mutations?1:[states[u]unsignedIntegerValue];[d appendData:SAPProtoBytes(1,item(u,state))];}response=d;
 }else if([method isEqual:@"Contains"]){
  assert([s isEqual:@"spotify.your_library_esperanto.proto.YourLibraryService"]&&fields.count<=64);NSMutableData *d=[SAPProtoInteger(98,200)mutableCopy];
  for(NSDictionary *f in fields){assert([f[@"number"]intValue]==3);NSString *u=[[NSString alloc]initWithData:f[@"value"]encoding:NSUTF8StringEncoding];[d appendData:SAPProtoBytes(2,join(@[text(1,u),SAPProtoInteger(2,[saved[u]boolValue])]))];}response=d;
  if(mode==11)response=SAPProtoInteger(98,200);
 }else {assert([method isEqual:@"GetEntity"]);response=metadata();}
 __block BOOL cancelled=NO;dispatch_block_t deliver=^{if((mode==21||mode==22)&&[method isEqual:@"GetEntity"]){eventsBeforeReset=traceEvents.count;traceGeneration++;if(mode==21)tracing=NO;}reply(response,error);if(mode==19&&[method isEqual:@"Contains"]&&[SAPProtoString(fields,3)isEqual:uri(1300,@"album")]){readsAtCancel=reads;dispatch_async(dispatch_get_main_queue(),^{[cancelDuringSkips cancel];});}};
 if(mode==10)[pending addObject:[deliver copy]];else dispatch_async(dispatch_get_main_queue(),deliver);
 return ^{if(!cancelled){cancelled=YES;cancelReads++;}};
}
void SAPInvokeServiceOnce(NSString *service,NSString *method,NSData *payload,void(^reply)(NSData *,NSString *,SAPCommandInvocationDisposition)){
 assert([service isEqual:@"spotify.collection_esperanto.proto.CollectionService"]&&[method isEqual:@"Remove"]);mutations++;libraryRemoves++;
 for(NSDictionary *f in SAPProtoFields(payload)){assert([f[@"number"]intValue]==2);NSString *u=SAPProtoString(SAPProtoFields(f[@"value"]),1);assert(![u hasPrefix:@"spotify:playlist:"]);[removedLibrary addObject:u];if(mode!=6&&!(mode==13&&[u hasPrefix:@"spotify:album:"]))saved[u]=@NO;}
 dispatch_async(dispatch_get_main_queue(),^{reply(NSData.data,mode==8?@"timeout":nil,SAPCommandInvoked);});
}
void SAPCallOfflineCommandOnceWithDisposition(NSString *method,NSData *payload,void(^reply)(NSData *,NSString *,SAPCommandInvocationDisposition)){
 assert([method isEqual:@"RemoveDownload"]);NSArray *f=SAPProtoFields(payload);assert(f.count==1);NSString *u=SAPProtoString(f,2);assert([u hasPrefix:@"spotify:track:"]);mutations++;trackRemoves++;
 if(mode!=6&&!albumHeld&&!playlistHeld)states[u]=@0;if(mode==18)[pending addObject:[^{reply(NSData.data,nil,SAPCommandInvoked);}copy]];else dispatch_async(dispatch_get_main_queue(),^{reply(NSData.data,mode==8?@"timeout":nil,SAPCommandInvoked);});
}
void SAPResetEntityOffline(NSString *u,void(^reply)(BOOL,NSString *)){assert([u isEqual:uri(20,@"album")]);mutations++;resetAlbum++;albumHeld=NO;clearUnheld();dispatch_async(dispatch_get_main_queue(),^{reply(YES,nil);});}
void SAPSetPlaylistOfflineOnceWithDisposition(NSString *u,BOOL enabled,void(^reply)(NSData *,NSString *,SAPCommandInvocationDisposition)){assert([u isEqual:uri(20,@"playlist")]&&!enabled);mutations++;resetPlaylist++;playlistHeld=NO;clearUnheld();dispatch_async(dispatch_get_main_queue(),^{reply(NSData.data,nil,SAPCommandInvoked);});}
dispatch_block_t SAPFetchPlaylistContents(NSString *u,void(^reply)(NSDictionary *,NSString *)){assert([u isEqual:uri(20,@"playlist")]);dispatch_async(dispatch_get_main_queue(),^{reply(mode==14?@{@"items":@[uri(1,@"track"),uri(2,@"track"),uri(3,@"track")],@"total":@3}:@{@"items":@[uri(1,@"track"),uri(2,@"track")],@"total":@2},nil);});return ^{};}
static NSArray *rows(BOOL full,BOOL album){NSMutableArray *a=NSMutableArray.array;for(NSUInteger n=1;n<=(full?2:1);n++){NSMutableDictionary *r=[@{@"uri":uri(n,@"track"),@"name":@"Song"}mutableCopy];if(album)r[@"album_uri"]=uri(20,@"album");[a addObject:r];}return a;}
static void waitFor(BOOL(^condition)(void)){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:12];while(!condition()&&end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];assert(condition());}
static NSArray *run(NSArray *selection,NSString **failure){__block NSArray *results=nil;__block NSString *error=nil;__block BOOL done=NO,returned=NO;NSProgress *p=SAPDeleteOfflineLibrarySelection(selection,^(NSDictionary *e){assert(returned&&NSThread.isMainThread);},^(NSArray *r,NSString *e){assert(returned&&NSThread.isMainThread);completions++;results=r;error=e;done=YES;});assert(p);returned=YES;waitFor(^{return done;});assert(completions==1);if(failure)*failure=error;return results;}
int main(void){@autoreleasepool{
 NSString *error=nil;NSArray *r;
 tracing=NO;setUp(0);r=run(rows(YES,YES),&error);assert(!error&&traceBegins==0&&traceEvents.count==0);puts("PASS diagnostics off creates no deletion trace operation or records");
 tracing=YES;setUp(0);r=run(rows(YES,YES),&error);assert(!error&&traceBegins==1&&traceEvent(@"selection")&&traceEvent(@"context_members")&&[traceEvent(@"album_metadata")[@"accepted"]boolValue]&&traceEvent(@"command_reply")&&traceEvent(@"verified_items")&&traceEvent(@"finished"));assert(resetAlbum==1&&trackRemoves==0&&libraryRemoves==2);puts("PASS correlated deletion trace contains selection, holders, proof, command and verified results without changing commands");
 setUp(7);run(rows(YES,YES),&error);NSDictionary *proof=traceEvent(@"album_metadata");assert([proof[@"reason"]isEqual:@"album_identity_mismatch"]&&[proof[@"expected_uri"]isEqual:uri(20,@"album")]&&[proof[@"observed_uri"]isEqual:uri(999,@"album")]);puts("PASS rejected album identity evidence reports exact expected and native identities");
 // A native GetEntity album contains GID-only track references, not display rows.
 setUp(25);r=run(rows(YES,YES),&error);assert(!error&&resetAlbum==1&&trackRemoves==0&&[removedLibrary containsObject:uri(20,@"album")]);for(NSDictionary *v in r)assert([v[@"offline_removed"]boolValue]&&[v[@"library_removed"]boolValue]);puts("PASS GID-only native album membership releases a wholly selected downloaded album");
 setUp(33);r=run(rows(NO,YES),&error);assert(!error&&resetAlbum==1&&[r[0][@"offline_removed"]boolValue]);puts("PASS GID-only single-release membership releases the selected single");
 for(NSUInteger m=26;m<=32;m++){setUp(m);r=run(rows(YES,YES),&error);assert(error.length&&resetAlbum==0&&![removedLibrary containsObject:uri(20,@"album")]);}puts("PASS malformed, conflicting, duplicate or unselected native members cannot authorize album removal");
 setUp(25);r=run(rows(NO,YES),&error);assert(error.length&&resetAlbum==0&&![removedLibrary containsObject:uri(20,@"album")]&&[saved[uri(2,@"track")]boolValue]);puts("PASS GID-only partial selection preserves downloaded album and other tracks");
 setUp(20);run(rows(YES,YES),&error);assert(!error&&resetAlbum==1&&[traceEvent(@"album_metadata")[@"accepted"]boolValue]);puts("PASS deletion membership does not require display duration");
 setUp(23);run(rows(YES,YES),&error);assert(!error&&resetAlbum==1&&![traceEvent(@"album_metadata")[@"display_album_name_present"]boolValue]);puts("PASS deletion membership does not require display album name");
 setUp(24);run(rows(YES,YES),&error);assert([traceEvent(@"album_metadata")[@"reason"]isEqual:@"native_metadata_error"]&&[traceEvent(@"album_metadata")[@"native_error"]isEqual:@7]&&[traceEvent(@"album_metadata")[@"native_error_wire_value"]isEqual:@14]&&resetAlbum==0);puts("PASS native sint32 metadata error blocks album reset");
 for(NSUInteger m=21;m<=22;m++){tracing=YES;setUp(m);run(rows(YES,YES),&error);assert(!error&&traceEvents.count==eventsBeforeReset);}tracing=NO;puts("PASS disabled/reset diagnostics rejects subsequent observations from old operation");
 setUp(0);r=run(rows(YES,YES),&error);assert(!error&&r.count==2&&resetAlbum==1&&[removedLibrary containsObject:uri(20,@"album")]);for(NSDictionary *v in r)assert([v[@"offline_removed"]boolValue]&&[v[@"library_removed"]boolValue]);puts("PASS full album policies and saved entries removed only after full metadata proof");
 setUp(1);r=run(rows(NO,YES),&error);assert(resetAlbum==0&&resetPlaylist==0&&trackRemoves==1&&![removedLibrary containsObject:uri(20,@"album")]&&![r[0][@"offline_removed"]boolValue]&&[r[0][@"library_removed"]boolValue]&&[saved[uri(2,@"track")]boolValue]);puts("PASS partial album retained, unrelated tracks and saved album untouched");
 setUp(2);r=run(rows(YES,NO),&error);assert(resetPlaylist==1&&r.count==2);for(NSDictionary *v in r)assert([v[@"offline_removed"]boolValue]);puts("PASS full playlist policy cleared without unfollowing playlist");
 setUp(3);r=run(rows(NO,NO),&error);assert(resetPlaylist==0&&trackRemoves==1&&![r[0][@"offline_removed"]boolValue]);puts("PASS partial playlist preserves other music");
 for(NSUInteger m=4;m<=5;m++){setUp(m);r=run(rows(NO,NO),&error);assert(error.length&&mutations==0);}setUp(11);r=run(rows(NO,NO),&error);assert(error.length&&mutations==0);setUp(0);r=run(@[@{@"uri":@"bad"}],&error);assert(error.length&&mutations==0);puts("PASS malformed/missing baselines and invalid selection fail closed");
 setUp(6);r=run(rows(NO,NO),&error);assert(trackRemoves==1&&libraryRemoves==1&&![r[0][@"offline_removed"]boolValue]&&![r[0][@"library_removed"]boolValue]);puts("PASS ACK without fresh effect never succeeds");
 setUp(8);r=run(rows(NO,NO),&error);assert(!error&&trackRemoves==1&&libraryRemoves==1&&[r[0][@"offline_removed"]boolValue]&&[r[0][@"library_removed"]boolValue]);puts("PASS timeout followed by actual verified effect succeeds without replay");
 setUp(7);r=run(rows(YES,YES),&error);assert(resetAlbum==0&&![removedLibrary containsObject:uri(20,@"album")]);puts("PASS foreign album metadata never authorizes broad removal");
 setUp(13);r=run(rows(YES,NO),&error);assert(error.length&&resetAlbum==1);for(NSDictionary *v in r)assert([v[@"offline_removed"]boolValue]&&![v[@"library_removed"]boolValue]);puts("PASS retained wholly selected saved album propagates to every member even without row album metadata");
 setUp(9);r=run(rows(NO,NO),&error);assert(![r[0][@"offline_removed"]boolValue]);puts("PASS Item.ERROR1 is never NOT_DOWNLOADED0");
 setUp(0);__block BOOL immediateDone=NO;__block NSArray *immediateResults=nil;NSProgress *immediate=SAPDeleteOfflineLibrarySelection(rows(YES,YES),nil,^(NSArray *v,NSString *e){assert(e.length);immediateResults=v;immediateDone=YES;completions++;});[immediate cancel];waitFor(^{return immediateDone;});assert(immediateResults.count==2&&mutations==0&&reads==0&&completions==1);for(NSDictionary *v in immediateResults)assert(![v[@"offline_removed"]boolValue]&&![v[@"library_removed"]boolValue]);puts("PASS immediate cancellation returns all selected rows as unverified");
 setUp(14);r=run(rows(YES,NO),&error);assert(resetPlaylist==0&&trackRemoves==2);for(NSDictionary *v in r)assert(![v[@"offline_removed"]boolValue]);puts("PASS freshly read playlist unselected member blocks broad reset");
 setUp(17);NSMutableArray *many=NSMutableArray.array;for(NSUInteger n=1;n<=129;n++)[many addObject:@{@"uri":uri(n,@"track"),@"name":@"Song"}];[many addObject:many[0]];r=run(many,&error);assert(r.count==129&&!error&&trackRemoves==2);puts("PASS 129 selected identities batch at native limits and duplicate rows deduplicate");
 setUp(18);__block BOOL submittedDone=NO;NSProgress *submitted=SAPDeleteOfflineLibrarySelection(rows(NO,NO),nil,^(NSArray *v,NSString *e){assert(e.length&&v.count==1&&![v[0][@"offline_removed"]boolValue]);submittedDone=YES;completions++;});waitFor(^{return (BOOL)(trackRemoves>0);});[submitted cancel];waitFor(^{return submittedDone;});for(dispatch_block_t late in pending)late();[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];assert(trackRemoves==1&&libraryRemoves==0&&completions==1);puts("PASS cancellation after submitted mutation never submits saved removal or replays late command");
 setUp(0);__block BOOL snapshotDone=NO;__block NSArray *snapshotResults=nil;NSMutableDictionary *mutableRow=[rows(NO,NO)[0]mutableCopy];SAPDeleteOfflineLibrarySelection(@[mutableRow],nil,^(NSArray *v,NSString *e){snapshotResults=v;snapshotDone=YES;});mutableRow[@"uri"]=uri(2,@"track");waitFor(^{return snapshotDone;});assert([snapshotResults[0][@"uri"]isEqual:uri(1,@"track")]);puts("PASS caller mutation after entry cannot change confirmed selection");
 setUp(19);NSMutableArray *partials=NSMutableArray.array;for(NSUInteger n=1;n<=300;n++)[partials addObject:@{@"uri":uri(n,@"track"),@"album_uri":uri(1000+n,@"album")}];__block BOOL skipsDone=NO;cancelDuringSkips=SAPDeleteOfflineLibrarySelection(partials,nil,^(NSArray *v,NSString *e){assert(e.length&&v.count==300);skipsDone=YES;completions++;});waitFor(^{return skipsDone;});assert(reads==readsAtCancel&&mutations==0&&completions==1);cancelDuringSkips=nil;puts("PASS many preserved contexts yield to cancellation before any new target command/read");
 for(NSUInteger m=34;m<=36;m++){tracing=YES;setUp(m);r=run(rows(YES,YES),&error);assert([error isEqual:SAPOfflineLibraryDeleteBusyError]&&r.count==0&&mutations==0&&trackRemoves==0&&libraryRemoves==0&&resetAlbum==0&&traceEvent(@"blocked_active_download")&&[traceEvent(@"finished")[@"blocked_by_active_download"]boolValue]);}tracing=NO;puts("PASS a still-downloading album blocks deletion before any command and reports one short error");
 setUp(10);__block BOOL done=NO;NSProgress *p=SAPDeleteOfflineLibrarySelection(rows(NO,NO),nil,^(NSArray *v,NSString *e){assert(e.length);done=YES;completions++;});waitFor(^{return (BOOL)(pending.count>0);});[p cancel];waitFor(^{return done;});for(dispatch_block_t late in pending)late();[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];assert(mutations==0&&cancelReads==1&&completions==1);puts("PASS cancellation cancels owned read, late callbacks ignored, completes exactly once");
 }return 0;}

void SAPCallReadOnlyService(NSString *s,NSString *m,NSData *p,void(^c)(NSData *,NSString *)){SAPCallReadOnlyServiceCancellable(s,m,p,c);}
