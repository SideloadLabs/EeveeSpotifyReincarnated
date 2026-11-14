#import "TemporaryOfflineExport.h"
#import "SpotifyTransport.h"
#import "ExportNativeAdapters.h"
#import "WireProto.h"

static NSString *const offlineService=@"spotify.offline_esperanto.proto.Offline";
static NSString *const libraryService=@"spotify.your_library_esperanto.proto.YourLibraryService";
enum { maximumLibraryURIs=64, maximumVerificationReads=3 };
static void onMain(dispatch_block_t block) {if(NSThread.isMainThread)block();else dispatch_async(dispatch_get_main_queue(),block);}
static BOOL validURI(id value,NSString *kind) {
    if(![value isKindOfClass:NSString.class])return NO;
    NSString *prefix=[NSString stringWithFormat:@"spotify:%@:",kind];NSString *uri=value;
    if(![uri hasPrefix:prefix]||uri.length!=prefix.length+22)return NO;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    return [[uri substringFromIndex:prefix.length]rangeOfCharacterFromSet:invalid].location==NSNotFound;
}
// Proto3 permits omission of a default scalar, but an explicit wrong wire type
// or duplicate scalar is ambiguous. A missing entity entry is never a default.
static NSNumber *number(NSArray *fields,unsigned field,uint64_t fallback,BOOL required) {
    NSNumber *result=nil;NSUInteger count=0;
    if(!fields)return nil;
    for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==field) {
        if(++count>1||[f[@"wire"]unsignedIntValue]!=0)return nil;result=f[@"value"];
    }
    return result?:required?nil:@(fallback);
}
static NSString *string(NSArray *fields,unsigned field) {
    NSString *result=nil;NSUInteger count=0;
    for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==field) {
        if(++count>1||[f[@"wire"]unsignedIntValue]!=2)return nil;
        result=[[NSString alloc]initWithData:f[@"value"] encoding:NSUTF8StringEncoding];
    }
    return result;
}
// Spotify 9.1.98 reports a track it never downloaded as state 0 (the proto3
// default), where older builds reported 1 after a removal. Both mean "absent".
static BOOL absentOfflineState(NSUInteger state) {return state<=1;}
// An album is prepared track by track with the same Offline.AddDownload that a
// single track uses: a native album context never starts for an unsaved album.
static NSArray<NSString *> *offlineTargets(NSString *target,NSArray<NSDictionary *> *tracks) {
    if(!validURI(target,@"album"))return @[target];
    NSMutableOrderedSet *uris=[NSMutableOrderedSet orderedSet];
    for(NSDictionary *track in tracks)if(validURI(track[@"uri"],@"track"))[uris addObject:track[@"uri"]];
    return uris.array;
}
// Exact state of every requested track. A missing, duplicated or malformed
// entry is ambiguous and refuses the whole answer.
static NSDictionary *parseOffline(NSData *data,NSArray<NSString *> *targets) {
    NSArray *fields=SAPProtoFields(data);NSMutableDictionary *result=[NSMutableDictionary dictionary];
    NSNumber *error=number(fields,2,0,NO);if(!error||error.unsignedLongLongValue)return nil;
    for(NSDictionary *f in fields) {
        if([f[@"number"]unsignedIntValue]!=1||[f[@"wire"]unsignedIntValue]!=2)continue;
        NSArray *item=SAPProtoFields(f[@"value"]);NSString *uri=string(item,1);
        if(![targets containsObject:uri])continue;
        if(result[uri])return nil;
        NSNumber *state=number(item,2,0,NO);if(!state||state.unsignedIntegerValue>6)return nil;
        result[uri]=state;
    }
    return result.count==targets.count?[result copy]:nil;
}
static void readOffline(NSArray<NSString *> *targets,void (^completion)(NSDictionary *,NSString *)) {
    NSMutableData *request=[NSMutableData data];
    for(NSString *uri in targets)[request appendData:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])];
    SAPCallReadOnlyService(offlineService,@"GetItems",request,^(NSData *data,NSString *error){
        onMain(^{NSDictionary *states=error.length?nil:parseOffline(data,targets);completion(states,states?nil:error?:@"Spotify did not return the exact download state. Temporary preparation was refused.");});
    });
}
static NSDictionary *parseLibrary(NSData *data,NSArray<NSString *> *uris) {
    NSArray *fields=SAPProtoFields(data);NSNumber *status=number(fields,98,0,YES);
    if(status.unsignedLongLongValue!=200||SAPProtoString(fields,99).length)return nil;
    NSSet *wanted=[NSSet setWithArray:uris];NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSDictionary *f in fields) {
        if([f[@"number"]unsignedIntValue]!=2||[f[@"wire"]unsignedIntValue]!=2)continue;
        NSArray *entry=SAPProtoFields(f[@"value"]);NSString *uri=string(entry,1);
        if(!uri||![wanted containsObject:uri])continue;
        NSNumber *member=number(entry,2,0,NO);
        if(!member||member.unsignedLongLongValue>1||result[uri])return nil;
        result[uri]=@([member boolValue]);
    }
    return result.count==uris.count?[result copy]:nil;
}
static void readLibrary(NSArray<NSString *> *uris,void (^completion)(NSDictionary *,NSString *)) {
    NSMutableData *request=[NSMutableData data];
    for(NSString *uri in uris)[request appendData:SAPProtoBytes(3,[uri dataUsingEncoding:NSUTF8StringEncoding])];
    SAPCallReadOnlyService(libraryService,@"Contains",request,^(NSData *data,NSString *error){
        onMain(^{NSDictionary *states=error.length?nil:parseLibrary(data,uris);completion(states,states?nil:error?:@"Spotify did not report every saved-library entry. Temporary preparation was refused.");});
    });
}

