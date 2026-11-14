#import "OfflineLibraryDelete.h"
#import "TrackDownload.h"
#import "SpotifyTransport.h"
#import "WireProto.h"
#import "PlaylistDownloads.h"
#import "ExportNativeAdapters.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"

#define DELETE_TRACE(stage,...) do { if([self tracing]) \
 SAPTraceEventAtGeneration("offline_library_delete",stage,self.traceID,(__VA_ARGS__),self.traceGeneration); } while(0)

NSString *const SAPOfflineLibraryDeleteBusyError=@"Download in progress";
static NSString *const Offline=@"spotify.offline_esperanto.proto.Offline";
static NSString *const Library=@"spotify.your_library_esperanto.proto.YourLibraryService";
static NSData *str(unsigned n,NSString *s){return SAPProtoBytes(n,[s dataUsingEncoding:NSUTF8StringEncoding]);}
static BOOL valid(id value,NSString *kind){if(![value isKindOfClass:NSString.class])return NO;NSString *prefix=[NSString stringWithFormat:@"spotify:%@:",kind];NSString *s=value;
 if(![s hasPrefix:prefix]||s.length!=prefix.length+22)return NO;
 return [[s substringFromIndex:prefix.length]rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet].location==NSNotFound;}
static id scalar(NSArray *fields,unsigned n,unsigned wire,id fallback){if(!fields)return nil;id result=nil;NSUInteger count=0;
 for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==n){if(++count>1||[f[@"wire"]unsignedIntValue]!=wire)return nil;result=f[@"value"];}return result?:fallback;}
static NSNumber *num(NSArray *fields,unsigned n,NSNumber *fallback){return scalar(fields,n,0,fallback);}
static NSString *string(NSArray *fields,unsigned n){NSData *d=scalar(fields,n,2,nil);return d?[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding]:nil;}
static NSArray *messages(NSArray *fields,unsigned n){if(!fields)return nil;NSMutableArray *a=NSMutableArray.array;
 for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==n){if([f[@"wire"]unsignedIntValue]!=2)return nil;NSArray *v=SAPProtoFields(f[@"value"]);if(!v)return nil;[a addObject:v];}return a;}
static NSDictionary *parseItems(NSData *data,NSArray *wanted){NSArray *fields=SAPProtoFields(data),*items=messages(fields,1);if(!items)return nil;
 NSSet *scope=[NSSet setWithArray:wanted];NSMutableDictionary *out=NSMutableDictionary.dictionary;
 for(NSArray *f in items){NSString *u=string(f,1);NSNumber *s=num(f,2,@0);if(!u||![scope containsObject:u]||out[u]||!s||s.unsignedLongLongValue>7)return nil;out[u]=s;}
 return out.count==wanted.count?out:nil;}
static NSDictionary *parseSaved(NSData *data,NSArray *wanted){NSArray *f=SAPProtoFields(data);NSNumber *status=num(f,98,nil);NSString *error=string(f,99);NSArray *entries=messages(f,2);
 if(!status||status.unsignedLongLongValue!=200||error.length||!entries)return nil;
 // An explicitly malformed error string must not be mistaken for its default.
 for(NSDictionary *field in f)if([field[@"number"]unsignedIntValue]==99&&(!error||[field[@"wire"]unsignedIntValue]!=2))return nil;
 NSSet *scope=[NSSet setWithArray:wanted];NSMutableDictionary *out=NSMutableDictionary.dictionary;
 for(NSArray *entry in entries){NSString *u=string(entry,1);NSNumber *saved=num(entry,2,@0);if(!u||![scope containsObject:u]||out[u]||!saved||saved.unsignedLongLongValue>1)return nil;out[u]=@([saved boolValue]);}
 return out.count==wanted.count?out:nil;}
static NSArray *parseContexts(NSData *data){NSArray *f=SAPProtoFields(data);NSNumber *error=num(f,2,@0);NSArray *infos=messages(f,1);if(!error||error.unsignedLongLongValue||!infos)return nil;
 NSMutableArray *out=NSMutableArray.array;NSMutableSet *seen=NSMutableSet.set;
 for(NSArray *info in infos){NSArray *contexts=messages(info,1),*items=messages(info,2);if(contexts.count!=1||!items)return nil;NSString *u=string(contexts[0],1);NSNumber *state=num(contexts[0],2,@0);
  if(!u.length||[seen containsObject:u]||!state||state.unsignedLongLongValue>7)return nil;[seen addObject:u];NSMutableOrderedSet *members=NSMutableOrderedSet.orderedSet;
  for(NSArray *item in items){NSString *track=string(item,1);NSNumber *s=num(item,2,@0);if(!track.length||!s||s.unsignedLongLongValue>7)return nil;[members addObject:track];}
  [out addObject:@{@"uri":u,@"items":members.array,@"state":state}];}return out;}
static NSString *gidURI(NSData *gid,NSString *kind){if(gid.length!=16)return nil;uint8_t b[16];memcpy(b,gid.bytes,16);const char *abc="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";char s[23]={0};
 for(NSInteger i=21;i>=0;i--){unsigned r=0;for(unsigned j=0;j<16;j++){unsigned v=(r<<8)|b[j];b[j]=v/62;r=v%62;}s[i]=abc[r];}return [NSString stringWithFormat:@"spotify:%@:%s",kind,s];}
