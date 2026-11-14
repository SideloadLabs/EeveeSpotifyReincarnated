#import <Foundation/Foundation.h>
#import "OfflineLibraryCatalog.h"
#import "WireProto.h"
#include <assert.h>
#import "DiagnosticTrace.h"
bool SAPTraceIsActive(void){return true;}
void SAPTraceEvent(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts){assert([facts[@"unfiltered_contexts"]boolValue]);assert([facts[@"context_count"]unsignedIntegerValue]<=1);}
static NSData *join(NSArray *a){NSMutableData *d=NSMutableData.data;for(NSData *v in a)[d appendData:v];return d;}
static NSData *text(unsigned n,NSString *s){return SAPProtoBytes(n,[s dataUsingEncoding:NSUTF8StringEncoding]);}
static NSData *gid(NSUInteger n){uint8_t b[16]={0};b[14]=n>>8;b[15]=n;return [NSData dataWithBytes:b length:16];}
static NSString *uri(NSUInteger n,NSString *kind){const char *abc="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";char s[23];memset(s,'0',22);s[22]=0;for(int i=21;n;i--){s[i]=abc[n%62];n/=62;}return [NSString stringWithFormat:@"spotify:%@:%s",kind,s];}
static NSData *item(NSUInteger n,unsigned state){return join(@[text(1,uri(n,@"track")),SAPProtoInteger(2,state)]);}
static NSUInteger mode,total=260,calls,cancels,active,maximum,batches,contextCalls,metadataCalls,artistCalls;
static NSMutableArray *pending,*requestedBatches;
static NSData *metadata(NSString *u){
 NSArray *parts=[u componentsSeparatedByString:@":"];NSString *kind=parts[1];NSUInteger n=0;const char *abc="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
 for(NSUInteger i=0;i<[parts[2]length];i++)n=n*62+(strchr(abc,[parts[2]characterAtIndex:i])-abc);
 NSData *artist=join(@[SAPProtoBytes(1,gid(700)),text(2,@"Artist"),SAPProtoBytes(17,SAPProtoBytes(1,SAPProtoBytes(1,[NSData dataWithBytes:(uint8_t[20]){2} length:20]))),SAPProtoInteger(16,mode==10)]);
 NSData *album=join(@[SAPProtoBytes(1,gid(600)),text(2,@"Album"),SAPProtoBytes(3,artist),SAPProtoInteger(4,1),SAPProtoBytes(6,SAPProtoInteger(1,4052)),SAPProtoBytes(9,SAPProtoBytes(1,[NSData dataWithBytes:(uint8_t[20]){1} length:20]))]);
 if([kind isEqual:@"artist"])return SAPProtoBytes(1,SAPProtoBytes(2,artist));
 if([kind isEqual:@"album"])return SAPProtoBytes(1,SAPProtoBytes(3,album));
 NSData *track=join(@[SAPProtoBytes(1,gid(n)),text(2,[NSString stringWithFormat:@"Track %lu",(unsigned long)n]),SAPProtoBytes(3,mode==8?SAPProtoBytes(1,gid(600)):album),SAPProtoBytes(4,mode==8?SAPProtoBytes(1,gid(700)):artist),SAPProtoInteger(5,2),SAPProtoInteger(6,2),SAPProtoInteger(7,360000)]);
 return SAPProtoBytes(1,SAPProtoBytes(4,track));
}
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *service,NSString *method,NSData *payload,void(^callback)(NSData *,NSString *)){
 assert(NSThread.isMainThread);calls++;NSData *response=nil;NSString *error=nil;
 NSArray *f=SAPProtoFields(payload);
 if([method isEqual:@"GetContexts"]){
  assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);contextCalls++;
  // Full native enumeration: explicit items policy; omit device/URIs/filter.
  assert(f.count==1 && [f[0][@"number"]unsignedIntValue]==1);
  assert(SAPProtoNumber(SAPProtoFields(SAPProtoData(f,1)),1,0)==1);
  NSMutableData *items=NSMutableData.data;
  for(NSUInteger n=1;n<=total;n++)[items appendData:SAPProtoBytes(2,item(n,n==2?5:3))];
  [items appendData:SAPProtoBytes(2,item(1,3))];
  // Context state cannot prove item readiness; downloads within an in-progress
  // stock playlist still belong in the library. Non-track items are ignored.
  [items appendData:SAPProtoBytes(2,join(@[text(1,uri(1,@"episode")),SAPProtoInteger(2,3)]))];
  response=SAPProtoBytes(1,join(@[SAPProtoBytes(1,join(@[text(1,uri(900,@"playlist")),SAPProtoInteger(2,4)])),items]));
  if(mode==1)error=@"Native service unavailable";
  if(mode==2)response=SAPProtoInteger(2,5);
  if(mode==3)response=[NSData dataWithBytes:(uint8_t[]){0x0a,0xff} length:2];
  if(mode==9)response=NSData.data;
 }else if([method isEqual:@"GetItems"]){
  assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"]);batches++;[requestedBatches addObject:@(f.count)];assert(f.count<=128);
  NSMutableData *d=NSMutableData.data;
  for(NSDictionary *field in f){assert([field[@"number"]unsignedIntValue]==1);NSString *u=[[NSString alloc]initWithData:field[@"value"] encoding:NSUTF8StringEncoding];
   if(mode==4)continue; // Missing responses must fail, never claim complete.
   [d appendData:SAPProtoBytes(1,join(@[text(1,u),SAPProtoInteger(2,[u isEqual:uri(3,@"track")]?2:3)]))];
  }response=d;
 }else{
  assert([service isEqual:@"spotify.metadata_esperanto.proto.ClassicMetadataService"] && [method isEqual:@"GetEntity"]);metadataCalls++;
  assert(f.count==1);NSString *u=SAPProtoString(f,1);response=metadata(u);if(mode==13 && [u hasPrefix:@"spotify:album:"])error=@"Album unavailable";if([u hasPrefix:@"spotify:artist:"]){artistCalls++;if(mode==11)error=@"Portrait unavailable";}
  if(mode==5)error=@"Metadata unavailable";
 }
 __block BOOL done=NO;active++;maximum=MAX(maximum,active);
 dispatch_block_t deliver=^{if(done)return;done=YES;active--;callback(error?nil:response,error);};
 if(mode==6 || (mode==12 && [method isEqual:@"GetEntity"]))[pending addObject:[^{callback(response,nil);}copy]]; // Simulates misbehaving late callback after cancellation.
 else dispatch_async(dispatch_get_main_queue(),deliver);
 return ^{if(done)return;done=YES;active--;cancels++;};
}
static void waitFor(BOOL(^f)(void)){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:10];while(!f() && end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];assert(f());}
static void reset(NSUInteger m,NSUInteger count){SAPUpdateOfflineLibraryCachedTracks(nil);mode=m;total=count;calls=cancels=active=maximum=batches=contextCalls=metadataCalls=artistCalls=0;pending=NSMutableArray.array;requestedBatches=NSMutableArray.array;}
static NSArray *fetch(NSString **failure){__block BOOL done=NO;__block NSArray *rows;__block NSString *error;
 SAPFetchOfflineLibrary(^(NSUInteger a,NSUInteger b){assert(NSThread.isMainThread && a<=b);},^(NSArray *r,NSString *e){assert(NSThread.isMainThread);rows=r;error=e;done=YES;});waitFor(^{return done;});if(failure)*failure=error;return rows;}
