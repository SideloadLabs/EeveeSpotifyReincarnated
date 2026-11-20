#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <string.h>
#import "include/Tweak.h"

static BOOL verifyRegistration(const struct mach_header_64 *image, NSData *uuid, uint64_t gateOffset, NSData *gate,
                               uint64_t skipOffset, NSData *skip) {
    if(!image || image->magic!=MH_MAGIC_64 || image->cputype!=CPU_TYPE_ARM64 || image->sizeofcmds>1048576)return NO;
    const uint8_t *cursor=(const uint8_t *)(image+1), *end=cursor+image->sizeofcmds;
    BOOL uuidMatches=NO;
    uint64_t textSize=0;
    for(uint32_t i=0;i<image->ncmds;i++) {
        if(end-cursor<sizeof(struct load_command))return NO;
        const struct load_command *command=(const void *)cursor;
        if(command->cmdsize<sizeof(*command) || command->cmdsize>end-cursor)return NO;
        if(command->cmd==LC_UUID && command->cmdsize>=sizeof(struct uuid_command)) {
            const struct uuid_command *identity=(const void *)cursor;
            uuidMatches=!memcmp(identity->uuid,uuid.bytes,16);
        } else if(command->cmd==LC_SEGMENT_64 && command->cmdsize>=sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment=(const void *)cursor;
            if(!strncmp(segment->segname,"__TEXT",sizeof(segment->segname)) && !segment->fileoff && (segment->initprot&5)==5)
                textSize=MIN(segment->filesize,segment->vmsize);
        }
        cursor+=command->cmdsize;
    }
    if(!uuidMatches || cursor!=end || textSize<gate.length || textSize<skip.length ||
       gateOffset>textSize-gate.length || skipOffset>textSize-skip.length)return NO;

    const uint8_t *code=(const void *)image;
    return !memcmp(code+gateOffset,gate.bytes,gate.length) && !memcmp(code+skipOffset,skip.bytes,skip.length);
}

BOOL EeveeNativeLyricsIsolatedFromAudio(void) {
    id value=[NSBundle.mainBundle objectForInfoDictionaryKey:@"EeveeOfflineLyricsRegistration"];
    if(![value isKindOfClass:NSDictionary.class])return NO;
    NSDictionary *proof=value;
    NSData *uuid=proof[@"UUID"], *gate=proof[@"GateBytes"], *skip=proof[@"SkipBytes"];
    NSNumber *gatePosition=proof[@"GateOffset"], *skipPosition=proof[@"SkipOffset"];
    if(![uuid isKindOfClass:NSData.class] || uuid.length!=16 || ![gate isKindOfClass:NSData.class] || gate.length!=12 ||
       ![skip isKindOfClass:NSData.class] || skip.length!=28 || ![gatePosition isKindOfClass:NSNumber.class] ||
       ![skipPosition isKindOfClass:NSNumber.class])return NO;
    uint64_t gateOffset=gatePosition.unsignedLongLongValue, skipOffset=skipPosition.unsignedLongLongValue;
    uint32_t words[3];
    [gate getBytes:words length:sizeof(words)];
    uint32_t distance=(words[2]&0x3ffffff)*4;
    if(words[0]!=0x38686a88 || words[1]!=0x7100051f || (words[2]&0xfc000000)!=0x14000000 ||
       distance<0x80 || distance>0x500 || skipOffset<=gateOffset || skipOffset-gateOffset!=8+distance || gateOffset%4)return NO;

    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char *path=_dyld_get_image_name(i);
        if(!path || strcmp(strrchr(path,'/')?strrchr(path,'/')+1:path,"Spotify"))continue;
        const struct mach_header_64 *image=(const void *)_dyld_get_image_header(i);
        if(verifyRegistration(image,uuid,gateOffset,gate,skipOffset,skip))return YES;
    }
    return NO;
}