static NSArray *fieldShape(NSArray *fields){NSMutableArray *out=NSMutableArray.array;
 for(NSDictionary *f in fields){NSMutableDictionary *row=[@{@"field":f[@"number"],@"wire":f[@"wire"]}mutableCopy];id v=f[@"value"];
  if([v isKindOfClass:NSNumber.class])row[@"value"]=v;else if([v isKindOfClass:NSData.class])row[@"bytes"]=@([v length]);[out addObject:row];if(out.count==32){if(fields.count>32)[out addObject:@{@"fields_omitted":@(fields.count-32)}];break;}}return out;}
static NSArray *rejectAlbum(NSMutableDictionary *proof,NSString *reason,NSString *path){proof[@"reason"]=reason;proof[@"field_path"]=path;return nil;}
static id diagnosticText(NSString *value){if(!value)return NSNull.null;if(value.length<=512)return value;return [[value substringWithRange:[value rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,512)]]stringByAppendingString:@"[truncated]"];}
static NSArray *albumTracks(NSData *data,NSString *uri,NSMutableDictionary *proof){NSArray *root=SAPProtoFields(data),*envelopes=messages(root,1);
 if(proof){proof[@"response_bytes"]=@(data.length);proof[@"expected_uri"]=uri;proof[@"root_shape"]=fieldShape(root);proof[@"envelope_count"]=@(envelopes.count);}
 if(envelopes.count!=1)return rejectAlbum(proof,@"invalid_metadata_envelope",@"response.item");NSArray *item=envelopes[0];NSNumber *error=num(item,1,@0);NSArray *albums=messages(item,3);
 if(proof){uint64_t encoded=error.unsignedLongLongValue;proof[@"item_shape"]=fieldShape(item);proof[@"native_error_wire_value"]=error?:NSNull.null;proof[@"native_error"]=error?@((int64_t)((encoded>>1)^(0ULL-(encoded&1)))):NSNull.null;proof[@"album_count"]=@(albums.count);}
 if(!error)return rejectAlbum(proof,@"malformed_native_error",@"item.error");
 if(error.unsignedLongLongValue)return rejectAlbum(proof,@"native_metadata_error",@"item.error");
 if(albums.count!=1)return rejectAlbum(proof,@"invalid_album_count",@"item.album");NSArray *album=albums[0];NSData *gid=scalar(album,1,2,nil);NSString *observed=gidURI(gid,@"album");
 if(proof){proof[@"album_shape"]=fieldShape(album);proof[@"gid_bytes"]=@(gid.length);proof[@"observed_uri"]=observed?:NSNull.null;proof[@"album_name"]=diagnosticText(string(album,2));proof[@"display_album_name_present"]=@(SAPProtoString(album,2).length>0);}
 if(![observed isEqual:uri])return rejectAlbum(proof,@"album_identity_mismatch",@"album.gid");
 // GetEntity contains membership references, often only Track.gid (field 1).
 // Display hydration (title/duration/track number) is not deletion authority.
 // Decode every declared member strictly; never skip a malformed disc or track.
 NSArray *discs=messages(album,11);if(proof)proof[@"disc_count"]=@(discs.count);if(!discs.count)return rejectAlbum(proof,@"missing_or_malformed_discs",@"album.disc");
 NSUInteger discIndex=0;NSMutableArray *out=NSMutableArray.array,*trackFields=proof?NSMutableArray.array:nil;NSMutableSet *seen=NSMutableSet.set;
 if(proof)proof[@"track_fields"]=trackFields;
 for(NSArray *disc in discs){
  NSArray *tracks=messages(disc,3);
  if(!tracks.count)return rejectAlbum(proof,@"missing_or_malformed_disc_tracks",[NSString stringWithFormat:@"album.disc[%lu].track",(unsigned long)discIndex]);
  NSUInteger trackIndex=0;
  for(NSArray *track in tracks){
   NSString *path=[NSString stringWithFormat:@"album.disc[%lu].track[%lu]",(unsigned long)discIndex,(unsigned long)trackIndex];
   BOOL hasGID=NO,hasURI=NO;for(NSDictionary *field in track){unsigned n=[field[@"number"]unsignedIntValue];hasGID|=n==1;hasURI|=n==36;}
   NSData *trackGID=scalar(track,1,2,nil);NSString *fromGID=gidURI(trackGID,@"track"),*canonical=string(track,36),*resolved=fromGID?:canonical;
   if(proof)[trackFields addObject:@{@"disc_index":@(discIndex),@"track_index":@(trackIndex),@"gid_bytes":@(trackGID.length),
    @"uri":diagnosticText(canonical),@"resolved_uri":resolved?:NSNull.null,@"identity_source":fromGID?@"gid":@"canonical_uri",@"field_shape":fieldShape(track)}];
   if(hasGID&&!fromGID)return rejectAlbum(proof,@"invalid_track_gid",[path stringByAppendingString:@".gid"]);
   if(hasURI&&!valid(canonical,@"track"))return rejectAlbum(proof,@"invalid_canonical_track_uri",[path stringByAppendingString:@".uri"]);
   if(fromGID&&hasURI&&![fromGID isEqual:canonical])return rejectAlbum(proof,@"track_identity_mismatch",path);
   if(!valid(resolved,@"track"))return rejectAlbum(proof,@"missing_track_identity",path);
   if([seen containsObject:resolved])return rejectAlbum(proof,@"duplicate_track_identity",path);
   [seen addObject:resolved];[out addObject:resolved];trackIndex++;
   if(out.count>1000)return rejectAlbum(proof,@"album_track_limit",@"album.disc.track");
  }
  discIndex++;
 }
 if(proof){proof[@"declared_track_count"]=@(out.count);proof[@"parsed_track_count"]=@(out.count);proof[@"membership_source"]=@"native_track_identities";}
 proof[@"reason"]=@"validated";return out;}

