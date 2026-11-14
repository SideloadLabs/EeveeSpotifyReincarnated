#import "ExportAlbumMetadata.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import "ExportArtwork.h"
#import "DiagnosticTrace.h"

static NSString *const SAPMetadataService = @"spotify.metadata_esperanto.proto.ClassicMetadataService";

static BOOL SAPValidSpotifyURI(NSString *uri, NSString *kind) {
    if (![uri isKindOfClass:NSString.class]) return NO;
    NSString *prefix = [@"spotify:" stringByAppendingFormat:@"%@:", kind];
    if (![uri hasPrefix:prefix] || uri.length != prefix.length + 22) return NO;
    NSString *identifier = [uri substringFromIndex:prefix.length];
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"] invertedSet]; });
    return [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSString *SAPTrackURIFromGID(NSData *gid) {
    if (![gid isKindOfClass:NSData.class] || gid.length != 16) return nil;

    // Spotify IDs are unsigned 128-bit values encoded as 22 base-62 digits.
    static const char alphabet[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    unsigned digits[22] = {0};
    const uint8_t *bytes = gid.bytes;
    for (NSUInteger byteIndex = 0; byteIndex < gid.length; byteIndex++) {
        unsigned carry = bytes[byteIndex];
        for (NSInteger digitIndex = 21; digitIndex >= 0; digitIndex--) {
            carry += digits[digitIndex] * 256;
            digits[digitIndex] = carry % 62;
            carry /= 62;
        }
        if (carry) return nil;
    }

    char identifier[22];
    for (NSUInteger i = 0; i < 22; i++) identifier[i] = alphabet[digits[i]];
    NSString *base62 = [[NSString alloc] initWithBytes:identifier length:sizeof(identifier)
                                             encoding:NSASCIIStringEncoding];
    return base62 ? [@"spotify:track:" stringByAppendingString:base62] : nil;
}

NSDictionary *SAPParseExportAlbumMetadata(NSData *response, NSString *albumURI) {
    if (!SAPValidSpotifyURI(albumURI, @"album") || ![response isKindOfClass:NSData.class]) return nil;
    NSArray *envelope = SAPProtoFields(response);
    NSData *itemData = SAPProtoData(envelope, 1);
    NSData *albumData = SAPProtoData(SAPProtoFields(itemData), 3);
    NSArray *albumFields = SAPProtoFields(albumData);
    NSString *albumName = SAPProtoString(albumFields, 2);
    if (!albumName.length) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    NSUInteger discFallback = 0;
    for (NSDictionary *discField in albumFields) {
        if ([discField[@"number"] unsignedIntegerValue] != 11 || [discField[@"wire"] unsignedIntegerValue] != 2) continue;
        NSArray *discFields = SAPProtoFields(discField[@"value"]);
        discFallback++;
        int64_t discValue = SAPProtoSInt(discFields, 1, (int64_t)discFallback);
        if (discValue <= 0) return nil;
        NSUInteger discNumber = (NSUInteger)discValue;
        NSUInteger trackFallback = 0;
        for (NSDictionary *trackField in discFields) {
            if ([trackField[@"number"] unsignedIntegerValue] != 3 || [trackField[@"wire"] unsignedIntegerValue] != 2) continue;
            NSArray *trackFields = SAPProtoFields(trackField[@"value"]);
            NSData *gid = SAPProtoData(trackFields, 1);
            NSString *gidURI = gid ? SAPTrackURIFromGID(gid) : nil;
            NSString *explicitURI = SAPProtoString(trackFields, 36);
            if (gid && !gidURI) return nil;
            if (SAPValidSpotifyURI(explicitURI, @"track") && gidURI &&
                ![explicitURI isEqualToString:gidURI]) return nil;
            NSString *uri = SAPValidSpotifyURI(explicitURI, @"track") ? explicitURI : gidURI;
            if (!uri && !gid) uri = explicitURI;
            NSString *name = SAPProtoString(trackFields, 2);
            if (!SAPValidSpotifyURI(uri, @"track")) return nil;
            trackFallback++;
            int64_t trackValue = SAPProtoSInt(trackFields, 5, (int64_t)trackFallback);
            int64_t durationValue = SAPProtoSInt(trackFields, 7, 0);
            if (trackValue <= 0 || trackValue > 100000) return nil;
            NSUInteger trackNumber = (NSUInteger)trackValue;
            // Album GetEntity may contain a minimal track reference (gid only)
            // without duration/audio files. Keep it and let resolveNext fetch
            // the full track metadata; only impossible values are rejected.
            if (durationValue < 0 || durationValue > 24LL * 60 * 60 * 1000) return nil;
            uint64_t duration = (uint64_t)durationValue;
            if (!discNumber || !trackNumber) return nil;
            NSMutableArray *audioFiles=[NSMutableArray array];
            for(NSDictionary *field in trackFields)if([field[@"number"]unsignedIntValue]==12&&[field[@"wire"]unsignedIntValue]==2){
                NSData *identifier=SAPProtoData(SAPProtoFields(field[@"value"]),1);
                if(identifier.length==20&&audioFiles.count<64&&![audioFiles containsObject:identifier])[audioFiles addObject:identifier];
            }
            BOOL metadataComplete = name.length > 0 && duration > 0 && audioFiles.count > 0;
            [tracks addObject:@{@"uri": uri, @"name": name ?: @"",
                                @"disc": @(discNumber), @"number": @(trackNumber),
                                @"duration_ms": @(duration), @"audio_files":audioFiles,
                                @"cover_image_uri":SAPExportAlbumCoverURI(albumFields)?:@"", @"album_uri":albumURI,
                                @"album_name":albumName,@"year":@(SAPProtoSInt(SAPProtoFields(SAPProtoData(albumFields,6)),1,0)),@"artist_name":SAPExportArtistName(albumFields,3)?:@"Unknown artist",
                                @"metadata_complete": @(metadataComplete)}];
            if (tracks.count > 1000) return nil;
        }
    }
    if (!tracks.count) return nil;
    return @{@"uri": albumURI, @"name": albumName, @"tracks": [tracks copy], @"cover_image_uri":SAPExportAlbumCoverURI(albumFields)?:@""};
}

void SAPFetchExportAlbumMetadata(NSString *albumURI,
                            void (^completion)(NSDictionary *album, NSString *error)) {
    if (!SAPValidSpotifyURI(albumURI, @"album")) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Invalid Spotify album URI"); });
        return;
    }
    NSData *payload = SAPProtoBytes(1, [albumURI dataUsingEncoding:NSUTF8StringEncoding]);
    SAPCallReadOnlyService(SAPMetadataService, @"GetEntity", payload, ^(NSData *response, NSString *error) {
        NSDictionary *album = response ? SAPParseExportAlbumMetadata(response, albumURI) : nil;
        if(SAPTraceIsActive()) {
            NSArray *item=SAPProtoFields(SAPProtoData(SAPProtoFields(response),1));
            NSArray *fields=SAPProtoFields(SAPProtoData(item,3));NSMutableArray *shape=[NSMutableArray array];
            for(NSDictionary *field in fields)if(shape.count<64)[shape addObject:@{@"field":field[@"number"],@"wire":field[@"wire"],@"bytes":[field[@"value"]isKindOfClass:NSData.class]?@([field[@"value"]length]):@0}];
            SAP_TRACE("export","album_metadata_decoded",0,@{@"album_uri":albumURI,@"response_bytes":@(response.length),@"parsed":@(album!=nil),@"track_count":@([album[@"tracks"]count]),@"album_fields":shape,@"schema_items_truncated":@(fields.count>shape.count)});
        }
        if (completion) completion(album, album ? nil : (error ?: @"Album metadata was incomplete"));
    });
}
