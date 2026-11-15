#import <Foundation/Foundation.h>
#import "ExportAlbumMetadata.h"
#import "WireProto.h"
#import "ExportArtwork.h"
#include <assert.h>

void SAPCallReadOnlyService(NSString *serviceName, NSString *method, NSData *payload,
                            void (^completion)(NSData *, NSString *)) {
    (void)serviceName; (void)method; (void)payload; (void)completion;
}

static NSData *join(NSArray<NSData *> *parts) {
    NSMutableData *data = [NSMutableData data];
    for (NSData *part in parts) [data appendData:part];
    return data;
}
static NSData *textField(unsigned field, NSString *value) {
    return SAPProtoBytes(field, [value dataUsingEncoding:NSUTF8StringEncoding]);
}
static NSData *dataField(unsigned field, const uint8_t *bytes, NSUInteger length) {
    return SAPProtoBytes(field, [NSData dataWithBytes:bytes length:length]);
}
static NSData *track(NSString *name, NSString *uri, unsigned number) {
    static const uint8_t fileID[20] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19};
    NSData *audioFile = SAPProtoBytes(1, [NSData dataWithBytes:fileID length:sizeof(fileID)]);
    return join(@[textField(2,name), SAPProtoInteger(5,(uint64_t)number*2), SAPProtoInteger(7,360000),
                  SAPProtoBytes(12,audioFile), textField(36,uri)]);
}
int main(void) {
    @autoreleasepool {
        NSString *albumURI = @"spotify:album:0123456789abcdefghijAB";
        NSString *firstURI = @"spotify:track:0123456789abcdefghijAC";
        NSString *secondURI = @"spotify:track:0123456789abcdefghijAD";
        NSData *disc1 = join(@[SAPProtoInteger(1,2*1), SAPProtoBytes(3,track(@"First",firstURI,1))]);
        NSData *disc2 = join(@[SAPProtoInteger(1,2*2), SAPProtoBytes(3,track(@"Second",secondURI,1))]);
        uint8_t coverID[20];memset(coverID,0xab,20);
        NSData *cover=SAPProtoBytes(1,[NSData dataWithBytes:coverID length:20]);
        NSData *album = join(@[textField(2,@"Album"),SAPProtoBytes(17,SAPProtoBytes(1,cover)),SAPProtoBytes(11,disc1),SAPProtoBytes(11,disc2)]);
        NSData *response = SAPProtoBytes(1,SAPProtoBytes(3,album));
        NSDictionary *parsed = SAPParseExportAlbumMetadata(response,albumURI);
        assert([parsed[@"name"] isEqual:@"Album"]);
        NSArray *tracks = parsed[@"tracks"];
        assert(tracks.count == 2);
        assert([parsed[@"cover_image_uri"]isEqual:@"spotify:image:abababababababababababababababababababab"]);
        assert([tracks[0][@"cover_image_uri"]isEqual:parsed[@"cover_image_uri"]]);
        assert([tracks[1][@"album_uri"]isEqual:albumURI]);
        assert([SAPExportAlbumCoverURI(SAPProtoFields(SAPProtoBytes(9,cover)))isEqual:parsed[@"cover_image_uri"]]);
        assert(SAPExportAlbumCoverURI(@[])==nil);
        NSURL *exportURL=[NSURL fileURLWithPath:@"/tmp/cover-fixture.ogg"];
        NSDictionary *art=@{@"jpeg":[NSData data],@"width":@640,@"height":@640};
        SAPAttachExportArtwork(exportURL,art);
        assert(SAPAttachedExportArtwork(exportURL)==art);
        NSURL *otherURL=[NSURL fileURLWithPath:@"/tmp/another-fixture.ogg"];
        assert(SAPAttachedExportArtwork(otherURL)==nil);
        SAPAttachExportArtwork(exportURL,nil);assert(SAPAttachedExportArtwork(exportURL)==nil);

        assert([tracks[0][@"uri"] isEqual:firstURI]);
        assert([tracks[1][@"disc"] unsignedIntegerValue] == 2);
        assert([tracks[1][@"duration_ms"] unsignedIntegerValue] == 180000);
        assert([tracks[0][@"metadata_complete"] boolValue]);
        assert(SAPParseExportAlbumMetadata(response,@"spotify:playlist:0123456789abcdefghijAB") == nil);

        NSData *badTrack = join(@[textField(2,@"Missing URI"),SAPProtoInteger(5,1),SAPProtoInteger(7,360000)]);
        NSData *badAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,badTrack))]);
        assert(SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,badAlbum)),albumURI) == nil);

        // Official metadata Track references carry a 16-byte gid and may omit
        // name, duration, audio files, and the legacy string URI field.
        const uint8_t gid[] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
        NSData *reference = join(@[dataField(1,gid,sizeof(gid))]);
        assert([SAPExportAlbumURI(SAPProtoFields(reference))isEqual:@"spotify:album:01TUwCKr0qGUD2dQQItYSQ"]);
        NSData *referenceDisc = join(@[SAPProtoBytes(3,reference), SAPProtoBytes(3,reference)]);
        NSData *referenceAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,referenceDisc)]);
        NSDictionary *referenceParsed = SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,referenceAlbum)),albumURI);
        NSArray *references = referenceParsed[@"tracks"];
        assert(references.count == 2);
        assert([references[0][@"uri"] isEqual:@"spotify:track:01TUwCKr0qGUD2dQQItYSQ"]);
        assert([references[0][@"name"] isEqual:@""]);
        assert([references[0][@"duration_ms"] unsignedIntegerValue] == 0);
        assert(![references[0][@"metadata_complete"] boolValue]);
        assert([references[0][@"number"] unsignedIntegerValue] == 1);
        assert([references[1][@"number"] unsignedIntegerValue] == 2);

        const uint8_t knownTrackGID[] = {0xc1,0x09,0xcf,0x80,0x92,0x17,0x48,0xc1,
                                         0xa1,0x9e,0x82,0x12,0xc6,0xbc,0x30,0xf0};
        NSData *knownTrack = dataField(1,knownTrackGID,sizeof(knownTrackGID));
        NSData *knownTrackAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,knownTrack))]);
        NSDictionary *knownTrackParsed = SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,knownTrackAlbum)),albumURI);
        assert([knownTrackParsed[@"tracks"][0][@"uri"] isEqual:@"spotify:track:5Sg09MvHqNWPWsYeuY2toY"]);

        // The alphabet and byte order match librespot's SpotifyId base-62
        // encoding. This nonzero 128-bit vector was independently converted.
        NSString *gidURI = @"spotify:track:01TUwCKr0qGUD2dQQItYSQ";
        NSData *consistentTrack = join(@[dataField(1,gid,sizeof(gid)),textField(36,gidURI)]);
        NSData *consistentAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,consistentTrack))]);
        NSDictionary *consistentParsed = SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,consistentAlbum)),albumURI);
        assert([consistentParsed[@"tracks"][0][@"uri"] isEqual:gidURI]);
        NSData *inconsistentTrack = join(@[dataField(1,gid,sizeof(gid)),textField(36,secondURI)]);
        NSData *inconsistentAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,inconsistentTrack))]);
        assert(SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,inconsistentAlbum)),albumURI) == nil);

        const uint8_t shortGid[] = {1,2,3};
        NSData *malformedReference = join(@[dataField(1,shortGid,sizeof(shortGid))]);
        NSData *malformedAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,malformedReference))]);
        assert(SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,malformedAlbum)),albumURI) == nil);

        // Inline track metadata remains usable and is marked complete.
        NSData *inlineAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,track(@"Inline",firstURI,7)))]);
        NSDictionary *inlineParsed = SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,inlineAlbum)),albumURI);
        assert([inlineParsed[@"tracks"][0][@"name"] isEqual:@"Inline"]);
        assert([inlineParsed[@"tracks"][0][@"metadata_complete"] boolValue]);

        NSData *noFileTrack = join(@[dataField(1,gid,sizeof(gid)),textField(2,@"Track"),SAPProtoInteger(7,360000)]);
        NSData *noFileAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,noFileTrack))]);
        NSDictionary *noFileParsed = SAPParseExportAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,noFileAlbum)),albumURI);
        assert(![noFileParsed[@"tracks"][0][@"metadata_complete"] boolValue]);
    }
    return 0;
}