@interface SAPOfflineLibraryDelete:NSObject
@property(nonatomic,strong)SAPOfflineLibraryDelete *keepAlive;
@property(nonatomic,strong)NSProgress *progress;
@property(nonatomic,copy)NSArray *input,*uris,*libraryURIs,*contexts,*albumURIs,*playlistContexts;
@property(nonatomic,strong)NSSet *selected;
@property(nonatomic,strong)NSMutableDictionary *rows,*states,*saved,*latestStates,*latestSaved,*notes,*albumMembership;
@property(nonatomic,strong)NSMutableSet *safeAlbums;
@property(nonatomic,copy)void(^event)(NSDictionary *);
@property(nonatomic,copy)void(^completion)(NSArray *,NSString *);
@property(nonatomic,copy)dispatch_block_t cancelRead;
@property(nonatomic,strong)dispatch_source_t readDeadline,retry,phaseDeadline;
@property(nonatomic)NSUInteger epoch,offset,verifyAttempt;
@property(nonatomic)BOOL finished,cancelled,verifying;
@property(nonatomic)SAPTraceID traceID;
@property(nonatomic)uint64_t traceGeneration;
@property(nonatomic)NSUInteger traceVerificationCount;
- (void)begin;
- (void)finish:(NSString *)error;
- (void)finishBlockedByActiveDownload:(NSArray *)contexts;
- (void)cancel;
- (void)nextAlbum:(NSUInteger)index;
- (void)nextPlaylist:(NSUInteger)index;
- (void)removeTracks:(NSUInteger)index;
- (void)removeSavedTracks:(NSUInteger)index;
- (void)verify;
- (BOOL)allSelected:(NSArray *)items;
@end
@implementation SAPOfflineLibraryDelete
- (BOOL)tracing{return self.traceID&&SAPTraceIsActive()&&self.traceGeneration==SAPTraceGeneration();}
- (void)traceEntries:(NSArray *)entries stage:(const char *)stage facts:(NSDictionary *)facts {
 if(![self tracing])return;
 for(NSUInteger offset=0;offset<entries.count;offset+=8){if(![self tracing])return;NSMutableDictionary *event=[facts mutableCopy]?:NSMutableDictionary.dictionary;
  event[@"entries"]=[entries subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)8,entries.count-offset))];event[@"offset"]=@(offset);event[@"total"]=@(entries.count);DELETE_TRACE(stage,event);}
}
- (void)traceMembership:(NSString *)uri items:(NSArray *)items source:(NSString *)source {
 if(![self tracing])return;NSMutableArray *entries=NSMutableArray.array;NSUInteger selected=0;
 for(NSString *u in items){BOOL chosen=[self.selected containsObject:u];selected+=chosen;[entries addObject:@{@"uri":u,@"selected":@(chosen),@"supported_track_uri":@(valid(u,@"track"))}];}
 [self traceEntries:entries stage:"context_members" facts:@{@"context_uri":uri,@"source":source,@"member_count":@(items.count),@"selected_count":@(selected),@"all_selected":@([self allSelected:items])}];
}
- (BOOL)active{return !self.finished&&!self.cancelled&&!self.progress.cancelled;}
- (void)stopRead{self.epoch++;dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();if(self.readDeadline){dispatch_source_cancel(self.readDeadline);self.readDeadline=nil;}}
- (void)emit:(NSString *)phase uri:(NSString *)uri completed:(NSUInteger)completed{if(![self active])return;self.progress.completedUnitCount=MIN((int64_t)completed,self.progress.totalUnitCount);
 if(self.event)self.event(@{@"phase":phase,@"uri":uri?:@"",@"name":(uri?self.rows[uri][@"name"]:nil)?:@"",@"completed":@(completed),@"total":@(self.uris.count)});}