int main(void){@autoreleasepool{
 NSString *error=nil;reset(0,260);NSArray *rows=fetch(&error);assert(!error && rows.count==258 && contextCalls==1 && batches==3 && maximum<=4);
 assert(metadataCalls==260 && artistCalls==1 && [rows[0][@"artist_cover_url"]hasPrefix:@"https://i.scdn.co/image/02"] && [rows[0][@"artist_image_uri"]hasPrefix:@"spotify:image:02"]);
 NSMutableSet *seen=NSMutableSet.set;for(NSDictionary *r in rows){assert(![seen containsObject:r[@"uri"]]);[seen addObject:r[@"uri"]];assert([r[@"artist_name"]isEqual:@"Artist"] && [r[@"album_name"]isEqual:@"Album"] && [r[@"category"]isEqual:@"Albums"] && [r[@"year"]intValue]==2026 && [r[@"duration_ms"]intValue]==180000 && [r[@"disc"]intValue]==1 && [r[@"number"]intValue]==1 && [r[@"cover_url"]hasPrefix:@"https://i.scdn.co/image/"]);}
 assert(![seen containsObject:uri(2,@"track")] && ![seen containsObject:uri(3,@"track")]);
 puts("PASS: all stock contexts, item state3, URI dedup, native request filters, bounded batches and four metadata reads");
 metadataCalls=artistCalls=contextCalls=batches=0;
 NSArray *unchanged=fetch(&error);
 assert(!error && [unchanged isEqual:rows] && contextCalls==1 && batches==3);
 assert(metadataCalls==0 && artistCalls==0 && "unchanged downloaded tracks must reuse complete metadata");
 puts("PASS: repeat native validation reuses complete metadata without another GetEntity");
 for(NSUInteger m=1;m<=4;m++){reset(m,4);assert(!fetch(&error) && error.length);assert(metadataCalls==0);}
 puts("PASS: service/context error, malformed body and omitted item prevent false completeness");
 reset(5,4);rows=fetch(&error);assert(rows.count==2 && error.length && [rows[0][@"metadata_complete"]isEqual:@NO]);
 puts("PASS: metadata errors retain downloaded tracks and return explicit partial metadata warning");
 reset(8,4);rows=fetch(&error);assert(rows.count==2 && !error && [rows[0][@"artist_name"]isEqual:@"Artist"] && [rows[0][@"album_name"]isEqual:@"Album"]);
 puts("PASS: album and artist references hydrated before publishing");
 reset(13,4);rows=fetch(&error);assert(rows.count==2 && error.length && artistCalls==1 && [rows[0][@"artist_cover_url"]length]);
 reset(10,4);rows=fetch(&error);assert(!error && rows.count==2 && [rows[0][@"artist_cover_url"]length]==0);
 reset(11,4);rows=fetch(&error);assert(rows.count==2 && error.length && [rows[0][@"artist_image_error"]length]);
 puts("PASS: unique artist portrait hydration, no album art substitution, portrait failure preserves tracks");
 reset(9,0);assert(fetch(&error).count==0 && !error && metadataCalls==0 && batches==0);
 reset(6,4);__block BOOL completed=NO;dispatch_block_t cancel=SAPFetchOfflineLibrary(nil,^(NSArray *r,NSString *e){completed=YES;});waitFor(^{return (BOOL)(pending.count>0);});cancel();cancel();for(dispatch_block_t callback in [pending copy])callback();[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];assert(!completed && cancels==1 && calls==1);
 reset(12,10);completed=NO;cancel=SAPFetchOfflineLibrary(nil,^(NSArray *r,NSString *e){completed=YES;});waitFor(^{return (BOOL)(pending.count==4);});cancel();for(dispatch_block_t callback in [pending copy])callback();[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];assert(!completed && cancels==4 && maximum==4);
 reset(6,10);cancel=SAPFetchOfflineLibrary(nil,^(NSArray *r,NSString *e){assert(0);});cancel();[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];assert(calls==0);
 puts("PASS: cancellation suppresses late callback and duplicate cancel; empty catalog succeeds");
 reset(0,4);rows=fetch(&error);assert([SAPOfflineLibraryCachedTracks() isEqual:rows]);
 metadataCalls=contextCalls=batches=0;total=5;
 NSArray *added=fetch(&error);assert(!error && added.count==3 && contextCalls==1 && batches==1 && metadataCalls==3);
 assert([added.lastObject[@"uri"]isEqual:uri(5,@"track")]);
 metadataCalls=contextCalls=batches=0;total=1;
 NSArray *removed=fetch(&error);assert(!error && removed.count==1 && contextCalls==1 && batches==1 && metadataCalls==0);
 assert([removed.firstObject[@"uri"]isEqual:uri(1,@"track")]);
 NSArray *saved=SAPOfflineLibraryCachedTracks();mode=1;assert(!fetch(&error) && error.length && SAPOfflineLibraryCachedTracks()==saved);
 mode=4;assert(!fetch(&error) && error.length && SAPOfflineLibraryCachedTracks()==saved);
 mode=6;completed=NO;cancel=SAPFetchOfflineLibrary(nil,^(NSArray *r,NSString *e){completed=YES;});
 waitFor(^{return (BOOL)(pending.count>0);});cancel();for(dispatch_block_t callback in [pending copy])callback();
 [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert(!completed && SAPOfflineLibraryCachedTracks()==saved);
 mode=9;assert(fetch(&error).count==0 && !error && SAPOfflineLibraryCachedTracks()!=nil && SAPOfflineLibraryCachedTracks().count==0);
 puts("PASS: new tracks hydrate once; removed/empty native results reconcile; errors and cancellation retain snapshot");
 reset(5,4);rows=fetch(&error);assert(error.length && rows.count==2);
 mode=0;metadataCalls=0;rows=fetch(&error);assert(!error && metadataCalls==4 && [rows.firstObject[@"metadata_complete"]isEqual:@YES]);
 puts("PASS: incomplete cached metadata retries on next verification");
 // A verified deletion while a scan is queued must invalidate that old writer.
 reset(6,4);completed=NO;cancel=SAPFetchOfflineLibrary(nil,^(NSArray *r,NSString *e){completed=YES;});
 waitFor(^{return (BOOL)(pending.count>0);});SAPUpdateOfflineLibraryCachedTracks(@[]);
 mode=0;for(dispatch_block_t callback in [pending copy])callback();waitFor(^{return completed;});
 assert(SAPOfflineLibraryCachedTracks().count==0);
 puts("PASS: verified cache updates cannot be overwritten by an older in-flight scan");
 reset(6,4);completed=NO;SAPFetchOfflineLibrary(nil,^(NSArray *r,NSString *e){assert(r.count==2 && !e);completed=YES;});
 waitFor(^{return (BOOL)(pending.count>0);});mode=0;total=1;
 NSArray *latest=fetch(&error);assert(!error && latest.count==1);
 for(dispatch_block_t callback in [pending copy])callback();waitFor(^{return completed;});
 assert([SAPOfflineLibraryCachedTracks() isEqual:latest]);
 puts("PASS: a slower older scan cannot overwrite a newer completed scan");
 // A progress observer can cancel while all rows come from complete metadata.
 reset(0,4);fetch(&error);__block NSUInteger progressCalls=0;completed=NO;
 __block dispatch_block_t hydrationCancel;hydrationCancel=SAPFetchOfflineLibrary(^(NSUInteger a,NSUInteger b){progressCalls++;if(a==1)hydrationCancel();},^(NSArray *r,NSString *e){completed=YES;});
 waitFor(^{return (BOOL)(progressCalls>=2);});[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert(progressCalls==2 && !completed);
 puts("PASS: cancellation during cached hydration suppresses subsequent progress and completion");
 // Persistence: a fresh launch shows the last verified list at once and reuses its
 // metadata, but a native scan still decides membership.
 NSString *dir=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 SAPOfflineLibraryStoreResetForTesting(dir);reset(0,4);rows=fetch(&error);assert(!error && rows.count==2);
 SAPOfflineLibraryStoreFlushForTesting();
 SAPOfflineLibraryStoreResetForTesting(dir); // new launch
 assert([SAPOfflineLibraryCachedTracks() isEqual:rows] && "snapshot must be shown before any native read");
 mode=0;calls=contextCalls=batches=metadataCalls=0;NSArray *relaunched=fetch(&error);
 assert(!error && [relaunched isEqual:rows] && contextCalls==1 && batches==1 && metadataCalls==0 && "persisted metadata is reused only after native item validation");
 // A track removed natively disappears even though it was persisted.
 SAPOfflineLibraryStoreFlushForTesting();SAPOfflineLibraryStoreResetForTesting(dir);total=1;calls=contextCalls=batches=metadataCalls=0;
 NSArray *shrunk=fetch(&error);assert(!error && shrunk.count==1 && metadataCalls==0);
 SAPOfflineLibraryStoreFlushForTesting();SAPOfflineLibraryStoreResetForTesting(dir);
 assert(SAPOfflineLibraryCachedTracks().count==1 && "scan result replaces the persisted snapshot");
 // A failed scan never replaces the persisted snapshot.
 mode=1;assert(!fetch(&error) && error.length);SAPOfflineLibraryStoreFlushForTesting();SAPOfflineLibraryStoreResetForTesting(dir);
 assert(SAPOfflineLibraryCachedTracks().count==1);
 // Verified deletion persists; clearing removes the file.
 SAPUpdateOfflineLibraryCachedTracks(@[]);SAPOfflineLibraryStoreFlushForTesting();SAPOfflineLibraryStoreResetForTesting(dir);
 assert(SAPOfflineLibraryCachedTracks().count==0);
 SAPUpdateOfflineLibraryCachedTracks(nil);SAPOfflineLibraryStoreFlushForTesting();SAPOfflineLibraryStoreResetForTesting(dir);
 assert(!SAPOfflineLibraryCachedTracks() && ![NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"offline-catalog.plist"]]);
 // Damaged files are ignored; invalid rows are dropped individually.
 NSString *file=[dir stringByAppendingPathComponent:@"offline-catalog.plist"];
 [@"not a plist" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];SAPOfflineLibraryStoreResetForTesting(dir);assert(!SAPOfflineLibraryCachedTracks());
 NSDictionary *good=@{@"uri":uri(1,@"track"),@"name":@"A",@"artist_name":@"B",@"album_name":@"C",@"category":@"Albums",@"year":@2026};
 NSDictionary *mixed=@{@"version":@1,@"rows":@[good,good,@{@"uri":@"spotify:track:bad",@"name":@"x"},@{@"uri":uri(2,@"track"),@"name":@[@"nested"]},@"junk",@{@"uri":uri(3,@"track")}]};
 [mixed writeToFile:file atomically:YES];SAPOfflineLibraryStoreResetForTesting(dir);
 assert(SAPOfflineLibraryCachedTracks().count==1 && [SAPOfflineLibraryCachedTracks().firstObject isEqual:good]);
 [@{@"version":@2,@"rows":@[good]} writeToFile:file atomically:YES];SAPOfflineLibraryStoreResetForTesting(dir);assert(!SAPOfflineLibraryCachedTracks());
 SAPOfflineLibraryStoreResetForTesting(nil);
 puts("PASS: persisted snapshot shows immediately, is replaced by native verification, and ignores damaged data");
 }return 0;}
