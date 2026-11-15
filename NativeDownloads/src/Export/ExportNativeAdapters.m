#import "ExportNativeAdapters.h"
#import "SpotifyTransport.h"
#import "NativeOffline.h"

NSDictionary *SAPCurrentExportTrack(void) {
    NSCAssert(NSThread.isMainThread,@"Read the bound player on the main thread");
    SAPInstallTrackDownloader();
    id track=SAPTransportObject(SAPTransportObject(SAPTransportPlayer(),@"state"),@"track");
    id value=SAPTransportObject(track,@"URI"),album=SAPTransportObject(track,@"albumURI");
    NSString *uri=[value isKindOfClass:NSURL.class]?[value absoluteString]:[value isKindOfClass:NSString.class]?value:nil;
    NSString *albumURI=[album isKindOfClass:NSURL.class]?[album absoluteString]:[album isKindOfClass:NSString.class]?album:nil;
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    if([uri hasPrefix:@"spotify:track:"]&&uri.length==36)result[@"uri"]=uri;
    if([albumURI hasPrefix:@"spotify:album:"]&&albumURI.length==36)result[@"album_uri"]=albumURI;
    id name=SAPTransportObject(track,@"trackTitle");
    if([name isKindOfClass:NSString.class])result[@"name"]=name;
    return result;
}
void SAPMakeEntityAvailableOffline(NSString *uri,NSArray<NSString *> *tracks,void (^completion)(BOOL,NSString *)) {
    NSString *reason=nil;
    BOOL invoked=SAPSubmitNativeAlbumDownload(uri,tracks,&reason);
    if(completion)completion(invoked,reason);
}
void SAPResetEntityOffline(NSString *uri,void (^completion)(BOOL,NSString *)) {
    NSString *reason=nil;
    BOOL invoked=SAPResetNativeEntityDownload(uri,&reason);
    if(completion)completion(invoked,reason);
}
