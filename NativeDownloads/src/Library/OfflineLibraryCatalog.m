#import "OfflineLibraryCatalog.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import "DiagnosticTrace.h"

static NSArray<NSDictionary *> *cachedTracks;
static NSUInteger cacheGeneration;
static BOOL snapshotLoaded;
#ifdef SAP_TESTING
static NSString *snapshotDirectory;
#endif
static void loadPersistedSnapshot(void);
static void persistSnapshot(NSArray<NSDictionary *> *tracks);
NSArray<NSDictionary *> *SAPOfflineLibraryCachedTracks(void) {
 NSCAssert(NSThread.isMainThread,@"Offline library snapshots are main-queue only");
 loadPersistedSnapshot();
 return cachedTracks;
}
void SAPUpdateOfflineLibraryCachedTracks(NSArray<NSDictionary *> *tracks) {
 NSCAssert(NSThread.isMainThread,@"Offline library snapshots are main-queue only");
 snapshotLoaded=YES;cacheGeneration++;cachedTracks=[tracks copy];persistSnapshot(cachedTracks);
}

static NSString *const OfflineService=@"spotify.offline_esperanto.proto.Offline";
static NSString *const MetadataService=@"spotify.metadata_esperanto.proto.ClassicMetadataService";
static BOOL validURI(NSString *uri,NSString *kind){
 NSString *prefix=[NSString stringWithFormat:@"spotify:%@:",kind];
 if(![uri hasPrefix:prefix] || uri.length!=prefix.length+22)return NO;
 NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
 return [[uri substringFromIndex:prefix.length]rangeOfCharacterFromSet:invalid].location==NSNotFound;
}
static NSString *uriFromGID(NSData *gid,NSString *kind){
 if(gid.length!=16)return nil;uint8_t bytes[16];memcpy(bytes,gid.bytes,16);
 const char *abc="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";char result[23]={0};
 for(NSInteger i=21;i>=0;i--){unsigned rem=0;for(unsigned j=0;j<16;j++){unsigned v=(rem<<8)|bytes[j];bytes[j]=v/62;rem=v%62;}result[i]=abc[rem];}
 return [NSString stringWithFormat:@"spotify:%@:%s",kind,result];
}
static NSArray *messages(NSArray *fields,unsigned number){NSMutableArray *result=NSMutableArray.array;
 for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==number){if([f[@"wire"]unsignedIntValue]!=2)return nil;NSArray *value=SAPProtoFields(f[@"value"]);if(!value)return nil;[result addObject:value];}return result;}
