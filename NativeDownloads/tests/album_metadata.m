#import <Foundation/Foundation.h>
#import "AlbumMetadata.h"
#import "WireProto.h"
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
static NSData *track(NSString *name, NSString *uri, unsigned number) {
    return join(@[textField(2,name), SAPProtoInteger(5,number), SAPProtoInteger(7,180000), textField(36,uri)]);
}
int main(void) {
    @autoreleasepool {
        NSString *albumURI = @"spotify:album:0123456789abcdefghijAB";
        NSString *firstURI = @"spotify:track:0123456789abcdefghijAC";
        NSString *secondURI = @"spotify:track:0123456789abcdefghijAD";
        NSData *disc1 = join(@[SAPProtoInteger(1,1), SAPProtoBytes(3,track(@"First",firstURI,1))]);
        NSData *disc2 = join(@[SAPProtoInteger(1,2), SAPProtoBytes(3,track(@"Second",secondURI,1))]);
        NSData *album = join(@[textField(2,@"Album"),SAPProtoBytes(11,disc1),SAPProtoBytes(11,disc2)]);
        NSData *response = SAPProtoBytes(1,SAPProtoBytes(3,album));
        NSDictionary *parsed = SAPParseAlbumMetadata(response,albumURI);
        assert([parsed[@"name"] isEqual:@"Album"]);
        NSArray *tracks = parsed[@"tracks"];
        assert(tracks.count == 2);
        assert([tracks[0][@"uri"] isEqual:firstURI]);
        assert([tracks[1][@"disc"] unsignedIntegerValue] == 2);
        assert([tracks[1][@"duration_ms"] unsignedIntegerValue] == 180000);
        assert(SAPParseAlbumMetadata(response,@"spotify:playlist:0123456789abcdefghijAB") == nil);
        NSData *badTrack = join(@[textField(2,@"Missing URI"),SAPProtoInteger(5,1),SAPProtoInteger(7,180000)]);
        NSData *badAlbum = join(@[textField(2,@"Album"),SAPProtoBytes(11,SAPProtoBytes(3,badTrack))]);
        assert(SAPParseAlbumMetadata(SAPProtoBytes(1,SAPProtoBytes(3,badAlbum)),albumURI) == nil);
    }
    return 0;
}
