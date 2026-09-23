// The protobuf wire format, just enough to walk into a message, change a few fields and write it
// back with everything else untouched. The lyrics read Spotify's replies through it.
#import <Foundation/Foundation.h>

// A field as it sits on the wire: a varint carries its value, everything else its raw payload.
@interface SGPBField : NSObject
@property (nonatomic) uint32_t number;
@property (nonatomic) uint8_t wire;   // 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32
@property (nonatomic) uint64_t varint;
@property (nonatomic, copy) NSData *payload;
@end

NSMutableArray<SGPBField *> *SGPBParse(NSData *data);   // nil when the bytes are not a message
NSData *SGPBSerialize(NSArray<SGPBField *> *fields);
SGPBField *SGPBFirst(NSArray<SGPBField *> *fields, uint32_t number);
SGPBField *SGPBVarint(uint32_t number, uint64_t value);
SGPBField *SGPBBytes(uint32_t number, NSData *payload);
SGPBField *SGPBString(uint32_t number, NSString *text);
NSString *SGPBText(SGPBField *field);   // the payload read as UTF-8, nil for any other field
// The message at `path` (field numbers, outermost first) handed to `edit`, whose result takes its
// place; nil when a field of the path is missing, the bytes do not parse or `edit` returns nil.
NSData *SGPBEdit(NSData *message, NSArray<NSNumber *> *path, NSData *(^edit)(NSData *inner));
