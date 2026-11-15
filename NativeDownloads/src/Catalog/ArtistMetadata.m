#import "ArtistMetadata.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import "DiagnosticTrace.h"
#import "Deadline.h"

static BOOL validURI(NSString *uri, NSString *kind) {
    if (![uri isKindOfClass:NSString.class]) return NO;
    NSString *prefix=[NSString stringWithFormat:@"spotify:%@:",kind];
    if (![uri hasPrefix:prefix] || uri.length!=prefix.length+22) return NO;
    static NSCharacterSet *invalid;static dispatch_once_t once;
    dispatch_once(&once,^{invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;});
    return [[uri substringFromIndex:prefix.length] rangeOfCharacterFromSet:invalid].location==NSNotFound;
}
BOOL SAPIsAlbumURI(NSString *uri) { return validURI(uri,@"album"); }
BOOL SAPIsPlaylistURI(NSString *uri) { return validURI(uri,@"playlist"); }

// Spotify's metadata GID is an unsigned big-endian 128-bit integer.
static NSString *uriFromGID(NSData *gid, NSString *kind) {
    if (gid.length!=16) return nil;
    uint8_t bytes[16];memcpy(bytes,gid.bytes,16);
    const char alphabet[]="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    char encoded[23]={0};
    for (NSInteger digit=21;digit>=0;digit--) {
        unsigned remainder=0;
        for (NSUInteger i=0;i<16;i++) {unsigned value=(remainder<<8)|bytes[i];bytes[i]=value/62;remainder=value%62;}
        encoded[digit]=alphabet[remainder];
    }
    return [NSString stringWithFormat:@"spotify:%@:%s",kind,encoded];
}
static NSInteger signedNumber(NSArray *fields,unsigned field) {
    uint64_t value=SAPProtoNumber(fields,field,0);
    return (NSInteger)((int64_t)(value>>1)^-(int64_t)(value&1));
}
static NSDictionary *albumCoverFacts(NSArray *album) {
    NSMutableArray *images=[NSMutableArray array],*candidates=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSDictionary *field in album) {
        unsigned number=[field[@"number"]unsignedIntValue];if([field[@"wire"]unsignedIntValue]!=2)continue;
        if(number==9)[candidates addObject:field[@"value"]];
        else if(number==17)for(NSDictionary *image in SAPProtoFields(field[@"value"]))
            if([image[@"number"]unsignedIntValue]==1 && [image[@"wire"]unsignedIntValue]==2)[candidates addObject:image[@"value"]];
    }
    for(NSData *candidate in candidates) {
        NSArray *image=SAPProtoFields(candidate);NSData *file=SAPProtoData(image,1);if(file.length!=20)continue;
        NSMutableString *identifier=[NSMutableString stringWithCapacity:40];const uint8_t *bytes=file.bytes;
        for(NSUInteger i=0;i<file.length;i++)[identifier appendFormat:@"%02x",bytes[i]];
        if([seen containsObject:identifier])continue;[seen addObject:identifier];
        [images addObject:@{@"image_uri":[@"spotify:image:" stringByAppendingString:identifier],
            @"url":[@"https://i.scdn.co/image/" stringByAppendingString:identifier],@"size":@(SAPProtoNumber(image,2,0))}];
        if(images.count==16)break;
    }
    NSDictionary *preferred=images.firstObject;
    for(NSDictionary *image in images)if([image[@"size"]unsignedIntValue]==0) {preferred=image;break;}
    return @{@"cover_count":@(images.count),@"covers":images,@"cover_url":preferred[@"url"]?:@""};
}
static NSArray *entityFields(NSData *response,unsigned kind,NSString **reason) {
    NSArray *envelope=SAPProtoFields(response),*item=SAPProtoFields(SAPProtoData(envelope,1));
    if(!envelope || !item) {if(reason)*reason=@"invalid_entity_envelope";return nil;}
    if(SAPProtoNumber(item,1,0)) {if(reason)*reason=[NSString stringWithFormat:@"metadata_error_%ld",(long)signedNumber(item,1)];return nil;}
    NSArray *entity=SAPProtoFields(SAPProtoData(item,kind));
    if(!entity && reason)*reason=@"missing_expected_entity";
    return entity;
}
static NSArray *albumTracks(NSArray *album,NSString **reason) {
    NSMutableArray *tracks=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    // These are the 9.1.90 executable's fields: Album.disc=11, Disc.track=3.
    for(NSDictionary *discField in album) {
        if([discField[@"number"]unsignedIntValue]!=11 || [discField[@"wire"]unsignedIntValue]!=2)continue;
        NSArray *disc=SAPProtoFields(discField[@"value"]);if(!disc) {if(reason)*reason=@"invalid_album_disc";return nil;}
        for(NSDictionary *trackField in disc) {
            if([trackField[@"number"]unsignedIntValue]!=3 || [trackField[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *track=SAPProtoFields(trackField[@"value"]);
            NSString *gidURI=uriFromGID(SAPProtoData(track,1),@"track"),*canonical=SAPProtoString(track,36);
            if(canonical.length && !validURI(canonical,@"track")) {if(reason)*reason=@"invalid_canonical_track_uri";return nil;}
            if(gidURI && canonical.length && ![gidURI isEqual:canonical]) {if(reason)*reason=@"track_identity_mismatch";return nil;}
            NSString *uri=gidURI?:canonical;
            if(!uri.length) {if(reason)*reason=@"track_identity_missing";return nil;}
            if(![seen containsObject:uri]) {[seen addObject:uri];[tracks addObject:uri];}
            if(tracks.count>4096) {if(reason)*reason=@"album_track_limit";return nil;}
        }
    }
    if(reason)*reason=tracks.count?@"verified_album_tracks":@"album_tracks_missing";
    return tracks.count?[tracks copy]:nil;
}
static NSDictionary *releaseFromFields(NSArray *album,unsigned group) {
    NSString *uri=uriFromGID(SAPProtoData(album,1),@"album"),*title=SAPProtoString(album,2);
    if(!uri || !title.length)return nil;
    uint64_t type=SAPProtoNumber(album,4,0);if(type==5 || type==6)return nil;
    NSString *category=group==8?@"Appears on":type==4?@"EPs":type==2?@"Singles":type==3?@"Compilations":
        type==1?@"Albums":group==6?@"Singles & EPs":group==7?@"Compilations":@"Albums";
    NSArray *date=SAPProtoFields(SAPProtoData(album,6));
    NSInteger year=signedNumber(date,1),month=signedNumber(date,2),day=signedNumber(date,3);
    if(year<0 || year>9999 || month<0 || month>12 || day<0 || day>31)year=month=day=0;
    NSString *version=SAPProtoString(album,19);
    if(version.length && ![title localizedCaseInsensitiveContainsString:version])title=[NSString stringWithFormat:@"%@ (%@)",title,version];
    NSMutableDictionary *release=[@{@"uri":uri,@"name":title,@"category":category,@"type":@(type),@"year":@(year),@"date_order":@(year*10000+month*100+day),@"cover_url":albumCoverFacts(album)[@"cover_url"]}mutableCopy];
    // SINGLE can contain multiple tracks; use verified membership for admission.
    NSArray *tracks=albumTracks(album,NULL);
    if(tracks){release[@"verified_track_count"]=@(tracks.count);release[@"track_count_verified"]=@YES;release[@"track_uris"]=tracks;}
    return release;
}
static NSDictionary *inNativeGroup(NSDictionary *release,NSDictionary *reference) {
    if(!release)return nil;
    NSMutableDictionary *result=[release mutableCopy];
    for(NSString *key in @[@"native_group_key",@"native_edition_index"])
        if(reference[key])result[key]=reference[key];
    return result;
}
static NSDictionary *withReleases(NSDictionary *base,NSArray *releases) {
    // Each Spotify AlbumGroup contains alternate editions of ONE release.
    // Keep Spotify's first resolved edition, independent of hydration completion
    // order. Separate groups remain separate even if their titles are equal.
    NSMutableDictionary *chosen=[NSMutableDictionary dictionary];NSMutableArray *keys=[NSMutableArray array];
    for(NSDictionary *release in releases){
        NSString *key=release[@"native_group_key"]?:release[@"uri"];NSDictionary *previous=chosen[key];
        if(!previous){chosen[key]=release;[keys addObject:key];}
        else if([release[@"native_edition_index"]unsignedIntegerValue]<[previous[@"native_edition_index"]unsignedIntegerValue])chosen[key]=release;
    }
    NSMutableArray *selected=[NSMutableArray array];for(NSString *key in keys)[selected addObject:chosen[key]];
    NSMutableArray *sections=[NSMutableArray array];
    for(NSString *category in @[@"Albums",@"EPs",@"Singles",@"Singles & EPs",@"Compilations",@"Appears on"]) {
        NSMutableArray *items=[NSMutableArray array];
        for(NSDictionary *release in selected)if([release[@"category"]isEqual:category])[items addObject:release];
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            NSComparisonResult date=[b[@"date_order"]compare:a[@"date_order"]];
            return date==NSOrderedSame?[a[@"name"]localizedStandardCompare:b[@"name"]]:date;
        }];
        if(items.count)[sections addObject:@{@"title":category,@"releases":[items copy]}];
    }
    NSMutableDictionary *result=[base mutableCopy];result[@"sections"]=sections;result[@"release_count"]=@(selected.count);result[@"resolved_edition_count"]=@(releases.count);return result;
}
static NSDictionary *parseArtist(NSData *response,NSString *artistURI,NSString **reason) {
    if(!validURI(artistURI,@"artist")) {if(reason)*reason=@"invalid_artist_uri";return nil;}
    NSArray *artist=entityFields(response,2,reason);if(!artist)return nil;
    NSString *name=SAPProtoString(artist,2);
    if(![uriFromGID(SAPProtoData(artist,1),@"artist")isEqual:artistURI]) {if(reason)*reason=@"artist_identity_mismatch";return nil;}
    if(!name.length) {if(reason)*reason=@"artist_name_missing";return nil;}
    NSMutableArray *releases=[NSMutableArray array],*pending=[NSMutableArray array];
    NSMutableSet *seen=[NSMutableSet set];NSMutableDictionary *groupCounts=[NSMutableDictionary dictionary];
    NSUInteger skipped=0,entries=0,duplicates=0,excluded=0;
    // Nested Album messages are often references containing only a GID.
    // Optional name/type/date fields must be hydrated through album GetEntity.
    for(unsigned group=5;group<=8;group++)for(NSDictionary *field in artist) {
        if([field[@"number"]unsignedIntValue]!=group || [field[@"wire"]unsignedIntValue]!=2)continue;
        NSString *key=[NSString stringWithFormat:@"%u",group];groupCounts[key]=@([groupCounts[key]unsignedIntegerValue]+1);
        NSArray *albums=SAPProtoFields(field[@"value"]);if(!albums) {if(reason)*reason=@"invalid_album_group";return nil;}
        NSString *nativeGroupKey=[NSString stringWithFormat:@"%@/%u/%lu",artistURI,group,(unsigned long)[groupCounts[key]unsignedIntegerValue]];
        NSUInteger editionIndex=0;
        for(NSDictionary *entry in albums) {
            if([entry[@"number"]unsignedIntValue]!=1 || [entry[@"wire"]unsignedIntValue]!=2)continue;
            entries++;NSUInteger rank=editionIndex++;
            NSArray *album=SAPProtoFields(entry[@"value"]);NSString *uri=uriFromGID(SAPProtoData(album,1),@"album");
            if(!uri) {skipped++;continue;}
            if([seen containsObject:uri]) {duplicates++;continue;}
            [seen addObject:uri];if(seen.count>4096) {if(reason)*reason=@"release_reference_limit";return nil;}
            uint64_t type=SAPProtoNumber(album,4,0);if(type==5 || type==6) {excluded++;continue;}
            NSDictionary *reference=@{@"uri":uri,@"group":@(group),@"native_group_key":nativeGroupKey,@"native_edition_index":@(rank)};
            NSDictionary *release=inNativeGroup(releaseFromFields(album,group),reference);
            if(release)[releases addObject:release];
            else [pending addObject:reference];
        }
    }
    if(reason)*reason=seen.count?@"parsed_references":@"no_release_references";
    NSDictionary *base=@{@"uri":artistURI,@"name":name,@"pending_releases":pending,
        @"parsed_editions":[releases copy],@"reference_count":@(releases.count+pending.count),@"skipped_incomplete_releases":@(skipped),
        @"parse_facts":@{@"group_counts":groupCounts,@"album_entries":@(entries),@"unique_gids":@(seen.count),
            @"duplicate_gids":@(duplicates),@"missing_or_invalid_gid":@(skipped),@"references_needing_metadata":@(pending.count),@"excluded_nonmusic":@(excluded)}};
    return withReleases(base,releases);
}
NSDictionary *SAPParseArtistMetadata(NSData *response,NSString *artistURI) {return parseArtist(response,artistURI,NULL);}

static void traceResponse(NSString *kind,NSString *uri,NSData *data,NSString *reason,NSDictionary *facts,BOOL captureBody) {
    if(!SAPTraceIsActive())return;
    NSMutableDictionary *values=[@{@"kind":kind,@"requested_uri":uri?:@"",@"response_received":@(data!=nil),
        @"response_bytes":@(data.length),@"parse_result":reason?:@"",@"facts":facts?:@{}}mutableCopy];
    // Explicit public metadata response bodies may be recorded, never HTTP headers,
    // session credentials, audio, or license material. Chunks avoid string limits.
    // body_complete is false when absent or over the capture cap; Base64 plus JSON
    // must stay below the trace's 128-KiB record limit.
    if(captureBody && data && data.length<=64*1024) {
        NSString *encoded=[data base64EncodedStringWithOptions:0];NSMutableArray *chunks=[NSMutableArray array];
        for(NSUInteger offset=0;offset<encoded.length;offset+=4096)[chunks addObject:[encoded substringWithRange:NSMakeRange(offset,MIN((NSUInteger)4096,encoded.length-offset))]];
        values[@"public_metadata_base64_chunks"]=chunks;values[@"body_complete"]=@YES;
    }else values[@"body_complete"]=@NO;
    SAPTraceEvent("artist_metadata","response",SAPTraceCurrentOperation(),values);
}

NSArray<NSString *> *SAPParseArtistAlbumTrackURIs(NSData *response,NSString *albumURI,NSString **reason) {
    if(!SAPIsAlbumURI(albumURI)) {if(reason)*reason=@"invalid_album_uri";return nil;}
    NSArray *album=entityFields(response,3,reason);if(!album)return nil;
    if(![uriFromGID(SAPProtoData(album,1),@"album")isEqual:albumURI]) {if(reason)*reason=@"album_identity_mismatch";return nil;}
    return albumTracks(album,reason);
}
void SAPFetchArtistAlbumTrackURIs(NSString *albumURI,void (^completion)(NSArray<NSString *> *,NSString *)) {
    if(!SAPIsAlbumURI(albumURI)) {if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Invalid album identity.");});return;}
    SAPCallReadOnlyService(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",SAPProtoBytes(1,[albumURI dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *reason=nil;NSArray *tracks=data?SAPParseArtistAlbumTrackURIs(data,albumURI,&reason):nil;
            if(SAPTraceIsActive()) {
                NSArray *sample=tracks.count>512?[tracks subarrayWithRange:NSMakeRange(0,512)]:tracks?:@[];
                NSMutableDictionary *facts=[@{@"track_count":@(tracks.count),@"track_uris":sample,@"track_uris_complete":@(tracks.count<=512)}mutableCopy];
                [facts addEntriesFromDictionary:albumCoverFacts(entityFields(data,3,NULL))];
                traceResponse(@"album_download_tracks",albumURI,data,reason?:error,facts,!tracks);
            }
            if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(tracks,tracks?nil:error?:[NSString stringWithFormat:@"Spotify album track metadata could not be verified (%@).",reason?:@"no response"]);});
        });
    });
}

