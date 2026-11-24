#import "CacheStorageKey.h"
#import "ExportKeyVault.h"
#import "CacheStorageLayout.h"
#import "ExportSites.h"
#import "DiagnosticTrace.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <os/lock.h>

enum { StorageKeyCapacity=16 };
static os_unfair_lock storageLock=OS_UNFAIR_LOCK_INIT;
static struct { uint8_t namespaceID[20],key[16]; } storageKeys[StorageKeyCapacity];
static unsigned storageCount,nextStorage;
static uint64_t captures,readFailures,guardFailures;
enum { MediaKey24Capacity=64 };
static struct { uint8_t key[24]; uint8_t context[64]; uint8_t contextLength; BOOL used; } mediaKeys24[MediaKey24Capacity];
static unsigned mediaKey24Count,nextMediaKey24;
static uint64_t mediaKey24Captures;
enum { MediaContextCapacity=64 };
static struct { uint8_t context[64]; uint8_t length; BOOL used; } mediaContexts[MediaContextCapacity];
static unsigned mediaContextCount,nextMediaContext;
static uint64_t mediaContextCaptures;
enum { MediaOutputCapacity=64 };
static struct { uint8_t bytes[32]; uint8_t length; BOOL used; } mediaOutputs[MediaOutputCapacity];
static unsigned mediaOutputCount,nextMediaOutput;
static uint64_t mediaOutputCaptures;
enum { MediaRecordCapacity=64 };
static struct { uint8_t file[20], value[36]; BOOL used; } mediaRecords[MediaRecordCapacity];
static unsigned mediaRecordCount,nextMediaRecord;
static uint64_t mediaRecordCaptures;

