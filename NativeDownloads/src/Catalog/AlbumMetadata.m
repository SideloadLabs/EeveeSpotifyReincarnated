#import "AlbumMetadata.h"
#import "TrackDownload.h"
#import "WireProto.h"

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

NSDictionary *SAPParseAlbumMetadata(NSData *response, NSString *albumURI) {
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
        NSUInteger discNumber = (NSUInteger)SAPProtoNumber(discFields, 1, ++discFallback);
        NSUInteger trackFallback = 0;
        for (NSDictionary *trackField in discFields) {
            if ([trackField[@"number"] unsignedIntegerValue] != 3 || [trackField[@"wire"] unsignedIntegerValue] != 2) continue;
            NSArray *trackFields = SAPProtoFields(trackField[@"value"]);
            NSString *uri = SAPProtoString(trackFields, 36);
            NSString *name = SAPProtoString(trackFields, 2);
            if (!SAPValidSpotifyURI(uri, @"track") || !name.length) return nil;
            NSUInteger trackNumber = (NSUInteger)SAPProtoNumber(trackFields, 5, ++trackFallback);
            uint64_t duration = SAPProtoNumber(trackFields, 7, 0);
            if (!discNumber || !trackNumber || !duration || duration > 24ULL * 60 * 60 * 1000) return nil;
            [tracks addObject:@{@"uri": uri, @"name": name,
                                @"disc": @(discNumber), @"number": @(trackNumber),
                                @"duration_ms": @(duration)}];
            if (tracks.count > 1000) return nil;
        }
    }
    if (!tracks.count) return nil;
    return @{@"uri": albumURI, @"name": albumName, @"tracks": [tracks copy]};
}

void SAPFetchAlbumMetadata(NSString *albumURI,
                            void (^completion)(NSDictionary *album, NSString *error)) {
    if (!SAPValidSpotifyURI(albumURI, @"album")) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Invalid Spotify album URI"); });
        return;
    }
    NSData *payload = SAPProtoBytes(1, [albumURI dataUsingEncoding:NSUTF8StringEncoding]);
    SAPCallReadOnlyService(SAPMetadataService, @"GetEntity", payload, ^(NSData *response, NSString *error) {
        NSDictionary *album = response ? SAPParseAlbumMetadata(response, albumURI) : nil;
        if (completion) completion(album, album ? nil : (error ?: @"Album metadata was incomplete"));
    });
}