@interface SAPArtistCatalogLoad : NSObject
@property(nonatomic,copy) NSString *uri;
@property(nonatomic,strong) NSDictionary *catalog;
@property(nonatomic,strong) NSMutableArray *releases;
@property(nonatomic,strong) NSArray *pending;
@property(nonatomic,strong) NSMutableDictionary<NSString *,id> *readCancels;
@property(nonatomic,strong) SAPArtistCatalogLoad *operationRetain;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,copy) void (^progress)(NSUInteger,NSUInteger);
@property(nonatomic,copy) void (^preview)(NSDictionary *);
@property(nonatomic,strong) NSMutableDictionary *remainingGroups;
@property(nonatomic) NSUInteger lastPreviewCompleted;
@property(nonatomic) BOOL previewed;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSString *);
@property(nonatomic) NSUInteger next,active,completed,failed,excluded;
@property(atomic) BOOL finished;
- (void)start;
- (void)pump;
- (void)finish:(NSString *)error;
- (void)cancelPendingReads;
- (void)publishPreview;
@end
@implementation SAPArtistCatalogLoad
- (void)publishPreview {
    if(self.finished || !self.preview || (self.previewed && self.completed-self.lastPreviewCompleted<32))return;
    NSMutableArray *settled=[NSMutableArray array];for(NSDictionary *release in self.releases){NSString *key=release[@"native_group_key"]?:release[@"uri"];if(![self.remainingGroups[key]unsignedIntegerValue])[settled addObject:release];}
    if(!settled.count)return;NSMutableDictionary *base=[self.catalog mutableCopy];base[@"pending_releases"]=@[];[base removeObjectForKey:@"parsed_editions"];base[@"catalog_loading"]=@YES;
    self.previewed=YES;self.lastPreviewCompleted=self.completed;self.preview(withReleases(base,settled));
}
- (void)cancelPendingReads {
    NSArray *cancellations=self.readCancels.allValues;[self.readCancels removeAllObjects];
    for(id value in cancellations)if(value!=NSNull.null)((dispatch_block_t)value)();
}
- (void)finish:(NSString *)error {
    if(self.finished)return;self.finished=YES;
    if(self.deadline)dispatch_source_cancel(self.deadline);self.deadline=nil;
    [self cancelPendingReads];
    NSDictionary *result=nil;
    if(self.catalog) {
        NSMutableDictionary *base=[self.catalog mutableCopy];base[@"pending_releases"]=@[];[base removeObjectForKey:@"parsed_editions"];
        base[@"unresolved_releases"]=@(self.pending.count-self.completed+self.failed);
        base[@"hydrated_releases"]=@(self.completed-self.failed-self.excluded);
        if(error.length && self.releases.count)base[@"load_warning"]=error;
        if(self.failed && !error.length)base[@"load_warning"]=[NSString stringWithFormat:@"Spotify did not return full metadata for %lu releases. Retry to load them.",(unsigned long)self.failed];
        result=withReleases(base,self.releases);
        if(!self.releases.count && [base[@"unresolved_releases"]unsignedIntegerValue])error=error?:@"Spotify returned release IDs, but their full metadata could not be read. Retry and send a diagnostic log if this continues.";
        else if(!self.releases.count && ![self.catalog[@"reference_count"]unsignedIntegerValue] && ![self.catalog[@"parse_facts"][@"excluded_nonmusic"]unsignedIntegerValue])error=@"Spotify returned artist metadata without release IDs. Retry and send a diagnostic log if this continues.";
        // A usable partial catalog stays selectable; its warning and Retry are
        // shown separately instead of turning Download into an error action.
        if(self.releases.count)error=nil;
    }
    SAP_TRACE("artist_metadata","finished",SAPTraceCurrentOperation(),@{@"artist_uri":self.uri?:@"",@"listed_releases":result[@"release_count"]?:@0,@"resolved_editions":@(self.releases.count),
        @"hydration_total":@(self.pending.count),@"hydration_completed":@(self.completed),@"hydration_failed":@(self.failed),@"error":error?:@""});
    void (^reply)(NSDictionary *,NSString *)=self.completion;self.completion=nil;self.progress=nil;self.preview=nil;
    self.operationRetain=nil;
    if(reply)reply(result,error);
}
- (void)start {
    if(self.finished)return;
    if(!validURI(self.uri,@"artist")) {[self finish:@"The artist identity is unavailable."];return;}
    self.operationRetain=self;
    __weak typeof(self) weak=self;
    self.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),60,^{[weak finish:@"Reading the artist catalog timed out. Retry to load the remaining releases."];});
    if(!self.readCancels)self.readCancels=[NSMutableDictionary dictionary];
    NSString *requestID=NSUUID.UUID.UUIDString;self.readCancels[requestID]=NSNull.null;
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",SAPProtoBytes(1,[self.uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        typeof(self) load=weak;if(!load || !load.readCancels[requestID])return;
        [load.readCancels removeObjectForKey:requestID];if(load.finished)return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            typeof(self) parsing=weak;if(!parsing || parsing.finished)return;
            NSString *reason=nil;NSDictionary *catalog=data?parseArtist(data,parsing.uri,&reason):nil;
            if(parsing.finished)return;
            traceResponse(@"artist",parsing.uri,data,reason?:error,catalog[@"parse_facts"],YES);
            dispatch_async(dispatch_get_main_queue(),^{
                typeof(self) current=weak;if(!current || current.finished)return;
                if(!catalog) {[current finish:error?:@"Spotify did not return valid artist metadata. Retry and send a diagnostic log if this continues."];return;}
                current.catalog=catalog;current.pending=catalog[@"pending_releases"];current.releases=[catalog[@"parsed_editions"]mutableCopy]?:[NSMutableArray array];
                current.remainingGroups=[NSMutableDictionary dictionary];NSMutableOrderedSet *identities=[NSMutableOrderedSet orderedSet];
                for(NSDictionary *release in current.releases)[identities addObject:release[@"uri"]];
                for(NSDictionary *reference in current.pending){NSString *key=reference[@"native_group_key"]?:reference[@"uri"];current.remainingGroups[key]=@([current.remainingGroups[key]unsignedIntegerValue]+1);[identities addObject:reference[@"uri"]];}
                NSMutableArray *observation=[NSMutableArray array];for(NSString *identity in identities)[observation addObject:@{@"uri":identity}];NSMutableDictionary *base=[catalog mutableCopy];base[@"observation_releases"]=observation;current.catalog=base;

                if(current.progress)current.progress(0,current.pending.count);[current publishPreview];
                [current pump];
            });
        });
    });
    if(self.finished || !self.readCancels[requestID]) {if(cancel)cancel();}
    else self.readCancels[requestID]=cancel?(id)cancel:NSNull.null;
}
- (void)pump {
    if(self.finished)return;
    if(self.completed==self.pending.count) {[self finish:nil];return;}
    // Bound explicit metadata work. No downloads or player commands are sent here.
    while(self.active<4 && self.next<self.pending.count) {
        NSDictionary *reference=self.pending[self.next++];NSString *uri=reference[@"uri"];self.active++;
        SAP_TRACE("artist_metadata","album_requested",SAPTraceCurrentOperation(),@{@"artist_uri":self.uri,@"album_uri":uri,@"source_group":reference[@"group"]});
        NSString *requestID=NSUUID.UUID.UUIDString;self.readCancels[requestID]=NSNull.null;
        __weak typeof(self) weak=self;
        dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
            typeof(self) load=weak;if(!load || !load.readCancels[requestID])return;
            [load.readCancels removeObjectForKey:requestID];if(load.finished)return;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                typeof(self) parsing=weak;if(!parsing || parsing.finished)return;
                NSString *reason=nil;NSArray *fields=data?entityFields(data,3,&reason):nil;
                NSString *received=uriFromGID(SAPProtoData(fields,1),@"album");
                BOOL matches=[received isEqual:uri];uint64_t type=SAPProtoNumber(fields,4,0);
                BOOL excluded=matches && (type==5 || type==6);
                NSDictionary *release=matches?inNativeGroup(releaseFromFields(fields,[reference[@"group"]unsignedIntValue]),reference):nil;
                if(fields)reason=!matches?@"album_identity_mismatch":excluded?@"nonmusic_album":release?@"resolved":@"album_name_missing";
                if(parsing.finished)return;
                if(SAPTraceIsActive()) {
                    unsigned sourceGroup=[reference[@"group"]unsignedIntValue];
                    NSString *sourceGroupLabel=sourceGroup==5?@"Albums":sourceGroup==6?@"Singles & EPs":sourceGroup==7?@"Compilations":sourceGroup==8?@"Appears on":@"";
                    NSMutableDictionary *facts=[@{@"received_uri":received?:@"",@"identity_matches":@(matches),@"name_present":@(SAPProtoString(fields,2).length>0),
                        @"album_name":release[@"name"]?:SAPProtoString(fields,2)?:@"",@"wire_album_name":SAPProtoString(fields,2)?:@"",
                        @"version":SAPProtoString(fields,19)?:@"",@"year":release[@"year"]?:@0,@"album_type":@(type),
                        @"source_group":@(sourceGroup),@"source_group_label":sourceGroupLabel}mutableCopy];
                    NSMutableArray *external=[NSMutableArray array];
                    for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==10 && [field[@"wire"]unsignedIntValue]==2){NSArray *identifier=SAPProtoFields(field[@"value"]);NSString *kind=SAPProtoString(identifier,1),*value=SAPProtoString(identifier,2);if(kind && value)[external addObject:@{@"type":kind,@"id":value}];}
                    facts[@"native_group_key"]=reference[@"native_group_key"]?:@"";facts[@"native_edition_index"]=reference[@"native_edition_index"]?:@0;
                    facts[@"external_ids"]=external;facts[@"wire_album_uri_field35"]=SAPProtoString(fields,35)?:@"";
                    // Reuse this catalog reply only while diagnostics are on.
                    // An unavailable member list must not look like an empty album.
                    NSString *trackReason=nil;NSArray *tracks=data?SAPParseArtistAlbumTrackURIs(data,uri,&trackReason):nil;
                    facts[@"track_membership_available"]=@(tracks!=nil);facts[@"track_count"]=@(tracks.count);
                    facts[@"track_uris"]=tracks.count>512?[tracks subarrayWithRange:NSMakeRange(0,512)]:tracks?:@[];
                    facts[@"track_uris_complete"]=@(tracks!=nil && tracks.count<=512);
                    facts[@"track_parse_result"]=trackReason?:error?:@"metadata_response_missing";
                    [facts addEntriesFromDictionary:albumCoverFacts(fields)];traceResponse(@"album",uri,data,reason?:error,facts,!excluded);
                }
                dispatch_async(dispatch_get_main_queue(),^{
                    typeof(self) current=weak;if(!current || current.finished)return;current.active--;current.completed++;
                    if(release)[current.releases addObject:release];else if(excluded)current.excluded++;else current.failed++;
                    NSString *group=reference[@"native_group_key"]?:uri;NSUInteger remaining=[current.remainingGroups[group]unsignedIntegerValue];current.remainingGroups[group]=@(remaining?remaining-1:0);
                    if(current.progress)current.progress(current.completed,current.pending.count);if(remaining==1)[current publishPreview];
                    if(current.failed>=8 && !current.releases.count) {[current finish:@"Spotify could not resolve the first release IDs. Retry and send a diagnostic log if this continues."];return;}
                    [current pump];
                });
            });
        });
        if(self.finished || !self.readCancels[requestID]) {if(cancel)cancel();}
        else self.readCancels[requestID]=cancel?(id)cancel:NSNull.null;
    }
}
@end

dispatch_block_t SAPFetchArtistMetadataProgressively(NSString *artistURI,void (^progress)(NSUInteger,NSUInteger),void (^preview)(NSDictionary *),void (^completion)(NSDictionary *,NSString *)) {
    SAPArtistCatalogLoad *load=[SAPArtistCatalogLoad new];load.uri=artistURI;load.progress=progress;load.preview=preview;load.completion=completion;
    dispatch_async(dispatch_get_main_queue(),^{[load start];});
    return ^{if(NSThread.isMainThread)[load finish:@"Catalog loading cancelled."];else dispatch_async(dispatch_get_main_queue(),^{[load finish:@"Catalog loading cancelled."];});};
}
void SAPFetchArtistMetadata(NSString *artistURI,void (^completion)(NSDictionary *,NSString *)) {SAPFetchArtistMetadataCancellable(artistURI,nil,completion);}

dispatch_block_t SAPFetchArtistMetadataCancellable(NSString *artistURI,void (^progress)(NSUInteger,NSUInteger),void (^completion)(NSDictionary *,NSString *)) {return SAPFetchArtistMetadataProgressively(artistURI,progress,nil,completion);}