@interface SAPTemporaryOfflineExportState:NSObject
@property(nonatomic,copy) NSString *target;
@property(nonatomic,copy) NSArray<NSString *> *removable;
@property(nonatomic,copy) NSArray<NSString *> *libraryURIs;
@property(nonatomic,copy) NSDictionary *saved;
@property(nonatomic) BOOL cleanupStarted,cleanupFinished;
@property(nonatomic,copy) NSString *cleanupError;
@property(nonatomic,strong) NSMutableArray *completions;
- (void)finish:(NSString *)error;
- (void)removeDownload:(NSUInteger)index;
- (void)verifyOffline:(NSUInteger)attempt;
- (void)restoreLibrary;
- (void)verifyLibrary:(NSUInteger)attempt;
@end
@implementation SAPTemporaryOfflineExportState
- (void)finish:(NSString *)error {
    if(self.cleanupFinished)return;self.cleanupFinished=YES;self.cleanupError=error;
    NSArray *callbacks=[self.completions copy];self.completions=nil;
    for(void (^completion)(NSString *) in callbacks)completion(error);
}
- (void)removeDownload:(NSUInteger)index {
    if(index>=self.removable.count){[self verifyOffline:0];return;}
    SAPCallOfflineCommandOnce(@"RemoveDownload",SAPProtoBytes(2,[self.removable[index] dataUsingEncoding:NSUTF8StringEncoding]),^(__unused NSData *data,__unused NSString *error){onMain(^{[self removeDownload:index+1];});});
}
- (void)verifyOffline:(NSUInteger)attempt {
    readOffline(self.removable,^(NSDictionary *states,__unused NSString *error){
        BOOL absent=states.count==self.removable.count;
        for(NSNumber *state in states.allValues)if(!absentOfflineState(state.unsignedIntegerValue))absent=NO;
        if(absent){[self restoreLibrary];return;}
        if(attempt+1>=maximumVerificationReads){[self finish:@"Spotify did not confirm removal of the temporary download. Saved library entries were left unchanged; cleanup is uncertain."];return;}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self verifyOffline:attempt+1];});
    });
}
- (void)restoreLibrary {
    readLibrary(self.libraryURIs,^(NSDictionary *current,__unused NSString *error){
        if(!current){[self finish:@"Spotify did not confirm the current saved-library entries. No library removals were sent; cleanup is uncertain."];return;}
        NSMutableArray *created=[NSMutableArray array];
        for(NSString *uri in self.libraryURIs)if(![self.saved[uri]boolValue]&&[current[uri]boolValue])[created addObject:uri];
        if(!created.count){
            [self finish:[current isEqual:self.saved]?nil:@"Spotify's saved-library state changed during export. Existing entries were preserved; the original state could not be confirmed."];return;
        }
        NSMutableData *request=[NSMutableData data];
        for(NSString *uri in created) {
            if(!validURI(uri,@"track")&&!validURI(uri,@"album")){[self finish:@"Invalid temporary library identity. No library removals were sent."];return;}
            [request appendData:SAPProtoBytes(2,SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]))];
        }
        // One verified transport invocation; even a timeout is followed only
        // by readbacks. The mutation itself is never replayed.
        SAPInvokeServiceOnce(@"spotify.collection_esperanto.proto.CollectionService",@"Remove",request,^(__unused NSData *data,__unused NSString *failure,__unused SAPCommandInvocationDisposition disposition){onMain(^{[self verifyLibrary:0];});});
    });
}
- (void)verifyLibrary:(NSUInteger)attempt {
    readLibrary(self.libraryURIs,^(NSDictionary *current,__unused NSString *error){
        if(current&&[current isEqual:self.saved]){[self finish:nil];return;}
        if(attempt+1>=maximumVerificationReads){[self finish:@"Spotify did not confirm restoration of the saved-library flags. No removal was sent again; cleanup is uncertain."];return;}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self verifyLibrary:attempt+1];});
    });
}
@end

