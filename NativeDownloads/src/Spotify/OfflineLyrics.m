#import "OfflineLyrics.h"
#import "../Playlists/PlaylistDownloadsInternal.h"

static BOOL lyricsEntityURI(NSString *uri,NSString *kind);

void SAPFetchOfflineLyricsMetadata(NSString *trackURI, void (^completion)(NSDictionary *)) {
    if(!completion)return;
    dispatch_async(dispatch_get_main_queue(),^{
        if(!lyricsEntityURI(trackURI,@"track")){completion(nil);return;}
        static NSCache *cache;
        static NSMutableDictionary<NSString *,NSMutableArray *> *waiting;
        if(!cache){cache=NSCache.new;cache.countLimit=512;waiting=NSMutableDictionary.new;}
        NSDictionary *known=[cache objectForKey:trackURI];
        if(known){completion(known);return;}
        if(waiting[trackURI]){[waiting[trackURI]addObject:[completion copy]];return;}
        waiting[trackURI]=[NSMutableArray arrayWithObject:[completion copy]];
        SAPCallReadOnlyServiceCancellable(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",
            SAPProtoBytes(1,[trackURI dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
                NSArray *item=SAPProtoFields(SAPProtoData(SAPProtoFields(data),1));
                NSArray *track=SAPProtoFields(SAPProtoData(item,4));
                NSData *gid=SAPProtoData(track,1);
                // ClassicMetadata GetEntity.item.track.gid is a 16-byte base62
                // identity. A relinked/unrelated response must not name this song.
                NSString *identity=nil;
                if(gid.length==16){
                    uint8_t bytes[16];memcpy(bytes,gid.bytes,16);
                    const char *abc="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";char id[23]={0};
                    for(NSInteger i=21;i>=0;i--){unsigned rem=0;for(unsigned j=0;j<16;j++){unsigned v=(rem<<8)|bytes[j];bytes[j]=v/62;rem=v%62;}id[i]=abc[rem];}
                    identity=[@"spotify:track:" stringByAppendingString:[NSString stringWithUTF8String:id]];
                }
                NSString *title=SAPProtoString(track,2),*artist=nil;
                for(NSDictionary *field in track)if([field[@"number"]unsignedIntValue]==4 && [field[@"wire"]unsignedIntValue]==2){
                    artist=SAPProtoString(SAPProtoFields(field[@"value"]),2);if(artist.length)break;
                }
                // nil: Spotify answered, but this ID has no usable title/artist (a
                // definite miss). "unavailable": no answer, so the lookup may succeed later.
                NSDictionary *result=nil;
                if(error || !item) result=@{@"unavailable":@YES};
                else if(!SAPProtoNumber(item,1,0) && [identity isEqual:trackURI] && title.length && artist.length){
                    result=@{@"uri":trackURI,@"name":title,@"artist_name":artist};[cache setObject:result forKey:trackURI];
                }
                NSArray *callbacks=[waiting[trackURI]copy];[waiting removeObjectForKey:trackURI];
                for(void (^callback)(NSDictionary *) in callbacks)callback(result);
            });
    });
}

static BOOL lyricsEntityURI(NSString *uri,NSString *kind) {
    NSString *prefix=[NSString stringWithFormat:@"spotify:%@:",kind];
    if(![uri isKindOfClass:NSString.class] || ![uri hasPrefix:prefix] || uri.length!=prefix.length+22)return NO;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    return [[uri substringFromIndex:prefix.length]rangeOfCharacterFromSet:invalid].location==NSNotFound;
}

// Eevee is optional in host fixtures and older installations. Resolve membership
// through the same native readers as the downloader, including playlist pagination.
void SAPRequestOfflineLyrics(NSString *uri, NSArray *trackURLs) {
    if(!NSClassFromString(@"EeveeOfflineLyricsDownloader"))return;
    id enabled=[NSUserDefaults.standardUserDefaults objectForKey:@"PixieOfflineLyricsEnabled"];
    if(enabled && ![enabled boolValue])return;
    NSTimeInterval requestedAt=NSDate.date.timeIntervalSince1970;
    dispatch_async(dispatch_get_main_queue(),^{
        void (^publish)(NSArray *, NSTimeInterval)=^(NSArray *tracks, NSTimeInterval issued){
            NSMutableArray *valid=[NSMutableArray array];
            for(id value in tracks) {
                NSString *text=[value respondsToSelector:@selector(absoluteString)]?[value absoluteString]:value;
                if(lyricsEntityURI(text,@"track"))[valid addObject:text];
            }
            if(valid.count)[NSNotificationCenter.defaultCenter postNotificationName:@"EeveeOfflineLyricsRequested" object:nil userInfo:@{@"tracks":valid,@"context":uri?:@"",@"requested_at":@(issued)}];
        };
        if(trackURLs.count){publish(trackURLs,requestedAt);return;}
        if(lyricsEntityURI(uri,@"track")){publish(@[uri],requestedAt);return;}
        BOOL album=lyricsEntityURI(uri,@"album");
        if(!album && !lyricsEntityURI(uri,@"playlist"))return;
        static NSMutableDictionary<NSString *, NSNumber *> *pending;
        if(!pending)pending=[NSMutableDictionary new];
        NSNumber *previous=pending[uri];
        pending[uri]=@(MAX(previous.doubleValue,requestedAt));
        if(previous)return;
        // Share the membership read, but honor a newer download issued after Cancel.
        void (^finish)(NSArray *)=^(NSArray *tracks){
            NSTimeInterval issued=pending[uri].doubleValue;
            [pending removeObjectForKey:uri];
            publish(tracks,issued);
        };
        if(album) {
            SAPFetchArtistAlbumTrackURIs(uri,^(NSArray *tracks,NSString *error){finish(tracks);});
        } else {
            SAPPlaylistReadList(uri,^(NSDictionary *contents,NSString *error){finish(contents[@"items"]);});
        }
    });
}

void SAPRemoveOfflineLyrics(NSString *uri, NSArray *trackURLs) {
    if(!NSClassFromString(@"EeveeOfflineLyricsDownloader"))return;
    NSString *token=NSUUID.UUID.UUIDString;
    dispatch_async(dispatch_get_main_queue(),^{
        void (^publish)(NSArray *,NSString *)=^(NSArray *tracks,NSString *phase){
            NSMutableArray *valid=[NSMutableArray array];
            for(id value in tracks) {
                NSString *text=[value respondsToSelector:@selector(absoluteString)]?[value absoluteString]:value;
                if(lyricsEntityURI(text,@"track"))[valid addObject:text];
            }
            [NSNotificationCenter.defaultCenter postNotificationName:@"EeveeOfflineLyricsRemoved" object:nil
                userInfo:@{@"tracks":valid,@"context":uri?:@"",@"token":token,@"phase":phase,@"all":@([uri isEqual:@"spotify:all"])}];
        };
        publish(trackURLs?:@[],@"begin");
        // The remembered context is removed immediately, even offline. Native
        // metadata also covers downloads made before context tracking existed.
        if(trackURLs.count || lyricsEntityURI(uri,@"track"))return;
        if(lyricsEntityURI(uri,@"album"))
            SAPFetchArtistAlbumTrackURIs(uri,^(NSArray *tracks,NSString *error){if(tracks)publish(tracks,@"resolved");});
        else if(lyricsEntityURI(uri,@"playlist"))
            SAPPlaylistReadList(uri,^(NSDictionary *contents,NSString *error){if(contents)publish(contents[@"items"],@"resolved");});
    });
}
