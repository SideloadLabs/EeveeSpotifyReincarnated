#import "PlaylistDownloadsInternal.h"

NSString *const SAPPlaylistLibraryService=@"spotify.your_library_esperanto.proto.YourLibraryService";
NSString *const SAPPlaylistDataService=@"spotify.playlist_esperanto.proto.PlaylistDataService";

NSDictionary *SAPParseWritablePlaylistPage(NSData *data,NSString **error){
    NSArray *fields=SAPProtoFields(data),*header=SAPProtoFields(SAPProtoData(fields,1));
    if(!fields || !header || SAPProtoNumber(fields,98,0)!=200 || SAPProtoString(fields,99).length){
        if(error)*error=SAPProtoString(fields,99)?:@"Spotify did not return a valid Your Library response.";return nil;
    }
    if(SAPProtoNumber(header,12,0)){if(error)*error=@"Playlist contents are still loading.";return nil;}
    NSMutableArray *entries=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];NSUInteger consumed=0;
    for(NSNumber *field in @[@2,@3])for(NSArray *entry in SAPPlaylistMessages(fields,field.unsignedIntValue)){
        consumed++;NSArray *info=SAPProtoFields(SAPProtoData(entry,1)),*extra=SAPProtoFields(SAPProtoData(entry,4));NSString *uri=SAPProtoString(info,3);
        if(!SAPIsPlaylistURI(uri) || !SAPProtoNumber(extra,9,0) || SAPProtoNumber(extra,5,0) || [seen containsObject:uri])continue;
        [seen addObject:uri];NSArray *kinds=SAPPlaylistMessages(extra,12);NSUInteger count=0;for(NSArray *kind in kinds){uint64_t type=SAPProtoNumber(kind,1,0);if(type==4 || type==9)count+=SAPProtoNumber(kind,2,0);}
        NSMutableDictionary *row=[@{@"uri":uri,@"name":SAPProtoString(info,2)?:@"Playlist",@"cover_uri":SAPProtoString(info,6)?:@"",@"cover_url":SAPPlaylistArtworkURL(SAPProtoString(info,6))}mutableCopy];if(kinds.count)row[@"track_count"]=@(count);[entries addObject:row];
    }
    return @{@"playlists":entries,@"consumed":@(consumed),@"remaining":@(SAPProtoNumber(header,9,0))};
}
static NSData *contentsRequest(NSString *uri,NSUInteger start){
    NSMutableData *range=[SAPProtoInteger(1,start)mutableCopy];[range appendData:SAPProtoInteger(2,SAPPlaylistPageSize)];
    NSMutableData *query=[SAPProtoBytes(4,range)mutableCopy];[query appendData:SAPProtoInteger(8,1)];[query appendData:SAPProtoInteger(17,1)];
    NSMutableData *playlistPolicy=[NSMutableData data];for(NSNumber *field in @[@2,@3,@5,@9,@42])[playlistPolicy appendData:SAPProtoInteger(field.unsignedIntValue,1)];
    [playlistPolicy appendData:SAPProtoBytes(35,SAPProtoInteger(1,1))];
    NSMutableData *policy=[SAPProtoBytes(1,playlistPolicy)mutableCopy];[policy appendData:SAPProtoBytes(4,SAPProtoInteger(1,1))];
    NSMutableData *request=[SAPPlaylistString(1,uri)mutableCopy];[request appendData:SAPProtoBytes(2,query)];[request appendData:SAPProtoBytes(3,policy)];return request;
}
NSDictionary *SAPParsePlaylistContents(NSData *data,NSString *uri,NSString **error){
    NSArray *fields=SAPProtoFields(data);if(!SAPPlaylistStatusOK(fields,error))return nil;
    NSArray *response=SAPProtoFields(SAPProtoData(fields,2)),*playlist=SAPProtoFields(SAPProtoData(response,2)),*metadata=SAPProtoFields(SAPProtoData(playlist,1));
    if(SAPProtoNumber(response,6,0) || ([SAPProtoString(metadata,1)isEqual:uri] && !SAPProtoNumber(metadata,17,0))){if(error)*error=@"Playlist contents are still loading.";return nil;}
    if(!SAPIsPlaylistURI(uri) || ![SAPProtoString(metadata,1)isEqual:uri]){
        if(error)*error=@"Spotify did not return a loaded playlist with the expected identity.";return nil;
    }
    NSUInteger total=SAPPlaylistHasField(response,4)?SAPProtoNumber(response,4,0):SAPProtoNumber(metadata,6,0);
    if(total>SAPPlaylistMaximumItems){if(error)*error=@"This playlist exceeds the supported 10,000-item limit.";return nil;}
    NSMutableArray *items=[NSMutableArray array];for(NSArray *entry in SAPPlaylistMessages(response,1)){
        NSString *item=SAPProtoString(entry,18);if(!item.length){if(error)*error=@"Spotify returned a playlist item without its identity. Nothing was appended.";return nil;}[items addObject:item];
    }
    NSArray *allows=SAPProtoFields(SAPProtoData(metadata,18)),*caps=SAPProtoFields(SAPProtoData(response,24));
    return @{@"items":items,@"total":@(total),@"revision":@(SAPProtoNumber(response,7,0)),@"can_add":@(SAPProtoNumber(allows,1,0)||SAPProtoNumber(caps,5,0)),@"name":SAPProtoString(metadata,2)?:@"Playlist"};
}

