#import "SGCanvas.h"
#import "Shared/Lyrics/Protobuf.h"

@implementation SGCanvas
@end

static SGCanvas *canvasWith(NSString *identifier, NSString *address, BOOL video) {
    if (!address.length) return nil;
    SGCanvas *canvas = [SGCanvas new];
    canvas.identifier = identifier.length ? identifier : @(address.hash).stringValue;
    canvas.address = address;
    canvas.video = video;
    return canvas;
}

SGCanvas *SGCanvasFromMetadata(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    NSString *address = metadata[@"canvas.url"];
    if (![address isKindOfClass:NSString.class]) return nil;
    NSString *type = [metadata[@"canvas.type"] isKindOfClass:NSString.class] ? metadata[@"canvas.type"] : nil;
    NSString *identifier = metadata[@"canvas.id"] ?: metadata[@"canvas.fileId"];
    return canvasWith([identifier isKindOfClass:NSString.class] ? identifier : nil, address,
                      [type hasPrefix:@"VIDEO"]);
}

// EntityCanvazRequest { repeated Entity entities = 1 { string entity_uri = 1; } }
NSData *SGCanvazRequestBody(NSString *trackURI) {
    if (!trackURI.length) return nil;
    NSData *entity = SGPBSerialize(@[SGPBString(1, trackURI)]);
    return SGPBSerialize(@[SGPBBytes(1, entity)]);
}

// EntityCanvazResponse { repeated Canvaz canvases = 1 { id = 1, url = 2, file_id = 3, type = 4 } }
SGCanvas *SGCanvazFromBody(NSData *body) {
    NSArray<SGPBField *> *fields = body.length ? SGPBParse(body) : nil;
    SGPBField *first = SGPBFirst(fields, 1);
    NSArray<SGPBField *> *canvaz = first.wire == 2 ? SGPBParse(first.payload) : nil;
    if (!canvaz) return nil;
    uint64_t type = SGPBFirst(canvaz, 4).varint;
    return canvasWith(SGPBText(SGPBFirst(canvaz, 1)) ?: SGPBText(SGPBFirst(canvaz, 3)),
                      SGPBText(SGPBFirst(canvaz, 2)), type >= 1 && type <= 3);
}
