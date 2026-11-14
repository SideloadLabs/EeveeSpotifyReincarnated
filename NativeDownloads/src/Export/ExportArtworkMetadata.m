#import "ExportArtwork.h"
#import "WireProto.h"
#import <objc/runtime.h>
NSString *SAPExportAlbumCoverURI(NSArray *album) {
    NSMutableArray *candidates=[NSMutableArray array];
    for(NSDictionary *field in album) {
        if([field[@"wire"]unsignedIntValue]!=2)continue;
        unsigned number=[field[@"number"]unsignedIntValue];
        if(number==9)[candidates addObject:field[@"value"]];
        else if(number==17)for(NSDictionary *image in SAPProtoFields(field[@"value"]))
            if([image[@"number"]unsignedIntValue]==1 && [image[@"wire"]unsignedIntValue]==2)[candidates addObject:image[@"value"]];
    }
    NSString *fallback=nil;
    for(NSData *candidate in candidates) {
        NSArray *image=SAPProtoFields(candidate);NSData *file=SAPProtoData(image,1);if(file.length!=20)continue;
        NSMutableString *uri=[NSMutableString stringWithString:@"spotify:image:"];const uint8_t *bytes=file.bytes;
        for(NSUInteger i=0;i<20;i++)[uri appendFormat:@"%02x",bytes[i]];
        if(SAPProtoNumber(image,2,0)==0)return uri;if(!fallback)fallback=uri;
    }
    return fallback;
}
NSString *SAPExportAlbumURI(NSArray *album) {
    NSData *gid=SAPProtoData(album,1);if(gid.length!=16)return nil;
    static const char alphabet[]="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    unsigned digits[22]={0};const uint8_t *bytes=gid.bytes;
    for(unsigned i=0;i<16;i++){unsigned carry=bytes[i];for(int j=21;j>=0;j--){carry+=digits[j]*256;digits[j]=carry%62;carry/=62;}if(carry)return nil;}
    char identifier[22];for(unsigned i=0;i<22;i++)identifier[i]=alphabet[digits[i]];
    return [@"spotify:album:" stringByAppendingString:[[NSString alloc]initWithBytes:identifier length:22 encoding:NSASCIIStringEncoding]];
}

static char SAPExportFileArtworkKey;
void SAPAttachExportArtwork(NSURL *file,NSDictionary *artwork) {
    if(file)objc_setAssociatedObject(file,&SAPExportFileArtworkKey,artwork,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
NSDictionary *SAPAttachedExportArtwork(NSURL *file) {
    return file?objc_getAssociatedObject(file,&SAPExportFileArtworkKey):nil;
}

NSString *SAPExportArtistName(NSArray *fields,unsigned number) {
    for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==number&&[field[@"wire"]unsignedIntValue]==2) {
        NSString *name=SAPProtoString(SAPProtoFields(field[@"value"]),2);if(name.length)return name;
    }
    return nil;
}