- (void)note:(NSString *)message uri:(NSString *)uri{if(!uri)return;NSMutableOrderedSet *a=self.notes[uri];if(!a){a=NSMutableOrderedSet.orderedSet;self.notes[uri]=a;}[a addObject:message];}
- (void)finish:(NSString *)error{if(self.finished)return;self.finished=YES;[self stopRead];for(dispatch_source_t timer in @[self.retry?:NSNull.null,self.phaseDeadline?:NSNull.null])if((id)timer!=NSNull.null)dispatch_source_cancel(timer);self.retry=nil;self.phaseDeadline=nil;
 NSMutableArray *results=NSMutableArray.array;BOOL retained=NO;
 for(NSString *u in self.uris){BOOL offline=self.latestStates[u]&&[self.latestStates[u]unsignedIntegerValue]==0;BOOL library=self.latestSaved[u]&&![self.latestSaved[u]boolValue];for(NSString *album in self.albumMembership[u])if([self.saved[album]boolValue]&&(!self.latestSaved[album]||[self.latestSaved[album]boolValue]))library=NO;
  if(!offline){retained=YES;[self note:self.latestStates[u]?@"Spotify still reports a download, pending policy, expired item, or error state.":@"Offline removal was not confirmed by an exact native readback." uri:u];}
  if(!library){retained=YES;[self note:@"Saved-library removal was not confirmed by an exact native readback." uri:u];}
  NSString *detail=[self.notes[u]array]?[[self.notes[u]array]componentsJoinedByString:@" "]:@"";
  [results addObject:@{@"uri":u,@"name":self.rows[u][@"name"]?:u,@"offline_removed":@(offline),@"library_removed":@(library),@"detail":detail}];}
 NSString *finalError=error?:retained?@"Spotify did not confirm removal of every selected track. Retained and uncertain results are listed individually.":nil;
 [self traceEntries:results stage:"result_items" facts:@{@"readback_required":@YES}];
 DELETE_TRACE("finished",@{@"cancelled":@(self.cancelled),@"selected_count":@(self.uris.count),@"unconfirmed_results":@(retained),@"verification_attempts":@(self.traceVerificationCount),@"error":finalError?:NSNull.null,@"success":@(!error.length&&!retained),@"filesystem_files_deleted_directly":@NO});
 void(^callback)(NSArray *,NSString *)=self.completion;self.completion=nil;self.event=nil;self.progress.cancellationHandler=nil;self.keepAlive=nil;
 if(callback)callback(results,finalError);}
// A context that is still requested/downloading/waiting (native states 2, 4, 5) keeps even its finished
// members under the album's policy, so removing them cannot work and ends in a long list of retained
// results. Stop before sending any command.
- (void)finishBlockedByActiveDownload:(NSArray *)contexts{
 if(self.finished)return;self.finished=YES;[self stopRead];for(dispatch_source_t timer in @[self.retry?:NSNull.null,self.phaseDeadline?:NSNull.null])if((id)timer!=NSNull.null)dispatch_source_cancel(timer);self.retry=nil;self.phaseDeadline=nil;
 DELETE_TRACE("blocked_active_download",@{@"contexts":contexts,@"commands_sent":@NO,@"automatic_replay":@NO});
 DELETE_TRACE("finished",@{@"cancelled":@NO,@"selected_count":@(self.uris.count),@"unconfirmed_results":@NO,@"verification_attempts":@0,@"error":SAPOfflineLibraryDeleteBusyError,@"success":@NO,@"blocked_by_active_download":@YES,@"filesystem_files_deleted_directly":@NO});
 void(^callback)(NSArray *,NSString *)=self.completion;self.completion=nil;self.event=nil;self.progress.cancellationHandler=nil;self.keepAlive=nil;
 if(callback)callback(@[],SAPOfflineLibraryDeleteBusyError);}