static NSArray *entity(NSData *data,unsigned field,NSString *uri,NSString *kind){
 NSArray *root=SAPProtoFields(data),*item=SAPProtoFields(SAPProtoData(root,1));
 if(!root || !item || SAPProtoNumber(item,1,0))return nil;
 NSArray *value=SAPProtoFields(SAPProtoData(item,field));
 return [uriFromGID(SAPProtoData(value,1),kind)isEqual:uri]?value:nil;
}
static NSString *imageURL(NSArray *album,unsigned individualField){
 NSMutableArray *images=NSMutableArray.array;
 for(NSDictionary *f in album){unsigned n=[f[@"number"]unsignedIntValue];if([f[@"wire"]unsignedIntValue]!=2)continue;
  if(n==individualField)[images addObject:f[@"value"]];
  else if(n==17)for(NSDictionary *image in SAPProtoFields(f[@"value"]))if([image[@"number"]unsignedIntValue]==1 && [image[@"wire"]unsignedIntValue]==2)[images addObject:image[@"value"]];}
 NSString *fallback=nil;
 for(NSData *bytes in images){NSArray *image=SAPProtoFields(bytes);NSData *gid=SAPProtoData(image,1);if(gid.length!=20)continue;
  NSMutableString *hex=NSMutableString.string;const uint8_t *p=gid.bytes;for(unsigned i=0;i<20;i++)[hex appendFormat:@"%02x",p[i]];
  NSString *url=[@"https://i.scdn.co/image/" stringByAppendingString:hex];if(SAPProtoNumber(image,2,0)==0)return url;if(!fallback)fallback=url;}
 return fallback?:@"";
}
static void applyAlbum(NSMutableDictionary *row,NSArray *album){
 NSString *name=SAPProtoString(album,2);if(name.length)row[@"album_name"]=name;
 NSString *identity=uriFromGID(SAPProtoData(album,1),@"album");if(identity)row[@"album_uri"]=identity;
 uint64_t type=SAPProtoNumber(album,4,0);row[@"category"]=type==4?@"EPs":type==2?@"Singles":type==3?@"Compilations":@"Albums";
 int64_t year=SAPProtoSInt(SAPProtoFields(SAPProtoData(album,6)),1,0);row[@"year"]=@(year>=0 && year<=9999?year:0);
 NSString *cover=imageURL(album,9);if(cover.length)row[@"cover_url"]=cover;
}
static void applyArtist(NSMutableDictionary *row,NSArray *artist){
 NSString *name=SAPProtoString(artist,2),*identity=uriFromGID(SAPProtoData(artist,1),@"artist");
 if(name.length)row[@"artist_name"]=name;if(identity)row[@"artist_uri"]=identity;
}
// The last verified snapshot also survives a launch, so the first open shows
// the list at once and reuses its metadata. It stays a display hint exactly like
// the in-process cache: SAPFetchOfflineLibrary still validates every track
// against the native catalog and replaces it.
static NSString *snapshotPath(void) {
#ifdef SAP_TESTING
 // Host fixtures never touch a real profile unless they inject a directory.
 return snapshotDirectory.length?[snapshotDirectory stringByAppendingPathComponent:@"offline-catalog.plist"]:nil;
#else
 return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Pixie/offline-catalog.plist"];
#endif
}
static dispatch_queue_t snapshotQueue(void) {
 static dispatch_queue_t queue;static dispatch_once_t once;
 dispatch_once(&once,^{queue=dispatch_queue_create("Pixie.offline-catalog-store",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});
 return queue;
}
static BOOL plainValue(id value){return [value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class];}
static void loadPersistedSnapshot(void) {
 if(snapshotLoaded)return;snapshotLoaded=YES;
 if(cachedTracks)return; // A scan or verified deletion already published newer truth.
 NSString *path=snapshotPath();NSDictionary *file=path?[NSDictionary dictionaryWithContentsOfFile:path]:nil;
 NSArray *stored=[file[@"version"]isEqual:@1]?file[@"rows"]:nil;
 if(![stored isKindOfClass:NSArray.class])return;
 NSMutableArray *rows=NSMutableArray.array;NSMutableSet *seen=NSMutableSet.set;
 for(NSDictionary *row in stored) {
  // Drop anything the scanner could not have produced; a damaged entry only
  // costs one row until the next verification.
  if(![row isKindOfClass:NSDictionary.class] || !validURI(row[@"uri"],@"track") || [seen containsObject:row[@"uri"]])continue;
  BOOL valid=YES;
  for(id key in row)if(![key isKindOfClass:NSString.class] || !plainValue(row[key])){valid=NO;break;}
  for(NSString *key in @[@"name",@"artist_name",@"album_name",@"category"])if(![row[key]isKindOfClass:NSString.class])valid=NO;
  if(!valid)continue;
  [seen addObject:row[@"uri"]];[rows addObject:[row copy]];
 }
 cachedTracks=[rows copy];
}
static void persistSnapshot(NSArray<NSDictionary *> *tracks) {
 NSString *path=snapshotPath();if(!path)return;
 // Rows are immutable copies, so the writer can read them off the main queue.
 dispatch_async(snapshotQueue(),^{@autoreleasepool{
  NSFileManager *fm=NSFileManager.defaultManager;
  if(!tracks){[fm removeItemAtPath:path error:nil];return;}
  [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  // Atomic replace keeps the previous snapshot if the write is interrupted.
  [@{@"version":@1,@"rows":tracks} writeToURL:[NSURL fileURLWithPath:path] error:nil];
 }});
}
#ifdef SAP_TESTING
void SAPOfflineLibraryStoreResetForTesting(NSString *directory) {
 snapshotDirectory=[directory copy];snapshotLoaded=NO;cachedTracks=nil;
}
void SAPOfflineLibraryStoreFlushForTesting(void) {dispatch_sync(snapshotQueue(),^{});}
#endif
@interface SAPOfflineLibraryFetch:NSObject
@property(nonatomic,copy)void(^progress)(NSUInteger,NSUInteger);
@property(nonatomic,copy)void(^completion)(NSArray *,NSString *);
@property(nonatomic)BOOL stopped;
@property(nonatomic,strong)NSMutableDictionary<NSString *,dispatch_block_t> *reads;
@property(nonatomic,strong)NSMutableOrderedSet<NSString *> *candidates;
@property(nonatomic,strong)NSMutableArray<NSString *> *downloaded;
@property(nonatomic,strong)NSMutableDictionary<NSString *,NSDictionary *> *rows;
@property(nonatomic,strong)NSMutableDictionary *metadataCache,*metadataWaiters;
@property(nonatomic)NSUInteger validationOffset,nextMetadata,metadataActive,metadataFailures,snapshotGeneration;
@property(nonatomic,copy)NSDictionary<NSString *,NSDictionary *> *previousRows;
- (void)begin;
- (void)cancel;
@end
@implementation SAPOfflineLibraryFetch
- (BOOL)isStopped{@synchronized(self){return self.stopped;}}
- (void)cancel{
 @synchronized(self){if(self.stopped)return;self.stopped=YES;}
 dispatch_async(dispatch_get_main_queue(),^{for(dispatch_block_t cancel in self.reads.allValues)cancel();[self.reads removeAllObjects];[self.metadataWaiters removeAllObjects];self.progress=nil;self.completion=nil;});
}
- (void)finish:(NSString *)error rows:(NSArray *)rows{
 if([self isStopped])return;
 @synchronized(self){if(self.stopped)return;self.stopped=YES;}
 for(dispatch_block_t cancel in self.reads.allValues)cancel();[self.reads removeAllObjects];[self.metadataWaiters removeAllObjects];
 // Errors/cancellation never replace the previous display snapshot. A later
 // scan or a verified deletion supersedes this writer.
 if(rows && self.snapshotGeneration==cacheGeneration){cachedTracks=[rows copy];persistSnapshot(cachedTracks);}
 void(^callback)(NSArray *,NSString *)=self.completion;self.completion=nil;self.progress=nil;if(callback)callback(rows,error);
}
- (void)read:(NSString *)service method:(NSString *)method payload:(NSData *)payload reply:(void(^)(NSData *,NSString *))reply{
 if([self isStopped])return;NSString *key=NSUUID.UUID.UUIDString;
 dispatch_block_t cancellation=SAPCallReadOnlyServiceCancellable(service,method,payload,^(NSData *data,NSString *error){
  // Always defer to serialize even a synchronously answering native bridge.
  dispatch_async(dispatch_get_main_queue(),^{if(!self.reads[key])return;[self.reads removeObjectForKey:key];if(![self isStopped])reply(data,error);});
 });
 self.reads[key]=cancellation?:^{};
}
- (void)metadata:(NSString *)uri reply:(void(^)(NSData *,NSString *))reply{
 if([self isStopped])return;NSDictionary *cached=self.metadataCache[uri];
 if(cached){dispatch_async(dispatch_get_main_queue(),^{if(![self isStopped])reply(cached[@"data"],cached[@"error"]);});return;}
 NSMutableArray *waiting=self.metadataWaiters[uri];if(waiting){[waiting addObject:[reply copy]];return;}
 self.metadataWaiters[uri]=[NSMutableArray arrayWithObject:[reply copy]];
 [self read:MetadataService method:@"GetEntity" payload:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]) reply:^(NSData *data,NSString *error){
  NSDictionary *entry=error?@{@"error":error}:data?@{@"data":data}:@{@"error":@"Metadata unavailable"};self.metadataCache[uri]=entry;
  NSArray *callbacks=[self.metadataWaiters[uri]copy];[self.metadataWaiters removeObjectForKey:uri];
  for(void(^callback)(NSData *,NSString *) in callbacks)if(![self isStopped])callback(entry[@"data"],entry[@"error"]);
 }];
}
- (void)begin{
 if([self isStopped])return;
 loadPersistedSnapshot();
 self.snapshotGeneration=++cacheGeneration;
 NSMutableDictionary *previous=NSMutableDictionary.dictionary;
 for(NSDictionary *row in cachedTracks)if([row[@"metadata_complete"]isEqual:@YES] && validURI(row[@"uri"],@"track"))previous[row[@"uri"]]=row;
 self.previousRows=previous;
 self.reads=NSMutableDictionary.dictionary;self.candidates=NSMutableOrderedSet.orderedSet;
 self.downloaded=NSMutableArray.array;self.rows=NSMutableDictionary.dictionary;self.metadataCache=NSMutableDictionary.dictionary;self.metadataWaiters=NSMutableDictionary.dictionary;
 // Descriptor at executable offset 0xa4a60e0: no pagination fields exist.
 // No device, URI list or item filter => request the complete local context set.
 [self read:OfflineService method:@"GetContexts" payload:SAPProtoBytes(1,SAPProtoInteger(1,1)) reply:^(NSData *data,NSString *error){
  NSArray *fields=SAPProtoFields(data),*contexts=messages(fields,1);NSUInteger itemCount=0;
  if(error || !fields || !contexts || SAPProtoNumber(fields,2,0)){[self finish:error?:@"Native offline context enumeration failed" rows:nil];return;}
  for(NSArray *info in contexts){
   NSArray *context=SAPProtoFields(SAPProtoData(info,1)),*items=messages(info,2);
   if(!context || !items){[self finish:@"Malformed native offline context" rows:nil];return;}
   NSString *contextURI=SAPProtoString(context,1);
   if(!contextURI.length){[self finish:@"Native offline context identity missing" rows:nil];return;}
   if(validURI(contextURI,@"track"))[self.candidates addObject:contextURI];
   for(NSArray *item in items){itemCount++;NSString *uri=SAPProtoString(item,1);
    if(!uri.length || ([uri hasPrefix:@"spotify:track:"] && !validURI(uri,@"track"))){[self finish:@"Malformed native offline item identity" rows:nil];return;}
    if(validURI(uri,@"track") && SAPProtoNumber(item,2,0)==3)[self.candidates addObject:uri];
   }
  }
  SAP_TRACE("offline_library","native_contexts_loaded",0,(@{@"context_count":@(contexts.count),@"item_count":@(itemCount),@"candidate_tracks":@(self.candidates.count),@"unfiltered_contexts":@YES,@"scope_runtime_verified":@NO,@"pagination_contract":@"none_in_native_descriptor"}));
  [self validateNext];
 }];
}
- (void)validateNext{
 if([self isStopped])return;
 if(self.validationOffset==self.candidates.count){if(self.progress)self.progress(0,self.downloaded.count);[self hydrateNext];return;}
 NSUInteger count=MIN((NSUInteger)128,self.candidates.count-self.validationOffset);
 NSArray *batch=[self.candidates.array subarrayWithRange:NSMakeRange(self.validationOffset,count)];
 NSMutableData *payload=NSMutableData.data;for(NSString *uri in batch)[payload appendData:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])];
 [self read:OfflineService method:@"GetItems" payload:payload reply:^(NSData *data,NSString *error){
  NSArray *fields=SAPProtoFields(data),*items=messages(fields,1);NSMutableDictionary *states=NSMutableDictionary.dictionary;
  if(error || !fields || !items){[self finish:error?:@"Native offline item validation failed" rows:nil];return;}
  for(NSArray *item in items){NSString *uri=SAPProtoString(item,1);uint64_t state=SAPProtoNumber(item,2,0);
   if(![batch containsObject:uri] || (states[uri] && [states[uri]unsignedLongLongValue]!=state)){[self finish:@"Native offline item validation returned inconsistent identities" rows:nil];return;}
   states[uri]=@(state);
  }
  if(states.count!=batch.count){[self finish:@"Native offline item validation omitted requested tracks" rows:nil];return;}
  for(NSString *uri in batch)if([states[uri]unsignedLongLongValue]==3)[self.downloaded addObject:uri];
  self.validationOffset+=count;[self validateNext];
 }];
}
- (void)hydrateNext{
 if([self isStopped])return;
 while(![self isStopped] && self.metadataActive<4 && self.nextMetadata<self.downloaded.count){
  NSString *uri=self.downloaded[self.nextMetadata++];
  NSDictionary *previous=self.previousRows[uri];
  if(previous){self.rows[uri]=previous;if(self.progress)self.progress(self.rows.count,self.downloaded.count);continue;}
  self.metadataActive++;
  NSMutableDictionary *row=[@{@"uri":uri,@"name":uri,@"artist_name":@"Unknown artist",@"artist_uri":@"",@"album_name":@"Unknown album",@"album_uri":@"",@"category":@"Albums",@"year":@0,@"disc":@0,@"number":@0,@"cover_url":@"",@"duration_ms":@0,@"metadata_complete":@NO,@"artist_cover_url":@"",@"artist_image_uri":@""}mutableCopy];
  [self metadata:uri reply:^(NSData *data,NSString *error){
   NSArray *track=entity(data,4,uri,@"track");
   if(error || !track){[self finishMetadata:row error:error?:@"Track metadata unavailable or identity mismatch"];return;}
   NSString *name=SAPProtoString(track,2);if(!name.length){[self finishMetadata:row error:@"Track title missing"];return;}
   row[@"name"]=name;int64_t duration=SAPProtoSInt(track,7,0),disc=SAPProtoSInt(track,6,0),number=SAPProtoSInt(track,5,0);
   row[@"duration_ms"]=@(duration>=0 && duration<=86400000?duration:0);row[@"disc"]=@(MAX((int64_t)0,disc));row[@"number"]=@(MAX((int64_t)0,number));
   NSArray *album=SAPProtoFields(SAPProtoData(track,3));applyAlbum(row,album);
   NSArray *artists=messages(track,4);applyArtist(row,artists.firstObject);
   [self hydrateAlbum:row];
  }];
 }
 if([self isStopped])return;
 if(!self.metadataActive && self.nextMetadata==self.downloaded.count){NSMutableArray *result=NSMutableArray.array;for(NSString *uri in self.downloaded)[result addObject:self.rows[uri]];
  NSString *warning=self.metadataFailures?[NSString stringWithFormat:@"Metadata unavailable for %lu downloaded tracks",(unsigned long)self.metadataFailures]:nil;
  [self finish:warning rows:[result copy]];
 }
}
- (void)hydrateAlbum:(NSMutableDictionary *)row{
 NSString *uri=row[@"album_uri"];
 if(!validURI(uri,@"album")){row[@"metadata_error"]=@"Album metadata identity missing";[self hydrateArtist:row];return;}
 [self metadata:uri reply:^(NSData *data,NSString *error){
  NSArray *album=entity(data,3,uri,@"album");if(error || !SAPProtoString(album,2).length){row[@"metadata_error"]=error?:@"Album metadata unavailable";[self hydrateArtist:row];return;}
  applyAlbum(row,album);if(![row[@"artist_uri"]length])applyArtist(row,messages(album,3).firstObject);[self hydrateArtist:row];
 }];
}
- (void)hydrateArtist:(NSMutableDictionary *)row{
 NSString *uri=row[@"artist_uri"];
 if(!validURI(uri,@"artist")){[self finishMetadata:row error:@"Artist metadata identity missing"];return;}
 [self metadata:uri reply:^(NSData *data,NSString *error){
  NSArray *artist=entity(data,2,uri,@"artist");if(error || !SAPProtoString(artist,2).length){row[@"artist_image_error"]=error?:@"Artist metadata unavailable";[self finishMetadata:row error:row[@"artist_image_error"]];return;}
  applyArtist(row,artist);
  // Artist.is_portrait_album_cover=16 explicitly excludes substituted album art.
  NSString *portrait=SAPProtoNumber(artist,16,0)?@"":imageURL(artist,11);
  row[@"artist_cover_url"]=portrait;row[@"artist_image_uri"]=portrait.length?[@"spotify:image:" stringByAppendingString:portrait.lastPathComponent]:@"";
  [self finishMetadata:row error:nil];
 }];
}
- (void)finishMetadata:(NSMutableDictionary *)row error:(NSString *)error{
 if([self isStopped])return;
 NSString *prior=row[@"metadata_error"];if(prior.length && error.length)error=[NSString stringWithFormat:@"%@; %@",prior,error];else if(prior.length)error=prior;
 if(error){row[@"metadata_error"]=error;self.metadataFailures++;}else row[@"metadata_complete"]=@YES;
 self.rows[row[@"uri"]]=[row copy];self.metadataActive--;if(self.progress)self.progress(self.rows.count,self.downloaded.count);[self hydrateNext];
}
@end

dispatch_block_t SAPFetchOfflineLibrary(void(^progress)(NSUInteger,NSUInteger),void(^completion)(NSArray *,NSString *)){
 SAPOfflineLibraryFetch *fetch=SAPOfflineLibraryFetch.new;fetch.progress=progress;fetch.completion=completion;
 dispatch_async(dispatch_get_main_queue(),^{[fetch begin];});return ^{[fetch cancel];};
}