void SAPCaptureTemporaryOfflineExport(NSString *targetURI,NSArray<NSDictionary *> *resolvedTracks,
    void (^completion)(NSDictionary *,NSString *)) {
    if(!completion)return;
    onMain(^{
        if((!validURI(targetURI,@"track")&&!validURI(targetURI,@"album"))||![resolvedTracks isKindOfClass:NSArray.class]||!resolvedTracks.count||resolvedTracks.count>1000){completion(nil,@"Invalid or oversized temporary export preparation.");return;}
        NSMutableOrderedSet *uris=[NSMutableOrderedSet orderedSetWithObject:targetURI];
        for(NSDictionary *track in resolvedTracks) {
            if(![track isKindOfClass:NSDictionary.class]||!validURI(track[@"uri"],@"track")||!validURI(track[@"album_uri"],@"album")){completion(nil,@"Associated album identity is unavailable. Temporary preparation was refused.");return;}
            [uris addObject:track[@"album_uri"]];
            if(uris.count>maximumLibraryURIs){completion(nil,@"Temporary sharing supports at most 64 distinct library identities. Choose a smaller selection.");return;}
        }
        NSString *target=[targetURI copy];NSArray *libraryURIs=[uris.array copy];NSArray *targets=offlineTargets(target,resolvedTracks);
        if(!targets.count){completion(nil,@"No exact track identities were resolved. Temporary preparation was refused.");return;}
        readOffline(targets,^(NSDictionary *states,NSString *error){
            if(!states){completion(nil,error);return;}
            readLibrary(libraryURIs,^(NSDictionary *saved,NSString *failure){
                if(!saved){completion(nil,failure);return;}
                NSMutableArray *removable=[NSMutableArray array];
                for(NSString *uri in targets)if(absentOfflineState([states[uri]unsignedIntegerValue]))[removable addObject:uri];
                SAPTemporaryOfflineExportState *owner=[SAPTemporaryOfflineExportState new];
                owner.target=target;owner.removable=removable;owner.libraryURIs=libraryURIs;owner.saved=saved;
                completion(@{@"target_uri":target,@"initial_download_state":states[target]?:@0,@"initial_download_states":states,@"saved_entries":saved,@"_temporary_owner":owner},nil);
            });
        });
    });
}
void SAPCleanupTemporaryOfflineExport(NSDictionary *token,BOOL ourDownloadAccepted,void (^completion)(NSString *)) {
    if(!completion)return;
    onMain(^{
        id object=[token isKindOfClass:NSDictionary.class]?token[@"_temporary_owner"]:nil;
        if(![object isKindOfClass:SAPTemporaryOfflineExportState.class]){completion(@"Invalid temporary export token. Nothing was removed.");return;}
        SAPTemporaryOfflineExportState *owner=object;
        if(owner.cleanupFinished){completion(owner.cleanupError);return;}
        if(!owner.completions)owner.completions=[NSMutableArray array];[owner.completions addObject:[completion copy]];
        if(owner.cleanupStarted)return;owner.cleanupStarted=YES;
        if(!ourDownloadAccepted||!owner.removable.count){[owner finish:nil];return;}
        [owner removeDownload:0];
    });
}