@interface SAPPlaylistRead : NSObject
@property(nonatomic,strong) SAPPlaylistRead *keepAlive;
@property(nonatomic,strong) NSMutableArray *items;
@property(nonatomic,strong) NSMutableSet *seen;
@property(nonatomic,copy) NSString *uri;
@property(nonatomic,copy) dispatch_block_t cancelRead;
@property(nonatomic,strong) dispatch_source_t retry;
@property(nonatomic,copy) void (^completion)(id,NSString *);
@property(nonatomic) NSUInteger offset,initialOffset,epoch,pages,loadingAttempts;
@property(nonatomic,strong) NSDictionary *firstPage;
@property(nonatomic) BOOL finished;
- (void)next;
- (void)finish:(id)result error:(NSString *)error;
@end
@implementation SAPPlaylistRead
- (void)finish:(id)result error:(NSString *)error {
    if(self.finished)return;self.finished=YES;self.epoch++;dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();
    if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}
    void (^reply)(id,NSString *)=self.completion;self.completion=nil;self.keepAlive=nil;if(reply)reply(result,error);
}
- (void)next {
    if(self.finished)return;if(++self.pages>64){[self finish:nil error:@"Spotify returned too many playlist pages."];return;}
    NSUInteger epoch=++self.epoch;NSData *request;NSString *service,*method=@"Get";
    if(self.uri){service=SAPPlaylistDataService;request=contentsRequest(self.uri,self.offset);}
    else {
        service=SAPPlaylistLibraryService;method=@"All";NSMutableData *header=[SAPProtoInteger(9,1)mutableCopy];
        for(NSArray *pair in @[@[@11,@(self.offset)],@[@12,@(SAPPlaylistPageSize)],@[@17,@1],@[@25,@1],@[@26,@1]])[header appendData:SAPProtoInteger([pair[0]unsignedIntValue],[pair[1]unsignedIntegerValue])];
        request=SAPProtoBytes(1,header);
    }
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(service,method,request,^(NSData *data,NSString *failure){
        if(self.finished || epoch!=self.epoch)return;self.cancelRead=nil;NSString *error=failure;NSDictionary *page=failure?nil:(self.uri?SAPParsePlaylistContents(data,self.uri,&error):SAPParseWritablePlaylistPage(data,&error));
        if(!page){
            if([error isEqual:@"Playlist contents are still loading."] && self.loadingAttempts<5){NSUInteger attempt=++self.loadingAttempts;self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MIN(3,attempt)*.5,^{self.retry=nil;if(!self.finished && self.epoch==epoch)[self next];});return;}
            [self finish:nil error:error?:@"Spotify did not return the playlist data."];return;
        }self.loadingAttempts=0;
        if(self.uri){
            if(!self.firstPage)self.firstPage=page;
            else if(![self.firstPage[@"total"]isEqual:page[@"total"]] || ![self.firstPage[@"revision"]isEqual:page[@"revision"]]){[self finish:nil error:@"The playlist changed while being read. Retry to use its current contents."];return;}
            [self.items addObjectsFromArray:page[@"items"]];self.offset=self.initialOffset+self.items.count;
            if(self.offset>[page[@"total"]unsignedIntegerValue]){[self finish:nil error:@"Spotify returned inconsistent playlist counts."];return;}
            if(self.offset==[page[@"total"]unsignedIntegerValue]){NSMutableDictionary *result=[self.firstPage mutableCopy];result[@"items"]=[self.items copy];[self finish:result error:nil];return;}
            if(![page[@"items"]count]){[self finish:nil error:@"Spotify returned an incomplete playlist page."];return;}
        }else{
            for(NSDictionary *entry in page[@"playlists"])if(![self.seen containsObject:entry[@"uri"]]){[self.seen addObject:entry[@"uri"]];[self.items addObject:entry];}
            self.offset+=[page[@"consumed"]unsignedIntegerValue];
            if(![page[@"remaining"]unsignedIntegerValue]){[self finish:[self.items copy] error:nil];return;}
            if(![page[@"consumed"]unsignedIntegerValue] || self.offset>SAPPlaylistMaximumItems){[self finish:nil error:@"Spotify returned an incomplete library page."];return;}
        }
        [self next];
    });
    if(!self.finished && epoch==self.epoch)self.cancelRead=cancel;else if(cancel)cancel();
}
@end
dispatch_block_t SAPPlaylistReadListFrom(NSString *uri,NSUInteger start,void (^completion)(id,NSString *)){
    SAPPlaylistRead *read=[SAPPlaylistRead new];read.uri=uri;read.offset=start;read.initialOffset=start;read.items=[NSMutableArray array];read.seen=[NSMutableSet set];read.completion=completion;read.keepAlive=read;
    dispatch_async(dispatch_get_main_queue(),^{[read next];});return ^{read.completion=nil;[read finish:nil error:nil];};
}
dispatch_block_t SAPPlaylistReadList(NSString *uri,void (^completion)(id,NSString *)){return SAPPlaylistReadListFrom(uri,0,completion);}
dispatch_block_t SAPFetchWritablePlaylists(void (^completion)(NSArray *,NSString *)) {return SAPPlaylistReadList(nil,completion);}
dispatch_block_t SAPFetchPlaylistContents(NSString *uri,void (^completion)(NSDictionary *,NSString *)) {
    if(!completion)return ^{};
    NSString *prefix=@"spotify:playlist:";
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    if(![uri isKindOfClass:NSString.class]||![uri hasPrefix:prefix]||uri.length!=prefix.length+22||[[uri substringFromIndex:prefix.length]rangeOfCharacterFromSet:invalid].location!=NSNotFound) {
        __block BOOL cancelled=NO;dispatch_async(dispatch_get_main_queue(),^{if(!cancelled)completion(nil,@"Invalid playlist identity.");});return ^{cancelled=YES;};
    }
    return SAPPlaylistReadList(uri,^(id value,NSString *error){completion([value isKindOfClass:NSDictionary.class]?value:nil,error);});
}