- (void)cancel{if(self.finished)return;self.cancelled=YES;[self finish:@"Deletion cancelled. Submitted native commands were not undone; unverified results remain uncertain."];}
- (void)read:(NSString *)service method:(NSString *)method payload:(NSData *)payload reply:(void(^)(NSData *,NSString *))reply{
 if(![self active])return;[self stopRead];NSUInteger epoch=self.epoch;
 DELETE_TRACE("read_requested",@{@"service":service,@"method":method,@"read_epoch":@(epoch),@"verifying":@(self.verifying)});
 self.readDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),12,^{if(![self active]||epoch!=self.epoch)return;DELETE_TRACE("read_timeout",@{@"service":service,@"method":method,@"read_epoch":@(epoch),@"seconds":@12});[self stopRead];reply(nil,@"Native read timed out.");});
 dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(service,method,payload,^(NSData *data,NSString *error){dispatch_async(dispatch_get_main_queue(),^{
  DELETE_TRACE("read_reply",@{@"service":service,@"method":method,@"read_epoch":@(epoch),@"response_bytes":@(data.length),@"response_received":@(data!=nil),@"error":error?:NSNull.null,@"ignored":@(![self active]||epoch!=self.epoch)});
  if(![self active]||epoch!=self.epoch)return;[self stopRead];reply(data,error);});});
 if([self active]&&epoch==self.epoch)self.cancelRead=cancel;else if(cancel)cancel();
}
- (void)readBatches:(NSArray *)uris saved:(BOOL)saved index:(NSUInteger)index into:(NSMutableDictionary *)out reply:(void(^)(BOOL))reply{
 if(![self active])return;if(index>=uris.count){reply(YES);return;}NSArray *batch=[uris subarrayWithRange:NSMakeRange(index,MIN(saved?64:128,uris.count-index))];NSMutableData *request=NSMutableData.data;
 for(NSString *u in batch)[request appendData:str(saved?3:1,u)];
 [self read:saved?Library:Offline method:saved?@"Contains":@"GetItems" payload:request reply:^(NSData *data,NSString *error){NSDictionary *values=error?nil:saved?parseSaved(data,batch):parseItems(data,batch);
  if([self tracing]){NSMutableArray *entries=NSMutableArray.array;for(NSString *u in batch)[entries addObject:@{@"uri":u,@"value":values[u]?:NSNull.null}];
   [self traceEntries:entries stage:"native_values" facts:@{@"method":saved?@"Contains":@"GetItems",@"verifying":@(self.verifying),@"parser_accepted":@(values!=nil),@"error":error?:NSNull.null,@"response_shape":values?@[]:fieldShape(SAPProtoFields(data))}];}
  if(!values){reply(NO);return;}[out addEntriesFromDictionary:values];[self readBatches:uris saved:saved index:index+batch.count into:out reply:reply];}];
}
- (BOOL)allSelected:(NSArray *)items{if(!items.count)return NO;for(id u in items)if(!valid(u,@"track")||![self.selected containsObject:u])return NO;return YES;}
- (void)begin{
 if(SAPTraceIsActive()){self.traceGeneration=SAPTraceGeneration();self.traceID=SAPTraceBegin(@"offline_library_delete",@"pixie",@{@"input_count":@([self.input isKindOfClass:NSArray.class]?self.input.count:0),@"automatic_replay":@NO});}
 NSMutableOrderedSet *ids=NSMutableOrderedSet.orderedSet,*albums=NSMutableOrderedSet.orderedSet;self.rows=NSMutableDictionary.dictionary;self.notes=NSMutableDictionary.dictionary;self.safeAlbums=NSMutableSet.set;self.albumMembership=NSMutableDictionary.dictionary;
 if(![self.input isKindOfClass:NSArray.class]||!self.input.count||self.input.count>10000){[self finish:@"Invalid or oversized track selection."];return;}
 for(id row in self.input){if(![row isKindOfClass:NSDictionary.class]||!valid(row[@"uri"],@"track")||(row[@"album_uri"]&&(![row[@"album_uri"]isKindOfClass:NSString.class]||([row[@"album_uri"]length]&&!valid(row[@"album_uri"],@"album"))))){[self finish:@"Invalid selected track or album identity. No commands were sent."];return;}
  NSString *u=row[@"uri"];if(self.rows[u]&&![self.rows[u][@"album_uri"]?:@"" isEqual:row[@"album_uri"]?:@""]){[self finish:@"Conflicting selected track identities. No commands were sent."];return;}
  [ids addObject:u];self.rows[u]=@{@"uri":u,@"name":[row[@"name"]isKindOfClass:NSString.class]?row[@"name"]:u,@"album_uri":row[@"album_uri"]?:@""};if(valid(row[@"album_uri"],@"album"))[albums addObject:row[@"album_uri"]];}
 self.uris=ids.array;self.selected=[NSSet setWithArray:self.uris];self.progress.totalUnitCount=self.uris.count;self.input=nil;if(self.progress.cancelled){[self cancel];return;}[self emit:@"checking" uri:nil completed:0];
 if([self tracing]){NSMutableArray *entries=NSMutableArray.array;for(NSString *u in self.uris)[entries addObject:self.rows[u]];[self traceEntries:entries stage:"selection" facts:@{@"selected_count":@(self.uris.count)}];}
 [self read:Offline method:@"GetContexts" payload:SAPProtoBytes(1,SAPProtoInteger(1,1)) reply:^(NSData *data,NSString *error){self.contexts=error?nil:parseContexts(data);if(!self.contexts){DELETE_TRACE("contexts_rejected",@{@"error":error?:NSNull.null,@"response_bytes":@(data.length),@"response_shape":fieldShape(SAPProtoFields(data)),@"reason":error?@"transport_error":@"native_context_parser_rejected",@"commands_sent":@NO});[self finish:@"Spotify did not return a complete valid native context baseline. No commands were sent."];return;}
  DELETE_TRACE("contexts_baseline",@{@"context_count":@(self.contexts.count),@"response_bytes":@(data.length),@"source":@"preflight_snapshot"});
  NSMutableArray *playlists=NSMutableArray.array,*busy=NSMutableArray.array;for(NSDictionary *context in self.contexts){NSString *u=context[@"uri"];BOOL intersects=NO;for(NSString *t in context[@"items"])if([self.selected containsObject:t]){intersects=YES;break;}if(!intersects)continue;
   NSUInteger contextState=[context[@"state"]unsignedIntegerValue];if(contextState==2||contextState==4||contextState==5)[busy addObject:@{@"uri":u?:@"",@"state":@(contextState)}];
   if(valid(u,@"album"))[albums addObject:u];if(valid(u,@"playlist"))[playlists addObject:context];
   [self traceMembership:u items:context[@"items"] source:@"native_context_preflight"];
   if(![self allSelected:context[@"items"]])for(NSString *t in context[@"items"])if([self.selected containsObject:t])[self note:[NSString stringWithFormat:@"Preserved %@ because it includes unselected or unsupported items.",u]uri:t];}
  if(busy.count){[self finishBlockedByActiveDownload:busy];return;}
  self.albumURIs=albums.array;self.playlistContexts=playlists;NSMutableOrderedSet *library=[NSMutableOrderedSet orderedSetWithArray:self.uris];[library addObjectsFromArray:self.albumURIs];self.libraryURIs=library.array;
  self.states=NSMutableDictionary.dictionary;self.saved=NSMutableDictionary.dictionary;
  [self readBatches:self.uris saved:NO index:0 into:self.states reply:^(BOOL ok){if(!ok){[self finish:@"Spotify omitted or returned invalid selected-item states. No commands were sent."];return;}
   [self readBatches:self.libraryURIs saved:YES index:0 into:self.saved reply:^(BOOL ok){if(!ok){[self finish:@"Spotify omitted or returned invalid saved-library flags. No commands were sent."];return;}[self nextAlbum:0];}];}];
 }];
}
// Mutations have their own bounded gate. A timeout advances to readback; late
// acknowledgements never advance twice, and the command is never submitted again.
- (void)command:(void(^)(dispatch_block_t))send method:(NSString *)method targets:(NSArray *)targets next:(dispatch_block_t)next{
 if(![self active])return;[self stopRead];NSUInteger epoch=self.epoch;
 [self traceEntries:targets stage:"command_requested" facts:@{@"method":method,@"command_epoch":@(epoch),@"automatic_replay":@NO}];
 void(^advance)(NSString *)=^(NSString *reason){dispatch_async(dispatch_get_main_queue(),^{
  DELETE_TRACE("command_gate",@{@"method":method,@"command_epoch":@(epoch),@"reason":reason,@"ignored":@(![self active]||epoch!=self.epoch),@"effect_confirmed":@NO});
  if(![self active]||epoch!=self.epoch)return;[self stopRead];next();});};
 dispatch_block_t done=^{advance(@"callback");};self.readDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),8,^{advance(@"timeout");});send(done);
}
- (void)removeLibrary:(NSArray *)uris next:(dispatch_block_t)next{if(!uris.count){next();return;}NSMutableData *payload=NSMutableData.data;for(NSString *u in uris)[payload appendData:SAPProtoBytes(2,str(1,u))];
 [self command:^(dispatch_block_t done){SAPInvokeServiceOnce(@"spotify.collection_esperanto.proto.CollectionService",@"Remove",payload,^(NSData *d,NSString *e,SAPCommandInvocationDisposition disposition){
  DELETE_TRACE("command_reply",@{@"method":@"Collection.Remove",@"targets":uris,@"transport_invoked":@(disposition==SAPCommandInvoked),@"response_received":@(d!=nil),@"response_bytes":@(d.length),@"response_shape":fieldShape(SAPProtoFields(d)),@"error":e?:NSNull.null,@"effect_confirmed":@NO});done();});}method:@"Collection.Remove" targets:uris next:next];}
