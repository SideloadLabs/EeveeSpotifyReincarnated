#import "SpotifyTransport.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#include <stdatomic.h>


static BOOL explicitEntityURI(NSString *uri,NSString *kind) {
    NSString *prefix=[NSString stringWithFormat:@"spotify:%@:",kind];
    if(![uri isKindOfClass:NSString.class] || ![uri hasPrefix:prefix] || uri.length!=prefix.length+22)return NO;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    return [[uri substringFromIndex:prefix.length]rangeOfCharacterFromSet:invalid].location==NSNotFound;
}
static BOOL explicitAlbumURI(NSString *uri) {return explicitEntityURI(uri,@"album");}
static void callExplicitServiceOnce(NSString *serviceName,NSString *method,NSData *payload,void (^completion)(NSData *,NSString *)) {
    SAPInvokeServiceOnce(serviceName,method,payload,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){if(completion)completion(data,error);});
}
void SAPCallOfflineCommandOnceWithDisposition(NSString *method,NSData *payload,
    void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)) {
    BOOL downloadCommand=NO;
    if(([method isEqual:@"AddDownload"] || [method isEqual:@"RemoveDownload"]) && [payload isKindOfClass:NSData.class]) {
        NSArray *fields=SAPProtoFields(payload);NSString *uri=SAPProtoString(fields,2);
        downloadCommand=fields.count==1 && (explicitAlbumURI(uri) ||
            explicitEntityURI(uri,@"playlist") || explicitEntityURI(uri,@"track"));
    }
    if((![method isEqual:@"SetOfflinePlaybackAllowed"] && !downloadCommand) || ![payload isKindOfClass:NSData.class]) {
        if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Unsupported explicit offline command",SAPCommandNotInvoked);});return;
    }
    SAPInvokeServiceOnce(SAPOfflineService,method,payload,completion);
}
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void (^completion)(NSData *,NSString *)) {
    SAPCallOfflineCommandOnceWithDisposition(method,payload,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){if(completion)completion(data,error);});
}
void SAPCallPlaylistModificationOnce(BOOL rootlist,NSData *payload,void (^completion)(NSData *,NSString *)) {
    NSArray *outer=SAPProtoFields(payload),*request=SAPProtoFields(SAPProtoData(outer,2));
    NSString *operation=SAPProtoString(request,1);BOOL valid=NO;
    if(rootlist)valid=outer.count==1 && request.count>=3 && [operation isEqual:@"create"] && SAPProtoString(request,4).length && SAPProtoNumber(request,5,0)==1;
    else {
        NSString *uri=SAPProtoString(outer,1);NSString *identifier=[uri hasPrefix:@"spotify:playlist:"]?[uri substringFromIndex:17]:nil;
        NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
        valid=identifier.length==22 && [identifier rangeOfCharacterFromSet:invalid].location==NSNotFound && [operation isEqual:@"add"] && [SAPProtoString(request,3)isEqual:@"end"];
        NSUInteger count=0;for(NSDictionary *f in request)if([f[@"number"]unsignedIntValue]==7){
            if([f[@"wire"]unsignedIntValue]!=2){valid=NO;continue;}
            NSString *track=[[NSString alloc]initWithData:f[@"value"] encoding:NSUTF8StringEncoding];NSString *tid=[track hasPrefix:@"spotify:track:"]?[track substringFromIndex:14]:nil;
            if(tid.length!=22 || [tid rangeOfCharacterFromSet:invalid].location!=NSNotFound)valid=NO;count++;
        }
        valid=valid && count>0 && count<=100;
    }
    NSSet *allowed=[NSSet setWithArray:rootlist?@[@1,@4,@5,@12]:@[@1,@3,@7]];
    for(NSDictionary *field in request)if(![allowed containsObject:field[@"number"]])valid=NO;
    if(outer.count!=(rootlist?1:2))valid=NO;
    if(!valid){if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Invalid explicit playlist modification.");});return;}
    callExplicitServiceOnce(rootlist?@"spotify.playlist_esperanto.proto.RootlistModificationService":@"spotify.playlist_esperanto.proto.PlaylistService",@"Modify",payload,completion);
}
void SAPSetPlaylistOfflineOnceWithDisposition(NSString *uri,BOOL enabled,
    void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)) {
    NSString *identifier=[uri hasPrefix:@"spotify:playlist:"]?[uri substringFromIndex:17]:nil;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    if(identifier.length!=22 || [identifier rangeOfCharacterFromSet:invalid].location!=NSNotFound){if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Invalid playlist identity.",SAPCommandNotInvoked);});return;}
    NSMutableData *payload=[SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];[payload appendData:SAPProtoInteger(3,enabled?1:2)];
    SAPInvokeServiceOnce(@"spotify.playlist_esperanto.proto.PlaylistService",@"SetOfflineState",payload,completion);
}
void SAPSetPlaylistOfflineOnce(NSString *uri,BOOL enabled,void (^completion)(NSData *,NSString *)) {
    SAPSetPlaylistOfflineOnceWithDisposition(uri,enabled,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){if(completion)completion(data,error);});
}
void SAPAddAlbumToLibraryOnce(NSString *albumURI,void (^completion)(NSData *,NSString *)) {
    if(!explicitAlbumURI(albumURI)) {if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Invalid album identity for Collection.Add.");});return;}
    // collection_add_remove_items_request.proto: items=2, item.uri=1. This
    // matches the 40-byte request made by the normal album button in log 22.
    NSData *payload=SAPProtoBytes(2,SAPProtoBytes(1,[albumURI dataUsingEncoding:NSUTF8StringEncoding]));
    callExplicitServiceOnce(@"spotify.collection_esperanto.proto.CollectionService",@"Add",payload,completion);
}
