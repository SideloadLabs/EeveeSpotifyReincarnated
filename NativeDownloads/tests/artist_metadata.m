#import <Foundation/Foundation.h>
#import "ArtistMetadata.h"
#import "WireProto.h"
#import "DiagnosticTrace.h"
#include <assert.h>

static void (^pendingRead)(NSData *, NSString *);
static NSUInteger readCalls;
static NSDictionary *readResponses;
static NSMutableArray *readURIs,*metadataEvents;
static BOOL tracing;
static NSUInteger readsActive,maximumReadsActive,readCancellations;
static NSUInteger staggerStartRead;
bool SAPTraceIsActive(void) {return tracing;}
SAPTraceID SAPTraceCurrentOperation(void) {return 0;}
void SAPTraceEvent(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts) {
    assert(tracing);@synchronized(metadataEvents) {
        [metadataEvents addObject:@{@"category":@(category),@"stage":@(stage),@"facts":facts}];
    }
}

bool SAPDiagnosticsEnabled(void){return true;}

void SAPJournalNoteAction(NSString *name, NSDictionary *facts) {}
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *service, NSString *method, NSData *payload,
                                                    void (^completion)(NSData *, NSString *)) {
    assert(NSThread.isMainThread);
    assert([service isEqual:@"spotify.metadata_esperanto.proto.ClassicMetadataService"] && [method isEqual:@"GetEntity"]);
    NSArray *fields=SAPProtoFields(payload);
    assert(fields.count==1 && [fields[0][@"number"]unsignedIntValue]==1);
    NSString *uri=SAPProtoString(fields,1);
    assert([uri isEqual:@"spotify:artist:0000000000000000000001"] || SAPIsAlbumURI(uri) || ([uri hasPrefix:@"spotify:artist:"] && readResponses[uri]));
    readCalls++;if(!readURIs)readURIs=[NSMutableArray array];[readURIs addObject:uri];
    __block BOOL finished=NO,cancelled=NO,active=NO;
    if(!readResponses)pendingRead=[^(NSData *data,NSString *error){if(finished)return;finished=YES;completion(data,error);} copy];
    else {
        active=YES;readsActive++;maximumReadsActive=MAX(maximumReadsActive,readsActive);
        id reply=readResponses[uri];
        double delay=.01;
        if(staggerStartRead) {
            NSUInteger offset=readCalls-staggerStartRead;
            delay=offset==0?.001:offset==1?.01:.05+(double)(offset-2)*.01;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(finished || cancelled)return;finished=YES;if(active){active=NO;readsActive--;}
            completion([reply isKindOfClass:NSData.class]?reply:nil,[reply isKindOfClass:NSData.class]?nil:@"Fixture metadata timeout");
        });
    }
    return ^{
        if(finished || cancelled)return;cancelled=YES;finished=YES;readCancellations++;
        if(active){active=NO;readsActive--;}
    };
}
void SAPCallReadOnlyService(NSString *service, NSString *method, NSData *payload,
                            void (^completion)(NSData *, NSString *)) {
    SAPCallReadOnlyServiceCancellable(service,method,payload,completion);
}
static NSData *join(NSArray<NSData *> *parts) {
    NSMutableData *data=[NSMutableData data];for(NSData *part in parts)[data appendData:part];return data;
}
static NSData *text(unsigned field, NSString *value) {return SAPProtoBytes(field,[value dataUsingEncoding:NSUTF8StringEncoding]);}
static NSData *hex(NSString *value) {
    NSMutableData *data=[NSMutableData data];
    for(NSUInteger i=0;i<value.length;i+=2) {
        unsigned number=0;[[NSScanner scannerWithString:[value substringWithRange:NSMakeRange(i,2)]]scanHexInt:&number];
        uint8_t byte=number;[data appendBytes:&byte length:1];
    }
    return data;
}
static NSData *gid(unsigned value) {uint8_t bytes[16]={0};bytes[15]=value;return [NSData dataWithBytes:bytes length:16];}
static NSData *sint(unsigned field, int32_t value) {
    uint32_t zigzag=((uint32_t)value<<1)^(uint32_t)-(value<0);return SAPProtoInteger(field,zigzag);
}
static NSData *album(NSData *identity, NSString *name, unsigned type, int year, NSString *version) {
    NSData *date=join(@[sint(1,year),sint(2,2),sint(3,29)]);
    return join(@[SAPProtoBytes(1,identity),text(2,name),SAPProtoInteger(4,type),SAPProtoBytes(6,date),text(19,version?:@"")]);
}
static NSData *group(NSArray<NSData *> *albums) {
    NSMutableArray *entries=[NSMutableArray array];for(NSData *item in albums)[entries addObject:SAPProtoBytes(1,item)];return join(entries);
}
static NSData *response(NSData *artist) {return SAPProtoBytes(1,SAPProtoBytes(2,artist));}
static NSDictionary *section(NSDictionary *catalog, NSString *title) {
    for(NSDictionary *value in catalog[@"sections"])if([value[@"title"]isEqual:title])return value;return nil;
}
static void waitFor(BOOL (^ready)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!ready() && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
    assert(ready());
}
// Distinct releases are distinct AlbumGroup entries; repeated albums within
// one AlbumGroup are editions and are covered separately below.
static NSData *releaseGroups(unsigned field,NSArray *albums){
    NSMutableData *result=[NSMutableData data];for(NSData *album in albums)[result appendData:SAPProtoBytes(field,group(@[album]))];return result;
}
int main(void) { @autoreleasepool {
    NSString *artistURI=@"spotify:artist:0000000000000000000001";
    // Fixed integer vectors are independent of the production repeated-byte-division encoder.
    NSArray *vectors=@[
        @[@"00000000000000000000000000000000",@"0000000000000000000000"],
        @[@"0000000000000000000000000000003d",@"000000000000000000000Z"],
        @[@"0000000000000000000000000000003e",@"0000000000000000000010"],
        @[@"ffffffffffffffffffffffffffffffff",@"7N42dgm5tFLK9N8MT7fHC7"],
        @[@"f2355b7089fd42ac84f98ac3c4ddb953",@"7n2wHs1TKAczGzO7Dd2rGr"]];
    for(NSArray *vector in vectors) {
        NSData *artist=join(@[SAPProtoBytes(1,hex(vector[0])),text(2,@"Known artist"),SAPProtoBytes(5,group(@[album(hex(vector[0]),@"Known release",1,2026,nil)]))]);
        NSDictionary *parsed=SAPParseArtistMetadata(response(artist),[@"spotify:artist:" stringByAppendingString:vector[1]]);
        assert(parsed && [parsed[@"sections"][0][@"releases"][0][@"uri"]isEqual:[@"spotify:album:" stringByAppendingString:vector[1]]]);
    }
    NSData *first=album(gid(1),@"First",1,2020,@"Deluxe");
    NSData *artist=join(@[SAPProtoBytes(1,gid(1)),text(2,@"Fixture artist"),
        releaseGroups(5,@[first,album(gid(2),@"EP",4,2024,nil),album(gid(3),@"Single",2,2023,nil),
            album(gid(4),@"Compilation",3,2021,nil),album(gid(5),@"Unknown",0,-1,nil),
            album(gid(6),@"Audiobook",5,2026,nil),album(gid(7),@"Podcast",6,2026,nil),
            album(NSData.data,@"Missing identity",1,2026,nil)]),
        releaseGroups(6,@[album(gid(8),@"Unspecified single or EP",0,2022,nil),album(gid(9),@"Later EP",4,2025,nil),album(gid(2),@"Duplicate EP",4,2024,nil)]),
        SAPProtoBytes(7,group(@[album(gid(10),@"Unspecified compilation",0,2022,nil)])),
        releaseGroups(8,@[first,album(gid(11),@"Guest release",1,2026,nil)])]);
    NSData *wire=response(artist);NSDictionary *catalog=SAPParseArtistMetadata(wire,artistURI);
    assert([catalog[@"name"]isEqual:@"Fixture artist"] && [catalog[@"release_count"]unsignedIntValue]==9);
    assert([catalog[@"skipped_incomplete_releases"]unsignedIntValue]==1);
    assert(([[catalog[@"sections"]valueForKey:@"title"]isEqual:@[@"Albums",@"EPs",@"Singles",@"Singles & EPs",@"Compilations",@"Appears on"]]));
    NSArray *albums=section(catalog,@"Albums")[@"releases"],*eps=section(catalog,@"EPs")[@"releases"];
    assert([albums[0][@"name"]isEqual:@"First (Deluxe)"] && [albums[0][@"year"]intValue]==2020 && [albums[0][@"date_order"]intValue]==20200229);
    assert([albums[1][@"year"]intValue]==0 && [eps[0][@"name"]isEqual:@"Later EP"] && [eps[1][@"type"]intValue]==4);
    assert([section(catalog,@"Appears on")[@"releases"]count]==1);
    assert(SAPParseArtistMetadata(wire,@"spotify:artist:0000000000000000000002")==nil);
    for(NSString *invalid in @[@"spotify:album:0000000000000000000001",@"spotify:artist:short",@"spotify:artist:000000000000000000000!"])
        assert(!SAPParseArtistMetadata(wire,invalid));
    assert(!SAPParseArtistMetadata([NSData dataWithBytes:(uint8_t[]){0x0a,0x7f,1} length:3],artistURI));
    assert(!SAPParseArtistMetadata(SAPProtoBytes(1,SAPProtoBytes(3,artist)),artistURI));
    assert(!SAPParseArtistMetadata(SAPProtoBytes(1,join(@[SAPProtoInteger(1,2),SAPProtoBytes(2,artist)])),artistURI));
    __block BOOL fetched=NO;
    SAPFetchArtistMetadata(artistURI,^(NSDictionary *value,NSString *error){assert(NSThread.isMainThread && value && !error);fetched=YES;});
    waitFor(^BOOL{return readCalls==1 && pendingRead!=nil;});
    void (^firstReply)(NSData *,NSString *)=pendingRead;pendingRead=nil;firstReply(wire,nil);waitFor(^BOOL{return fetched;});
    puts("PASS: verified Artist/GetEntity envelope and groups, EP enum4, sint32 dates, five fixed base62 vectors, six categories and cross-group deduplication");
    // One native group is one row, even when its editions have different IDs.
    // Equal titles in separate groups must remain separate releases.
    NSData *editionArtist=response(join(@[SAPProtoBytes(1,gid(1)),text(2,@"Editions"),
        SAPProtoBytes(5,group(@[album(gid(20),@"Same title",1,2026,nil),album(gid(21),@"Same title",1,2026,nil)])),
        SAPProtoBytes(5,group(@[album(gid(22),@"Same title",1,2026,nil)]))]));
    NSDictionary *editionCatalog=SAPParseArtistMetadata(editionArtist,artistURI);
    assert([editionCatalog[@"release_count"]intValue]==2 && [editionCatalog[@"resolved_edition_count"]intValue]==3);
    NSArray *editionRows=section(editionCatalog,@"Albums")[@"releases"];
    NSMutableSet *editionURIs=[NSMutableSet set];for(NSDictionary *row in editionRows)[editionURIs addObject:row[@"uri"]];
    assert([editionURIs containsObject:@"spotify:album:000000000000000000000k"] && [editionURIs containsObject:@"spotify:album:000000000000000000000m"] && ![editionURIs containsObject:@"spotify:album:000000000000000000000l"]);
    // A fully parsed alternate is initially selectable. A later hydrated first
    // edition replaces it; a failed first edition leaves the alternate usable.
    NSData *pendingEdition=response(join(@[SAPProtoBytes(1,gid(1)),text(2,@"Pending editions"),SAPProtoBytes(5,group(@[SAPProtoBytes(1,gid(20)),album(gid(21),@"Alternate",1,2026,nil)]))]));
    for(NSNumber *primaryWorks in @[@YES,@NO]){
        NSString *primary=@"spotify:album:000000000000000000000k";
        readResponses=@{artistURI:pendingEdition,primary:SAPProtoBytes(1,SAPProtoBytes(3,album(gid(primaryWorks.boolValue?20:99),@"Primary",1,2026,nil)))};fetched=NO;
        SAPFetchArtistMetadata(artistURI,^(NSDictionary *value,NSString *error){assert(value && !error && [value[@"release_count"]intValue]==1);NSDictionary *row=section(value,@"Albums")[@"releases"][0];assert([row[@"uri"]isEqual:primaryWorks.boolValue?primary:@"spotify:album:000000000000000000000l"]);fetched=YES;});waitFor(^BOOL{return fetched;});
    }
    NSDictionary *recorded=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"tests/fixtures/artist-release-groups.json"] options:0 error:nil];assert(recorded);
    for(NSDictionary *entry in recorded[@"artists"]){
        NSMutableDictionary *responses=[NSMutableDictionary dictionary];NSString *recordedURI=entry[@"uri"];
        responses[recordedURI]=[[NSData alloc]initWithBase64EncodedString:entry[@"response_base64"] options:0];
        for(NSString *u in recorded[@"albums"])responses[u]=[[NSData alloc]initWithBase64EncodedString:recorded[@"albums"][u] options:0];
        readResponses=responses;fetched=NO;
        SAPFetchArtistMetadata(recordedURI,^(NSDictionary *value,NSString *error){assert(value && !error && [value[@"release_count"]isEqual:entry[@"expected_groups"]]);NSMutableSet *groupKeys=[NSMutableSet set];for(NSDictionary *s in value[@"sections"])for(NSDictionary *row in s[@"releases"]){NSString *key=row[@"native_group_key"];assert(key && ![groupKeys containsObject:key]);[groupKeys addObject:key];assert([row[@"native_edition_index"]intValue]==0);}fetched=YES;});waitFor(^BOOL{return fetched;});
    }
    readResponses=@{artistURI:wire};
    puts("PASS: native edition groups produce one row each; separate equal titles survive; late preferred metadata and fallback work; recorded catalogs replay as 9 and 69 releases instead of 9 and 85");


    // The void wrapper discards its cancel handle. The load must stay alive
    // after the caller's autorelease pool drains until the async RPC completes.
    readResponses=@{artistURI:wire};fetched=NO;
    @autoreleasepool {
        SAPFetchArtistMetadata(artistURI,^(NSDictionary *value,NSString *error){
            assert(NSThread.isMainThread && value && !error);fetched=YES;
        });
    }
    waitFor(^BOOL{return fetched;});

    // Spotify may return AlbumGroup entries with only a GID. These were all
    // discarded by the former parser; the fixture deliberately has no names.
    NSMutableArray *references=[NSMutableArray array];for(unsigned i=2;i<=7;i++)[references addObject:SAPProtoBytes(1,gid(i))];
    NSData *referenceArtist=join(@[SAPProtoBytes(1,gid(1)),text(2,@"Reference-only artist"),releaseGroups(5,references),SAPProtoBytes(6,group(@[references[0]]))]);
    NSData *referenceWire=response(referenceArtist);NSDictionary *referenceCatalog=SAPParseArtistMetadata(referenceWire,artistURI);
    assert([referenceCatalog[@"release_count"]intValue]==0 && [referenceCatalog[@"pending_releases"]count]==6);
    assert([referenceCatalog[@"reference_count"]intValue]==6 && [referenceCatalog[@"skipped_incomplete_releases"]intValue]==0);
    NSData *resolvedAlbumWire=SAPProtoBytes(1,SAPProtoBytes(3,album(gid(2),@"Resolved album",1,2026,@"Deluxe Edition")));
    readResponses=@{artistURI:referenceWire,
        @"spotify:album:0000000000000000000002":resolvedAlbumWire,
        @"spotify:album:0000000000000000000003":SAPProtoBytes(1,SAPProtoBytes(3,album(gid(3),@"Resolved single",2,2025,nil))),
        @"spotify:album:0000000000000000000004":SAPProtoBytes(1,SAPProtoBytes(3,album(gid(4),@"Resolved EP",4,2024,nil))),
        @"spotify:album:0000000000000000000005":SAPProtoBytes(1,SAPProtoBytes(3,album(gid(99),@"Wrong album",1,2026,nil))),
        @"spotify:album:0000000000000000000006":NSNull.null,
        @"spotify:album:0000000000000000000007":SAPProtoBytes(1,SAPProtoBytes(3,album(gid(7),@"Non-music",5,2026,nil)))};
    fetched=NO;metadataEvents=[NSMutableArray array];tracing=YES;__block NSUInteger completedMetadata=0;
    SAPFetchArtistMetadataCancellable(artistURI,^(NSUInteger done,NSUInteger total){assert(NSThread.isMainThread && total==6);completedMetadata=done;},^(NSDictionary *value,NSString *error){
        assert(NSThread.isMainThread && value && !error);
        assert([value[@"release_count"]intValue]==3 && [value[@"hydrated_releases"]intValue]==3 && [value[@"unresolved_releases"]intValue]==2);
        assert([value[@"load_warning"]length] && section(value,@"Albums") && section(value,@"EPs") && section(value,@"Singles"));fetched=YES;
    });
    waitFor(^BOOL{return fetched;});assert(completedMetadata==6 && maximumReadsActive==4 && readsActive==0);
    BOOL captured=NO,mismatch=NO,failedRead=NO;
    for(NSDictionary *event in metadataEvents) {
        NSDictionary *facts=event[@"facts"];
        if([facts[@"kind"]isEqual:@"artist"]) {
            NSString *base64=[facts[@"public_metadata_base64_chunks"]componentsJoinedByString:@""];
            assert([[[NSData alloc]initWithBase64EncodedString:base64 options:0]isEqual:referenceWire]);
            assert([facts[@"body_complete"]boolValue] && [facts[@"facts"][@"references_needing_metadata"]intValue]==6);captured=YES;
        }
        if([facts[@"parse_result"]isEqual:@"album_identity_mismatch"])mismatch=YES;
        if([facts[@"kind"]isEqual:@"album"] && ![facts[@"response_received"]boolValue])failedRead=YES;
        if([facts[@"kind"]isEqual:@"album"] && [facts[@"requested_uri"]isEqual:@"spotify:album:0000000000000000000002"]) {
            NSDictionary *releaseFacts=facts[@"facts"];
            assert([releaseFacts[@"album_name"]isEqual:@"Resolved album (Deluxe Edition)"]);
            assert([releaseFacts[@"wire_album_name"]isEqual:@"Resolved album"]);
            assert([releaseFacts[@"version"]isEqual:@"Deluxe Edition"]);
            assert([releaseFacts[@"year"]intValue]==2026);
            assert([releaseFacts[@"source_group"]intValue]==5 && [releaseFacts[@"source_group_label"]isEqual:@"Albums"]);
            NSString *base64=[facts[@"public_metadata_base64_chunks"]componentsJoinedByString:@""];
            assert([facts[@"body_complete"]boolValue] && [[[NSData alloc]initWithBase64EncodedString:base64 options:0]isEqual:resolvedAlbumWire]);
        }
    }
    assert(captured && mismatch && failedRead);
    NSUInteger traceCount=metadataEvents.count;tracing=NO;fetched=NO;
    SAPFetchArtistMetadata(artistURI,^(NSDictionary *value,NSString *error){assert([value[@"release_count"]intValue]==3 && !error);fetched=YES;});
    waitFor(^BOOL{return fetched;});assert(metadataEvents.count==traceCount);
    // Cancellation before the queued start runs sends no request and completes once.
    readResponses=@{artistURI:referenceWire};NSUInteger beforePrestartReads=readCalls;
    __block NSUInteger prestartCompletions=0;
    dispatch_block_t cancelBeforeStart=SAPFetchArtistMetadataCancellable(artistURI,nil,^(NSDictionary *value,NSString *error){
        assert(NSThread.isMainThread && !value && [error isEqual:@"Catalog loading cancelled."]);prestartCompletions++;
    });
    cancelBeforeStart();assert(prestartCompletions==1 && readCalls==beforePrestartReads);
    __block BOOL startDrained=NO;dispatch_async(dispatch_get_main_queue(),^{startDrained=YES;});
    waitFor(^BOOL{return startDrained;});assert(readCalls==beforePrestartReads && prestartCompletions==1);

    // A sent artist request is cancelled, and a late transport delivery cannot
    // start album hydration or complete the load a second time.
    readResponses=nil;pendingRead=nil;NSUInteger beforeArtistCancelReads=readCalls,beforeArtistCancelCalls=readCancellations;
    __block NSUInteger artistCancelCompletions=0;
    dispatch_block_t cancelArtist=SAPFetchArtistMetadataCancellable(artistURI,nil,^(NSDictionary *value,NSString *error){
        assert(!value && [error isEqual:@"Catalog loading cancelled."]);artistCancelCompletions++;
    });
    waitFor(^BOOL{return readCalls==beforeArtistCancelReads+1 && pendingRead!=nil;});
    void (^lateArtistReply)(NSData *,NSString *)=pendingRead;pendingRead=nil;cancelArtist();lateArtistReply(referenceWire,nil);
    assert(readCancellations==beforeArtistCancelCalls+1 && artistCancelCompletions==1);
    assert(readCalls==beforeArtistCancelReads+1 && artistCancelCompletions==1);

    // Cancel during hydration: the one completed request is removed, and the
    // three outstanding reads are cancelled; no remaining URI is requested.
    __block NSUInteger cancelledCalls=0;__block dispatch_block_t cancel=nil;
    readResponses=@{artistURI:referenceWire};NSUInteger beforeCancelReads=readCalls,beforeCancelCancellations=readCancellations;staggerStartRead=readCalls+1;
    cancel=SAPFetchArtistMetadataCancellable(artistURI,^(NSUInteger done,NSUInteger total){if(done==1)cancel();},^(NSDictionary *value,NSString *error){cancelledCalls++;});
    waitFor(^BOOL{return cancelledCalls==1 && readsActive==0;});
    staggerStartRead=0;assert(readCalls==beforeCancelReads+5 && cancelledCalls==1 && readCancellations==beforeCancelCancellations+3);cancel=nil;
    tracing=YES;fetched=NO;
    SAPFetchArtistMetadata(nil,^(NSDictionary *value,NSString *error){assert(!value && error.length);fetched=YES;});waitFor(^BOOL{return fetched;});tracing=NO;
    // Empty artist groups must be distinguishable from a transport or hydration
    // failure; do not report a successful catalog of zero without an explanation.
    readResponses=@{artistURI:response(join(@[SAPProtoBytes(1,gid(1)),text(2,@"No release references")]))};fetched=NO;
    SAPFetchArtistMetadata(artistURI,^(NSDictionary *value,NSString *error){assert(value && [value[@"release_count"]intValue]==0 && [error containsString:@"without release IDs"]);fetched=YES;});waitFor(^BOOL{return fetched;});
    // Body capture must fit the trace record limit even after base64 encoding.
    for(NSNumber *size in @[@64000,@70000]) {
        NSData *large=response(join(@[SAPProtoBytes(1,gid(1)),text(2,@"Bounded metadata"),SAPProtoBytes(99,[NSMutableData dataWithLength:size.unsignedIntegerValue])]));
        readResponses=@{artistURI:large};metadataEvents=[NSMutableArray array];tracing=YES;fetched=NO;
        SAPFetchArtistMetadata(artistURI,^(NSDictionary *value,NSString *error){fetched=YES;});waitFor(^BOOL{return fetched;});tracing=NO;
        BOOL checked=NO;
        for(NSDictionary *event in metadataEvents)if([event[@"facts"][@"kind"]isEqual:@"artist"]) {
            NSDictionary *facts=event[@"facts"];
            assert([NSJSONSerialization dataWithJSONObject:event options:0 error:nil].length<128*1024);
            assert([facts[@"body_complete"]boolValue]==(large.length<=64*1024));
            if(large.length>64*1024)assert(!facts[@"public_metadata_base64_chunks"]);checked=YES;
        }
        assert(checked);
    }
    puts("PASS: GID-only refs hydrated through native album GetEntity; max4 reads; duplicate IDs, wrong identity, timeout, nonmusic, partial warning, cancellation, empty groups; exact diagnostic body only when ON");
    puts("PASS: public metadata body capture stays under trace record limit; oversized bodies retain parser facts and are explicitly marked incomplete");

    // Album download track lists use the actual 9.1.90 Disc.track=3 and can
    // contain GIDs without names or canonical URIs, just like artist references.
    NSData *discOne=join(@[SAPProtoBytes(3,SAPProtoBytes(1,gid(2))),SAPProtoBytes(3,join(@[SAPProtoBytes(1,gid(3)),text(36,@"spotify:track:0000000000000000000003")]))]);
    NSData *discTwo=join(@[SAPProtoBytes(3,SAPProtoBytes(1,gid(2))),SAPProtoBytes(3,text(36,@"spotify:track:0000000000000000000004"))]);
    NSString *albumURI=@"spotify:album:0000000000000000000001",*parseReason=nil;
    uint8_t imageBytes[20];for(unsigned i=0;i<20;i++)imageBytes[i]=i;
    NSData *cover=SAPProtoBytes(1,[NSData dataWithBytes:imageBytes length:20]);
    NSData *fullAlbum=SAPProtoBytes(1,SAPProtoBytes(3,join(@[SAPProtoBytes(1,gid(1)),SAPProtoBytes(11,discOne),SAPProtoBytes(11,discTwo),SAPProtoBytes(9,cover),SAPProtoBytes(17,SAPProtoBytes(1,cover))])));
    NSArray *downloadTracks=SAPParseArtistAlbumTrackURIs(fullAlbum,albumURI,&parseReason);
    assert(([downloadTracks isEqual:@[@"spotify:track:0000000000000000000002",@"spotify:track:0000000000000000000003",@"spotify:track:0000000000000000000004"]]));
    assert([parseReason isEqual:@"verified_album_tracks"]);
    assert(!SAPParseArtistAlbumTrackURIs(fullAlbum,@"spotify:album:0000000000000000000002",&parseReason) && [parseReason isEqual:@"album_identity_mismatch"]);
    NSData *mismatchedTrack=join(@[SAPProtoBytes(1,gid(2)),text(36,@"spotify:track:0000000000000000000003")]);
    NSData *mismatchedAlbum=SAPProtoBytes(1,SAPProtoBytes(3,join(@[SAPProtoBytes(1,gid(1)),SAPProtoBytes(11,SAPProtoBytes(3,mismatchedTrack))])));
    assert(!SAPParseArtistAlbumTrackURIs(mismatchedAlbum,albumURI,&parseReason) && [parseReason isEqual:@"track_identity_mismatch"]);
    NSData *missingTrack=SAPProtoBytes(1,SAPProtoBytes(3,join(@[SAPProtoBytes(1,gid(1)),SAPProtoBytes(11,SAPProtoBytes(3,text(2,@"No identity")))])));
    assert(!SAPParseArtistAlbumTrackURIs(missingTrack,albumURI,&parseReason) && [parseReason isEqual:@"track_identity_missing"]);
    readResponses=@{albumURI:fullAlbum};fetched=NO;metadataEvents=[NSMutableArray array];tracing=YES;
    SAPFetchArtistAlbumTrackURIs(albumURI,^(NSArray *tracks,NSString *error){assert(NSThread.isMainThread && [tracks isEqual:downloadTracks] && !error);fetched=YES;});waitFor(^BOOL{return fetched;});
    tracing=NO;BOOL coverFound=NO;
    for(NSDictionary *event in metadataEvents)if([event[@"facts"][@"kind"]isEqual:@"album_download_tracks"]) {
        NSDictionary *facts=event[@"facts"][@"facts"];assert([facts[@"cover_count"]intValue]==1);
        assert([facts[@"covers"][0][@"url"]isEqual:@"https://i.scdn.co/image/000102030405060708090a0b0c0d0e0f10111213"]);coverFound=YES;
    }
    assert(coverFound);
    puts("PASS: verified native album GID, every disc/track GID and canonical URI; duplicate tracks deduplicated; mismatched or missing identities prevent downloads; async track list callback on main");
    puts("PASS: cover and cover_group image IDs decoded, deduplicated and mapped to Vitrine's existing Spotify image CDN format in diagnostics");

    // Catalog hydration must expose bounded membership from its existing reply,
    // including a clear unavailable result when Spotify returns no member list.
    NSData *oneReference=response(join(@[SAPProtoBytes(1,gid(1)),text(2,@"Membership artist"),SAPProtoBytes(5,group(@[SAPProtoBytes(1,gid(1))]))]));
    for(NSNumber *trackCount in @[@0,@1,@3,@513]) {
        NSMutableArray *members=[NSMutableArray array];
        for(NSUInteger i=1;i<=trackCount.unsignedIntegerValue;i++)
            [members addObject:SAPProtoBytes(3,text(36,[NSString stringWithFormat:@"spotify:track:%022lu",(unsigned long)i]))];
        NSData *catalogAlbum=SAPProtoBytes(1,SAPProtoBytes(3,join(@[album(gid(1),@"Membership album",1,2026,nil),SAPProtoBytes(11,join(members))])));
        for(NSNumber *enabled in @[@NO,@YES]) {
            readResponses=@{artistURI:oneReference,albumURI:catalogAlbum};metadataEvents=[NSMutableArray array];tracing=enabled.boolValue;fetched=NO;
            NSUInteger beforeReads=readCalls;
            SAPFetchArtistMetadata(artistURI,^(NSDictionary *value,NSString *error){assert(value && !error);NSDictionary *item=section(value,@"Albums")[@"releases"][0];assert([item[@"track_count_verified"]boolValue]==(trackCount.unsignedIntegerValue>0));assert([item[@"track_uris"]count]==trackCount.unsignedIntegerValue);if(trackCount.unsignedIntegerValue)assert([item[@"verified_track_count"]unsignedIntegerValue]==trackCount.unsignedIntegerValue && [item[@"track_uris"][0]isEqual:@"spotify:track:0000000000000000000001"]);fetched=YES;});waitFor(^BOOL{return fetched;});tracing=NO;
            assert(readCalls==beforeReads+2);
            if(!enabled.boolValue) {assert(metadataEvents.count==0);continue;}
            BOOL membershipFound=NO;
            for(NSDictionary *event in metadataEvents)if([event[@"facts"][@"kind"]isEqual:@"album"]) {
                NSDictionary *facts=event[@"facts"][@"facts"];NSUInteger count=trackCount.unsignedIntegerValue;
                NSString *base64=[event[@"facts"][@"public_metadata_base64_chunks"]componentsJoinedByString:@""];
                assert([event[@"facts"][@"body_complete"]boolValue] && [[[NSData alloc]initWithBase64EncodedString:base64 options:0]isEqual:catalogAlbum]);
                assert([facts[@"album_name"]isEqual:@"Membership album"] && [facts[@"wire_album_name"]isEqual:@"Membership album"]);
                assert([facts[@"source_group"]intValue]==5 && [facts[@"source_group_label"]isEqual:@"Albums"]);
                assert([facts[@"track_membership_available"]boolValue]==(count>0));
                assert([facts[@"track_count"]unsignedIntegerValue]==count && [facts[@"track_uris"]count]==MIN(count,(NSUInteger)512));
                assert([facts[@"track_uris_complete"]boolValue]==(count>0 && count<=512));
                assert([facts[@"track_parse_result"]isEqual:count?@"verified_album_tracks":@"album_tracks_missing"]);
                if(count)assert([facts[@"track_uris"][0]isEqual:@"spotify:track:0000000000000000000001"]);
                assert([NSJSONSerialization dataWithJSONObject:event options:0 error:nil].length<128*1024);membershipFound=YES;
            }
            assert(membershipFound);
        }
    }
    puts("PASS: catalog diagnostics reuse the hydration reply with no extra reads; missing membership is unavailable; 513 tracks retain count with a 512-URI incomplete sample; diagnostics off emit nothing");
    NSData *progressiveWire=response(join(@[SAPProtoBytes(1,gid(1)),text(2,@"Progressive artist"),SAPProtoBytes(5,group(@[album(gid(22),@"Ready",1,2026,nil)])),SAPProtoBytes(5,group(@[SAPProtoBytes(1,gid(20)),album(gid(21),@"Alternate",1,2026,nil)]))]));
    readResponses=@{artistURI:progressiveWire,@"spotify:album:000000000000000000000k":SAPProtoBytes(1,SAPProtoBytes(3,album(gid(20),@"Preferred",1,2026,nil)))};fetched=NO;__block NSUInteger previews=0;
    SAPFetchArtistMetadataProgressively(artistURI,nil,^(NSDictionary *value){assert(NSThread.isMainThread && !fetched);assert([value[@"release_count"]intValue]==1 && [section(value,@"Albums")[@"releases"][0][@"name"]isEqual:@"Ready"]);assert([value[@"observation_releases"]count]==3);previews++;},^(NSDictionary *value,NSString *error){assert(!error && previews==1 && [value[@"release_count"]intValue]==2);BOOL ready=NO,preferred=NO;for(NSDictionary *row in section(value,@"Albums")[@"releases"]){ready|=[row[@"name"]isEqual:@"Ready"];preferred|=[row[@"name"]isEqual:@"Preferred"];assert(![row[@"name"]isEqual:@"Alternate"]);}assert(ready&&preferred);fetched=YES;});waitFor(^BOOL{return fetched;});
    puts("PASS: progressive catalogs expose ready groups before completion, defer unsettled edition identities, retain full observation scope, and preserve visible identities in the final catalog");
} return 0; }