- (void)nextAlbum:(NSUInteger)index{
 if(![self active])return;if(index>=self.albumURIs.count){[self nextPlaylist:0];return;}NSString *u=self.albumURIs[index];NSDictionary *context=nil;for(NSDictionary *c in self.contexts)if([c[@"uri"]isEqual:u]){context=c;break;}
 if(context&&![self allSelected:context[@"items"]]){DELETE_TRACE("album_preserved",@{@"uri":u,@"reason":@"native_context_contains_unselected_or_unsupported_tracks"});dispatch_async(dispatch_get_main_queue(),^{[self nextAlbum:index+1];});return;}
 [self read:@"spotify.metadata_esperanto.proto.ClassicMetadataService" method:@"GetEntity" payload:str(1,u) reply:^(NSData *data,NSString *error){NSMutableDictionary *proof=[self tracing]?NSMutableDictionary.dictionary:nil;NSArray *tracks=error?nil:albumTracks(data,u,proof);
  if([self tracing]){NSArray *fields=proof[@"track_fields"];[proof removeObjectForKey:@"track_fields"];
   proof[@"expected_uri"]=u;proof[@"response_bytes"]=@(data.length);proof[@"transport_error"]=error?:NSNull.null;proof[@"accepted"]=@(tracks!=nil);
   if(error)proof[@"reason"]=@"transport_error";DELETE_TRACE("album_metadata",proof);
   [self traceEntries:fields stage:"album_track_fields" facts:@{@"album_uri":u,@"source":@"received_metadata_fields",@"absent_values":@"null; membership requires identity, not display hydration"}];
   if(tracks)[self traceMembership:u items:tracks source:@"validated_album_metadata"];
   DELETE_TRACE("album_decision",@{@"uri":u,@"metadata_valid":@(tracks!=nil),@"all_tracks_selected":@([self allSelected:tracks]),@"native_context_present":@(context!=nil),@"saved_at_preflight":self.saved[u]?:NSNull.null,@"policy_reset_authorized":@(context&&[self allSelected:tracks])});}
  if(![self allSelected:tracks]){for(NSString *t in self.uris)if([self.rows[t][@"album_uri"]isEqual:u])[self note:@"Saved album and album download policy were preserved: full selected membership was not proven." uri:t];[self nextAlbum:index+1];return;}
  [self.safeAlbums addObject:u];for(NSString *track in tracks){NSMutableSet *members=self.albumMembership[track];if(!members){members=NSMutableSet.set;self.albumMembership[track]=members;}[members addObject:u];}dispatch_block_t removeSaved=^{[self removeLibrary:[self.saved[u]boolValue]?@[u]:@[] next:^{[self nextAlbum:index+1];}];};
  if(context){[self emit:@"removing" uri:tracks[0] completed:0];[self command:^(dispatch_block_t done){SAPResetEntityOffline(u,^(BOOL attempted,NSString *failure){
   DELETE_TRACE("command_reply",@{@"method":@"resetEntityOfflineAvailabilityWithURL:",@"uri":u,@"handler_returned":@(attempted),@"error":failure?:NSNull.null,@"effect_confirmed":@NO});done();});}method:@"resetEntityOfflineAvailabilityWithURL:" targets:@[u] next:removeSaved];}else removeSaved();
 }];
}
- (void)nextPlaylist:(NSUInteger)index{
 if(![self active])return;if(index>=self.playlistContexts.count){[self removeTracks:0];return;}NSDictionary *c=self.playlistContexts[index];NSString *u=c[@"uri"];
 if(![self allSelected:c[@"items"]]){DELETE_TRACE("playlist_preserved",@{@"uri":u,@"reason":@"native_context_contains_unselected_or_unsupported_tracks"});dispatch_async(dispatch_get_main_queue(),^{[self nextPlaylist:index+1];});return;}[self stopRead];NSUInteger epoch=self.epoch;
 void(^reply)(NSDictionary *,NSString *)=^(NSDictionary *list,NSString *error){dispatch_async(dispatch_get_main_queue(),^{if(![self active]||epoch!=self.epoch)return;[self stopRead];NSArray *items=[list[@"items"]isKindOfClass:NSArray.class]?list[@"items"]:nil;NSNumber *total=[list[@"total"]isKindOfClass:NSNumber.class]?list[@"total"]:nil;
  [self traceMembership:u items:items source:@"fresh_complete_playlist_read"];
  DELETE_TRACE("playlist_decision",@{@"uri":u,@"error":error?:NSNull.null,@"declared_total":total?:NSNull.null,@"received_count":@(items.count),@"revision":list[@"revision"]?:NSNull.null,@"policy_reset_authorized":@(!error&&total&&items.count==total.unsignedIntegerValue&&[self allSelected:items])});
  if(error||!total||items.count!=total.unsignedIntegerValue||![self allSelected:items]){for(NSString *t in c[@"items"])[self note:@"Playlist policy was preserved: its current full selected membership was not proven." uri:t];[self nextPlaylist:index+1];return;}
  [self command:^(dispatch_block_t done){SAPSetPlaylistOfflineOnceWithDisposition(u,NO,^(NSData *d,NSString *e,SAPCommandInvocationDisposition disposition){
   DELETE_TRACE("command_reply",@{@"method":@"SetPlaylistOffline",@"uri":u,@"enabled":@NO,@"transport_invoked":@(disposition==SAPCommandInvoked),@"response_received":@(d!=nil),@"response_bytes":@(d.length),@"error":e?:NSNull.null,@"effect_confirmed":@NO});done();});}method:@"SetPlaylistOffline" targets:@[u] next:^{[self nextPlaylist:index+1];}];});};
 self.readDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),12,^{reply(nil,@"Playlist read timed out.");});
 dispatch_block_t cancel=SAPFetchPlaylistContents(u,reply);if([self active]&&epoch==self.epoch)self.cancelRead=cancel;else if(cancel)cancel();
}
- (void)removeTracks:(NSUInteger)index{
 if(![self active])return;if(index>=self.uris.count){[self removeSavedTracks:0];return;}NSString *u=self.uris[index];
 [self read:Offline method:@"GetItems" payload:str(1,u) reply:^(NSData *data,NSString *error){NSDictionary *state=error?nil:parseItems(data,@[u]);if(!state){[self note:@"Targeted removal was skipped because its current native state could not be read." uri:u];[self removeTracks:index+1];return;}
  DELETE_TRACE("track_decision",@{@"uri":u,@"current_state":state[u],@"not_downloaded_state":@0,@"remove_requested":@([state[u]unsignedIntegerValue]!=0)});
  if([state[u]unsignedIntegerValue]==0){[self removeTracks:index+1];return;}[self emit:@"removing" uri:u completed:index];
  [self command:^(dispatch_block_t done){SAPCallOfflineCommandOnceWithDisposition(@"RemoveDownload",str(2,u),^(NSData *d,NSString *e,SAPCommandInvocationDisposition disposition){
   DELETE_TRACE("command_reply",@{@"method":@"RemoveDownload",@"uri":u,@"transport_invoked":@(disposition==SAPCommandInvoked),@"response_received":@(d!=nil),@"response_bytes":@(d.length),@"response_shape":fieldShape(SAPProtoFields(d)),@"error":e?:NSNull.null,@"effect_confirmed":@NO});done();});}method:@"RemoveDownload" targets:@[u] next:^{[self removeTracks:index+1];}];
 }];
}
- (void)removeSavedTracks:(NSUInteger)index{
 if(![self active])return;if(index>=self.uris.count){self.verifyAttempt=0;self.verifying=YES;
  self.phaseDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),8,^{[self finish:@"Native verification timed out. Unconfirmed removals remain uncertain."];});[self verify];return;}
 NSArray *batch=[self.uris subarrayWithRange:NSMakeRange(index,MIN((NSUInteger)64,self.uris.count-index))];NSMutableArray *remove=NSMutableArray.array;for(NSString *u in batch)if([self.saved[u]boolValue])[remove addObject:u];
 [self removeLibrary:remove next:^{[self removeSavedTracks:index+batch.count];}];
}
- (void)verify{
 if(![self active])return;if([self tracing])self.traceVerificationCount++;[self emit:@"verifying" uri:nil completed:0];NSMutableDictionary *states=NSMutableDictionary.dictionary,*saved=NSMutableDictionary.dictionary;self.latestStates=nil;self.latestSaved=nil;
 [self readBatches:self.uris saved:NO index:0 into:states reply:^(BOOL offlineOK){self.latestStates=offlineOK?states:nil;
  [self readBatches:self.libraryURIs saved:YES index:0 into:saved reply:^(BOOL savedOK){self.latestSaved=savedOK?saved:nil;BOOL complete=offlineOK&&savedOK;
   for(NSString *u in self.uris)if([states[u]unsignedIntegerValue]!=0||!states[u]||!saved[u]||[saved[u]boolValue])complete=NO;
   // Album readbacks are included even though each row's library flag refers to
   // the selected track. A saved album that remains is reported explicitly.
   for(NSString *a in self.safeAlbums)if([self.saved[a]boolValue]&&(!saved[a]||[saved[a]boolValue]))complete=NO;
   for(NSString *a in self.albumURIs)if([saved[a]boolValue])for(NSString *u in self.uris)if([self.rows[u][@"album_uri"]isEqual:a]||[self.albumMembership[u]containsObject:a])[self note:[self.safeAlbums containsObject:a]?@"Spotify still reports the wholly selected album as saved.":@"The associated saved album was preserved." uri:u];
   if([self tracing]){NSMutableArray *entries=NSMutableArray.array;
    for(NSString *u in self.uris)[entries addObject:@{@"uri":u,@"before_state":self.states[u]?:NSNull.null,@"after_state":self.latestStates[u]?:NSNull.null,@"before_saved":self.saved[u]?:NSNull.null,@"after_saved":self.latestSaved[u]?:NSNull.null,@"offline_removed":@(self.latestStates[u]&&[self.latestStates[u]unsignedIntegerValue]==0),@"not_downloaded_state":@0}];
    [self traceEntries:entries stage:"verified_items" facts:@{@"attempt":@(self.verifyAttempt+1),@"offline_read_valid":@(offlineOK),@"library_read_valid":@(savedOK),@"complete":@(complete),@"holding_contexts_source":@"preflight snapshot only; not queried again by verification"}];}
   if(complete){[self emit:@"finished" uri:nil completed:self.uris.count];[self finish:nil];return;}
   if(++self.verifyAttempt>=5){[self finish:nil];return;}
   self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),.25,^{self.retry=nil;[self verify];});
  }];
 }];
}
@end
NSProgress *SAPDeleteOfflineLibrarySelection(NSArray<NSDictionary *> *rows,void(^event)(NSDictionary *),void(^completion)(NSArray *,NSString *)){
 // Freeze the confirmed identities before the asynchronous start. Copying only
 // the array would let a mutable caller row change the deletion target.
 id snapshot=rows;
 if([rows isKindOfClass:NSArray.class]){NSMutableArray *values=NSMutableArray.array;for(id row in rows){if(![row isKindOfClass:NSDictionary.class]){[values addObject:row];continue;}NSMutableDictionary *value=NSMutableDictionary.dictionary;for(NSString *key in @[@"uri",@"name",@"album_uri"]){id field=row[key];if(field)value[key]=[field isKindOfClass:NSString.class]?[field copy]:field;}[values addObject:[value copy]];}snapshot=[values copy];}
 SAPOfflineLibraryDelete *op=SAPOfflineLibraryDelete.new;op.keepAlive=op;op.input=snapshot;op.event=event;op.completion=completion;op.progress=[NSProgress progressWithTotalUnitCount:[rows isKindOfClass:NSArray.class]?rows.count:0];
 __weak SAPOfflineLibraryDelete *weakOp=op;op.progress.cancellationHandler=^{dispatch_async(dispatch_get_main_queue(),^{[weakOp cancel];});};dispatch_async(dispatch_get_main_queue(),^{[op begin];});return op.progress;
}