static BOOL readBytes(uintptr_t address,void *out,size_t size) {
    vm_size_t read=0;
    return address && address<=UINTPTR_MAX-size &&
        vm_read_overwrite(mach_task_self(),address,size,(vm_address_t)out,&read)==KERN_SUCCESS && read==size;
}
// Diagnostics only: discover native cipher callers outside the known storage
// constructor. Never read the supplied key bytes or serialize an object address.
static void observeCipherCaller(const uint64_t *registers,uintptr_t image) {
    if(!SAPTraceIsActive()||!registers||!image)return;
    uintptr_t caller=registers[30];
    if(caller<image || caller-image>0x10000000)return;
    unsigned length=(unsigned)registers[2];
    if(length!=16 && length!=24 && length!=32)return;
    if(caller-image==SAPCacheStorageOwnerReturnA || caller-image==SAPCacheStorageOwnerReturnB)return;
    static struct {uintptr_t caller;unsigned length;} seen[32];
    static unsigned count;static uint64_t generation;
    uint64_t current=SAPTraceGeneration();BOOL added=NO;
    os_unfair_lock_lock(&storageLock);
    if(generation!=current){memset(seen,0,sizeof(seen));count=0;generation=current;}
    BOOL duplicate=NO;
    for(unsigned i=0;i<count;i++)if(seen[i].caller==caller&&seen[i].length==length){duplicate=YES;break;}
    if(!duplicate && count<32){seen[count].caller=caller;seen[count++].length=length;added=YES;}
    os_unfair_lock_unlock(&storageLock);
    if(added && SAPTraceIsActive() && SAPTraceGeneration()==current)
        SAP_TRACE("export","native_cipher_setup_caller",0,@{
            @"caller_image_offset":[NSString stringWithFormat:@"0x%llx",(unsigned long long)(caller-image)],
            @"key_argument_bytes":@(length),@"key_pointer_present":@(registers[1]!=0),
            @"source":@"guarded native AES setter entry; caller outside known cache-storage constructor",
            @"track_association_proven":@NO,@"key_bytes_read":@NO,@"key_in_log":@NO,
            @"coverage":@"first 32 unique caller/length pairs per diagnostic generation; these two AES implementations only"});
}
void SAPObserveCacheStorageKey(const uint64_t *registers,uintptr_t image) {
    observeCipherCaller(registers,image);
    if(!registers || !image)return;
    uintptr_t caller=registers[30];
    if(registers[2]==24 && caller>=image && caller-image==SAPExportMediaContextOffset) {
        uint8_t key[24];
        if(!readBytes(registers[1],key,sizeof(key))) {
            memset_s(key,sizeof(key),0,sizeof(key));
            os_unfair_lock_lock(&storageLock);readFailures++;os_unfair_lock_unlock(&storageLock);
            return;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        uint8_t fingerprint[20];CC_SHA1(key,sizeof(key),fingerprint);
#pragma clang diagnostic pop
        os_unfair_lock_lock(&storageLock);
        BOOL duplicate=NO;
        for(unsigned i=0;i<mediaKey24Count;i++)if(mediaKeys24[i].used&&!memcmp(mediaKeys24[i].key,key,24)){duplicate=YES;break;}
        if(!duplicate) {
            unsigned slot=nextMediaKey24++%MediaKey24Capacity;
            memcpy(mediaKeys24[slot].key,key,24);memset(mediaKeys24[slot].context,0,64);mediaKeys24[slot].contextLength=0;mediaKeys24[slot].used=YES;
            if(mediaKey24Count<MediaKey24Capacity)mediaKey24Count++;
            mediaKey24Captures++;
        }
        os_unfair_lock_unlock(&storageLock);
        if(!duplicate&&SAPTraceIsActive()) {
            NSMutableString *hex=[NSMutableString string];
            for(unsigned i=0;i<8;i++)[hex appendFormat:@"%02x",fingerprint[i]];
            SAP_TRACE("export","media_key_24_observed",0,@{@"source":@"verified 24-byte media cipher setter caller",
                @"key_fingerprint":hex,@"key_in_log":@NO,@"key_bytes_read":@NO});
        }
        memset_s(key,sizeof(key),0,sizeof(key));
        memset_s(fingerprint,sizeof(fingerprint),0,sizeof(fingerprint));
        return;
    }
    if(registers[2]!=16)return;
    if(caller<image || (caller-image!=SAPCacheStorageOwnerReturnA && caller-image!=SAPCacheStorageOwnerReturnB))return;
    // Both call sites pass the same 20-byte SHA1 buffer to a 16-byte AES setter.
    uint8_t code[sizeof(SAPCacheStorageOwnerCode)];
    if(!readBytes(image+SAPCacheStorageOwnerOffset,code,sizeof(code)) ||
       memcmp(code,SAPCacheStorageOwnerCode,sizeof(code))) {
        os_unfair_lock_lock(&storageLock);guardFailures++;os_unfair_lock_unlock(&storageLock);return;
    }
    uint8_t source[20]={0},material[21]={1},namespaceBytes[20],identifier[20];
    if(!readBytes(registers[1],source,sizeof(source))) {
        memset_s(source,sizeof(source),0,sizeof(source));
        os_unfair_lock_lock(&storageLock);readFailures++;os_unfair_lock_unlock(&storageLock);return;
    }
    memcpy(material+1,source,20);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(material,sizeof(material),namespaceBytes);
    CC_SHA1(namespaceBytes,sizeof(namespaceBytes),identifier);
#pragma clang diagnostic pop
    os_unfair_lock_lock(&storageLock);
    unsigned slot=StorageKeyCapacity;
    for(unsigned i=0;i<storageCount;i++)if(!memcmp(storageKeys[i].namespaceID,identifier,20)){slot=i;break;}
    if(slot==StorageKeyCapacity) {
        slot=nextStorage++%StorageKeyCapacity;
        if(storageCount<StorageKeyCapacity)storageCount++;
    }
    BOOL changed=memcmp(storageKeys[slot].key,source,16)!=0||memcmp(storageKeys[slot].namespaceID,identifier,20)!=0;
    memcpy(storageKeys[slot].namespaceID,identifier,20);
    memcpy(storageKeys[slot].key,source,16);captures++;
    os_unfair_lock_unlock(&storageLock);
    if(changed){NSMutableString *space=[NSMutableString string];for(unsigned i=0;i<20;i++)[space appendFormat:@"%02x",identifier[i]];SAPVaultObserveStorage(space,[NSData dataWithBytes:source length:16]);}
    memset_s(source,sizeof(source),0,sizeof(source));
    memset_s(material,sizeof(material),0,sizeof(material));
    memset_s(namespaceBytes,sizeof(namespaceBytes),0,sizeof(namespaceBytes));
    memset_s(identifier,sizeof(identifier),0,sizeof(identifier));
    SAP_TRACE("export","cache_storage_context_observed",0,
        @{@"source":@"verified native cache-owner initializer",@"key_in_log":@NO,@"protected_persistence_enqueued":@(changed)});
}
BOOL SAPCopyCacheStorageKey(NSString *identifier,uint8_t output[16]) {
    if(![identifier isKindOfClass:NSString.class] || identifier.length!=40 || !output)return NO;
    uint8_t bytes[20];
    for(unsigned i=0;i<20;i++) {
        unsigned value=0;
        for(unsigned j=0;j<2;j++) {
            unichar c=[identifier characterAtIndex:i*2+j];
            if(c>='0' && c<='9')value=value*16+c-'0';
            else if(c>='a' && c<='f')value=value*16+c-'a'+10;
            else return NO;
        }
        bytes[i]=(uint8_t)value;
    }
    BOOL found=NO;os_unfair_lock_lock(&storageLock);
    for(unsigned i=0;i<storageCount;i++)if(!memcmp(storageKeys[i].namespaceID,bytes,20)) {
        memcpy(output,storageKeys[i].key,16);found=YES;break;
    }
    os_unfair_lock_unlock(&storageLock);return found;
}
static void readStringContext(uintptr_t object,uint8_t context[64],uint8_t *length) {
    *length=0;memset(context,0,64);
    if(!object)return;
    uint8_t flags=0;
    if(!readBytes(object+0x17,&flags,1))return;
    uintptr_t data=object;uint64_t size=(uint64_t)(flags&0x7f);
    if(flags&0x80) {
        uint64_t longSize=0;uintptr_t longData=0;
        if(!readBytes(object+8,&longSize,8)||!readBytes(object,&longData,8))return;
        size=longSize;data=longData;
    }
    if(size>64)size=64;
    if(size&&readBytes(data,context,(size_t)size))*length=(uint8_t)size;
}
void SAPObserveMediaContext(const uint64_t *registers,uintptr_t image) {
    if(!registers||!image)return;
    uint8_t context[64],length=0;
    readStringContext((uintptr_t)registers[21],context,&length);
    if(!length)return;
    os_unfair_lock_lock(&storageLock);
    BOOL duplicate=NO;
    for(unsigned i=0;i<mediaContextCount;i++)if(mediaContexts[i].used&&mediaContexts[i].length==length&&!memcmp(mediaContexts[i].context,context,length)){duplicate=YES;break;}
    if(!duplicate){unsigned slot=nextMediaContext++%MediaContextCapacity;memcpy(mediaContexts[slot].context,context,64);mediaContexts[slot].length=length;mediaContexts[slot].used=YES;if(mediaContextCount<MediaContextCapacity)mediaContextCount++;mediaContextCaptures++;}
    os_unfair_lock_unlock(&storageLock);
    if(!duplicate&&SAPTraceIsActive()) {
        NSString *text=[[NSString alloc]initWithBytes:context length:length encoding:NSUTF8StringEncoding];
        SAP_TRACE("export","media_context_observed",0,@{@"source":@"instruction after verified 24-byte media key setter",
            @"length":@(length),@"context":text?:NSNull.null,@"key_in_log":@NO});
    }
    memset_s(context,sizeof(context),0,sizeof(context));
}
NSUInteger SAPCopyRecentMediaContexts(uint8_t *contexts,uint8_t *lengths,size_t maximum) {
    if(!contexts||!lengths||!maximum)return 0;NSUInteger written=0;
    os_unfair_lock_lock(&storageLock);
    NSUInteger available=mediaContextCount<MediaContextCapacity?mediaContextCount:MediaContextCapacity;
    for(NSUInteger i=0;i<available&&written<maximum;i++){
        unsigned slot=(nextMediaContext+MediaContextCapacity-1-i)%MediaContextCapacity;
        if(!mediaContexts[slot].used)continue;
        memcpy(contexts+written*64,mediaContexts[slot].context,64);lengths[written]=mediaContexts[slot].length;written++;
    }
    os_unfair_lock_unlock(&storageLock);return written;
}
void SAPObserveMediaOutput(uintptr_t output) {
    if(!output)return;
    uint8_t bytes[32];
    if(!readBytes(output,bytes,sizeof(bytes)))return;
    os_unfair_lock_lock(&storageLock);
    BOOL duplicate=NO;
    for(unsigned i=0;i<mediaOutputCount;i++)if(mediaOutputs[i].used&&!memcmp(mediaOutputs[i].bytes,bytes,32)){duplicate=YES;break;}
    if(!duplicate){unsigned slot=nextMediaOutput++%MediaOutputCapacity;memcpy(mediaOutputs[slot].bytes,bytes,32);mediaOutputs[slot].length=32;mediaOutputs[slot].used=YES;if(mediaOutputCount<MediaOutputCapacity)mediaOutputCount++;mediaOutputCaptures++;}
    os_unfair_lock_unlock(&storageLock);
    if(!duplicate&&SAPTraceIsActive()) {
        SAP_TRACE("export","media_output_observed",0,@{@"source":@"unverified legacy output; not a proven media IV",
            @"output_length":@32,@"key_in_log":@NO});
    }
    memset_s(bytes,sizeof(bytes),0,sizeof(bytes));
}
void SAPObserveMediaRecord(const uint64_t *registers,uintptr_t image) {
    if(!registers||!image)return;
    uintptr_t vector=(uintptr_t)registers[21];
    uintptr_t fileID=(uintptr_t)registers[20];
    uint64_t offset=registers[22];
    uintptr_t begin=0;
    if(!vector||!fileID||offset>0x100000)return;
    if(!readBytes(vector,&begin,sizeof(begin))||!begin)return;
    uint8_t file[20],value[36];
    if(!readBytes(fileID,file,sizeof(file))||!readBytes(begin+(uintptr_t)offset,value,sizeof(value)))return;
    os_unfair_lock_lock(&storageLock);
    unsigned slot=MediaRecordCapacity;
    for(unsigned i=0;i<mediaRecordCount;i++)if(mediaRecords[i].used&&!memcmp(mediaRecords[i].file,file,20)&&!memcmp(mediaRecords[i].value,value,36)){slot=i;break;}
    BOOL added=NO;
    if(slot==MediaRecordCapacity){slot=nextMediaRecord++%MediaRecordCapacity;if(mediaRecordCount<MediaRecordCapacity)mediaRecordCount++;added=YES;}
    memcpy(mediaRecords[slot].file,file,20);memcpy(mediaRecords[slot].value,value,36);mediaRecords[slot].used=YES;
    if(added)mediaRecordCaptures++;
    os_unfair_lock_unlock(&storageLock);
    if(added&&SAPTraceIsActive()) {
        NSMutableString *id=[NSMutableString string];
        for(unsigned i=0;i<8;i++)[id appendFormat:@"%02x",file[i]];
        SAP_TRACE("export","media_record_observed",0,@{@"source":@"native media key-setter tail record",@"file_fingerprint":id,
            @"record_layout_verified":@NO,@"record_length":@(36),@"key_in_log":@NO});
    }
    memset_s(file,sizeof(file),0,sizeof(file));
    memset_s(value,sizeof(value),0,sizeof(value));
}
NSUInteger SAPCopyRecentMediaRecords(uint8_t *records,size_t maximum) {
    if(!records||!maximum)return 0;NSUInteger written=0;
    os_unfair_lock_lock(&storageLock);
    NSUInteger available=mediaRecordCount<MediaRecordCapacity?mediaRecordCount:MediaRecordCapacity;
    for(NSUInteger i=0;i<available&&written<maximum;i++){
        unsigned slot=(nextMediaRecord+MediaRecordCapacity-1-i)%MediaRecordCapacity;
        if(!mediaRecords[slot].used)continue;
        memcpy(records+written*56,mediaRecords[slot].file,20);
        memcpy(records+written*56+20,mediaRecords[slot].value,36);
        written++;
    }
    os_unfair_lock_unlock(&storageLock);return written;
}
NSUInteger SAPCopyRecentMediaOutputs(uint8_t *outputs,uint8_t *lengths,size_t maximum) {
    if(!outputs||!lengths||!maximum)return 0;NSUInteger written=0;
    os_unfair_lock_lock(&storageLock);
    NSUInteger available=mediaOutputCount<MediaOutputCapacity?mediaOutputCount:MediaOutputCapacity;
    for(NSUInteger i=0;i<available&&written<maximum;i++){
        unsigned slot=(nextMediaOutput+MediaOutputCapacity-1-i)%MediaOutputCapacity;
        if(!mediaOutputs[slot].used)continue;
        memcpy(outputs+written*32,mediaOutputs[slot].bytes,32);lengths[written]=mediaOutputs[slot].length;written++;
    }
    os_unfair_lock_unlock(&storageLock);return written;
}
NSDictionary *SAPCacheStorageKeyReport(void) {
    os_unfair_lock_lock(&storageLock);
    NSDictionary *result=@{@"contexts":@(storageCount),@"captures":@(captures),
        @"read_failures":@(readFailures),@"guard_failures":@(guardFailures),
        @"capacity":@(StorageKeyCapacity),@"media_keys_24":@(mediaKey24Count),
        @"media_key_24_captures":@(mediaKey24Captures),@"media_contexts":@(mediaContextCount),@"media_context_captures":@(mediaContextCaptures),@"media_outputs":@(mediaOutputCount),@"media_output_captures":@(mediaOutputCaptures),@"media_records":@(mediaRecordCount),@"media_record_captures":@(mediaRecordCaptures),@"protected_persistence":@"device-only Keychain, status in export key_vault",@"research_disk_dump_enabled":@NO,@"key_material_logged":@NO};
    os_unfair_lock_unlock(&storageLock);return result;
}
NSUInteger SAPMediaKey24Count(void) {
    os_unfair_lock_lock(&storageLock);NSUInteger count=mediaKey24Count;os_unfair_lock_unlock(&storageLock);return count;
}
NSUInteger SAPCopyRecentMediaKeys24(uint8_t *keys,uint8_t *contexts,uint8_t *contextLengths,size_t maximum) {
    if(!keys||!contexts||!contextLengths||!maximum)return 0;NSUInteger written=0;
    os_unfair_lock_lock(&storageLock);
    NSUInteger available=mediaKey24Count<MediaKey24Capacity?mediaKey24Count:MediaKey24Capacity;
    for(NSUInteger i=0;i<available&&written<maximum;i++) {
        unsigned slot=(nextMediaKey24+MediaKey24Capacity-1-i)%MediaKey24Capacity;
        if(!mediaKeys24[slot].used)continue;
        memcpy(keys+written*24,mediaKeys24[slot].key,24);
        memcpy(contexts+written*64,mediaKeys24[slot].context,64);
        contextLengths[written]=mediaKeys24[slot].contextLength;written++;
    }
    os_unfair_lock_unlock(&storageLock);return written;
}
BOOL SAPCopyMediaKey24(NSUInteger index,uint8_t output[24]) {
    if(!output)return NO;BOOL found=NO;
    os_unfair_lock_lock(&storageLock);
    if(index<mediaKey24Count && mediaKeys24[index].used){memcpy(output,mediaKeys24[index].key,24);found=YES;}
    os_unfair_lock_unlock(&storageLock);return found;
}

#ifdef SAP_TESTING
void SAPCacheStorageResetForTesting(void) {
    os_unfair_lock_lock(&storageLock);memset_s(storageKeys,sizeof(storageKeys),0,sizeof(storageKeys));storageCount=nextStorage=0;os_unfair_lock_unlock(&storageLock);
}
#endif
