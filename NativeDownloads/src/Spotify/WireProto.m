#import "WireProto.h"

static BOOL readInteger(const uint8_t *bytes, NSUInteger size, NSUInteger *at, uint64_t *out) {
    uint64_t value = 0;
    for (unsigned i = 0; i < 10; i++) {
        if (*at >= size) return NO;
        uint8_t byte = bytes[(*at)++];
        if (i == 9 && byte > 1) return NO;
        value |= (uint64_t)(byte & 127) << (i * 7);
        if (!(byte & 128)) { *out = value; return YES; }
    }
    return NO;
}
static void appendInteger(NSMutableData *data, uint64_t value) {
    do { uint8_t byte = value & 127; value >>= 7; if (value) byte |= 128; [data appendBytes:&byte length:1]; } while (value);
}
NSArray<NSDictionary *> *SAPProtoFields(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length > 4 * 1024 * 1024) return nil;
    const uint8_t *bytes = data.bytes;
    NSUInteger at = 0;
    NSMutableArray *fields = [NSMutableArray array];
    while (at < data.length) {
        if (fields.count >= 131072) return nil;
        NSUInteger start = at; uint64_t tag, value;
        if (!readInteger(bytes, data.length, &at, &tag) || (tag >> 3) == 0 || (tag >> 3) > 0x1fffffff) return nil;
        unsigned wire = tag & 7;
        id payload;
        if (wire == 0) {
            if (!readInteger(bytes, data.length, &at, &value)) return nil;
            payload = @(value);
        } else {
            if (wire == 1) value = 8;
            else if (wire == 5) value = 4;
            else if (wire == 2) { if (!readInteger(bytes, data.length, &at, &value)) return nil; }
            else return nil; // Deprecated groups: preserve the complete input unchanged at caller.
            if (value > data.length - at) return nil;
            payload = [data subdataWithRange:NSMakeRange(at, (NSUInteger)value)];
            at += (NSUInteger)value;
        }
        [fields addObject:@{@"number": @(tag >> 3), @"wire": @(wire), @"value": payload,
            @"raw": [data subdataWithRange:NSMakeRange(start, at - start)]}];
    }
    return fields;
}
NSData *SAPProtoBytes(unsigned number, NSData *value) {
    NSMutableData *data = [NSMutableData data];
    appendInteger(data, ((uint64_t)number << 3) | 2); appendInteger(data, value.length); [data appendData:value]; return data;
}
NSData *SAPProtoInteger(unsigned number, uint64_t value) {
    NSMutableData *data = [NSMutableData data]; appendInteger(data, (uint64_t)number << 3); appendInteger(data, value); return data;
}
uint64_t SAPProtoNumber(NSArray<NSDictionary *> *fields, unsigned number, uint64_t fallback) {
    for (NSDictionary *field in fields.reverseObjectEnumerator)
        if ([field[@"number"] unsignedIntValue] == number && [field[@"wire"] unsignedIntValue] == 0) return [field[@"value"] unsignedLongLongValue];
    return fallback;
}
NSData *SAPProtoData(NSArray<NSDictionary *> *fields, unsigned number) {
    for (NSDictionary *field in fields.reverseObjectEnumerator)
        if ([field[@"number"] unsignedIntValue] == number && [field[@"wire"] unsignedIntValue] == 2) return field[@"value"];
    return nil;
}
NSString *SAPProtoString(NSArray<NSDictionary *> *fields, unsigned number) {
    NSData *data = SAPProtoData(fields, number);
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

int64_t SAPProtoSInt(NSArray<NSDictionary *> *fields, unsigned number, int64_t fallback) {
    for (NSDictionary *field in fields.reverseObjectEnumerator) {
        if ([field[@"number"] unsignedIntValue] != number || [field[@"wire"] unsignedIntValue] != 0) continue;
        uint64_t raw = [field[@"value"] unsignedLongLongValue];
        // Protobuf zigzag: (n << 1) ^ (n >> 31) for positive n is 2n.
        return (int64_t)(raw >> 1) ^ -(int64_t)(raw & 1);
    }
    return fallback;
}
