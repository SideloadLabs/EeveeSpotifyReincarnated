#import "NativeCacheMap.h"
#import "ExportKeyVault.h"
#import "ExportCacheIndex.h"
#import "ExportSites.h"
#import "DiagnosticTrace.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <os/lock.h>
#include <string.h>

enum { SAPCacheMapCapacity=4096 };
typedef struct {
    uint8_t fileID[20],cacheID[20],namespaceID[20],kind;
    uint16_t index;
} SAPCacheMapping;
static SAPCacheMapping mappings[SAPCacheMapCapacity];
static os_unfair_lock mappingLock=OS_UNFAIR_LOCK_INIT;
static unsigned mappingCount,nextMapping;
static uint64_t observations,duplicates,evictions,readFailures,guardFailures;
static BOOL guardVerified;
static void clearMemory(void *pointer,size_t length) {
    volatile uint8_t *bytes=pointer;while(length--)*bytes++=0;
}

static BOOL readMemory(uintptr_t pointer,void *out,size_t count) {
    if(!pointer||pointer>UINTPTR_MAX-count)return NO;
    vm_size_t copied=0;
    return vm_read_overwrite(mach_task_self(),pointer,count,(vm_address_t)out,&copied)==KERN_SUCCESS&&copied==count;
}
static NSString *hex20(const uint8_t *bytes) {
    char out[41];static const char chars[]="0123456789abcdef";
    for(unsigned i=0;i<20;i++){out[2*i]=chars[bytes[i]>>4];out[2*i+1]=chars[bytes[i]&15];}out[40]=0;
    return [NSString stringWithUTF8String:out];
}
void SAPNativeCacheObserve(const uint64_t *registers,uintptr_t imageBase) {
    // The entry itself is patched. Verify the next untouched native instructions.
    uint8_t code[sizeof(SAPExportCacheKeyBody)];
    if(!registers||!imageBase||imageBase>UINTPTR_MAX-SAPExportCacheKeyBodyOffset||
       !readMemory(imageBase+SAPExportCacheKeyBodyOffset,code,sizeof(code))||memcmp(code,SAPExportCacheKeyBody,sizeof(code))) {
        os_unfair_lock_lock(&mappingLock);guardFailures++;os_unfair_lock_unlock(&mappingLock);return;
    }
    uint8_t material[44]={0},descriptor[24]={0};
    uintptr_t owner=(uintptr_t)registers[0];
    if(owner>UINTPTR_MAX-SAPExportCacheNamespaceOffset||!readMemory(owner+SAPExportCacheNamespaceOffset,material,20)||
       !readMemory((uintptr_t)registers[1],descriptor,sizeof(descriptor))) {
        clearMemory(material,sizeof(material));clearMemory(descriptor,sizeof(descriptor));
        os_unfair_lock_lock(&mappingLock);guardVerified=YES;readFailures++;os_unfair_lock_unlock(&mappingLock);return;
    }
    SAPCacheMapping entry={0};memcpy(entry.fileID,descriptor,20);
    entry.kind=descriptor[20];entry.index=(uint16_t)(descriptor[22]|((uint16_t)descriptor[23]<<8));
    memcpy(material+20,descriptor,21);material[41]=0;memcpy(material+42,descriptor+22,2);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(material,sizeof(material),entry.cacheID);
    CC_SHA1(material,20,entry.namespaceID);
#pragma clang diagnostic pop
    clearMemory(material,sizeof(material));clearMemory(descriptor,sizeof(descriptor));
    BOOL added=YES;
    os_unfair_lock_lock(&mappingLock);guardVerified=YES;observations++;
    for(unsigned i=0;i<mappingCount;i++) {
        SAPCacheMapping *prior=&mappings[i];
        if(prior->kind==entry.kind&&prior->index==entry.index&&
           !memcmp(prior->fileID,entry.fileID,20)&&!memcmp(prior->cacheID,entry.cacheID,20)&&
           !memcmp(prior->namespaceID,entry.namespaceID,20)){duplicates++;added=NO;break;}
    }
    if(added){if(mappingCount==SAPCacheMapCapacity)evictions++;else mappingCount++;
        mappings[nextMapping]=entry;nextMapping=(nextMapping+1)%SAPCacheMapCapacity;}
    os_unfair_lock_unlock(&mappingLock);
    if(added)SAPVaultObserveMapping([NSData dataWithBytes:entry.fileID length:20],hex20(entry.namespaceID));
    if(added)SAPExportCacheIndexObserve([NSData dataWithBytes:entry.fileID length:20],@{@"cache_id_hex":hex20(entry.cacheID),@"namespace_id_hex":hex20(entry.namespaceID),@"descriptor_kind":@(entry.kind),@"index":@(entry.index)});
    if(added&&SAPTraceIsActive())SAP_TRACE("native_cache","file_cache_link",SAPTraceCurrentOperation(),
        @{@"file_identifier":hex20(entry.fileID),@"cache_id_hex":hex20(entry.cacheID),
          @"descriptor_kind":@(entry.kind),@"descriptor_index":@(entry.index),
          @"source":@"verified native cache descriptor hash entry",@"key_material_read":@NO});
    clearMemory(&entry,sizeof(entry));
}
NSArray<NSDictionary *> *SAPNativeCacheCandidates(NSData *fileID) {
    if(![fileID isKindOfClass:NSData.class]||fileID.length!=20)return @[];
    uint8_t identifier[20];memcpy(identifier,fileID.bytes,20);
    NSMutableArray *result=[NSMutableArray array];os_unfair_lock_lock(&mappingLock);
    for(unsigned i=0;i<mappingCount;i++)if(!memcmp(identifier,mappings[i].fileID,20)) {
        SAPCacheMapping *entry=&mappings[i];
        [result addObject:@{@"cache_id_hex":hex20(entry->cacheID),@"descriptor_kind":@(entry->kind),
            @"index":@(entry->index),@"namespace_id_hex":hex20(entry->namespaceID)}];
    }
    os_unfair_lock_unlock(&mappingLock);
    // Only explicit export calls this lookup. Observers never read SQLite.
    for(NSDictionary *candidate in SAPExportCacheIndexCandidates(fileID))if(![result containsObject:candidate])[result addObject:candidate];
    return result;
}
NSDictionary *SAPNativeCacheMapReport(void) {
    os_unfair_lock_lock(&mappingLock);
    NSDictionary *report=@{@"status":observations?@"observing":@"awaiting_native_read",@"body_guard_verified":@(guardVerified),
        @"capacity":@(SAPCacheMapCapacity),@"entries":@(mappingCount),@"observations":@(observations),
        @"duplicate_observations":@(duplicates),@"ring_evictions":@(evictions),@"read_failures":@(readFailures),
        @"body_guard_failures":@(guardFailures),@"persistent_storage":@NO};
    os_unfair_lock_unlock(&mappingLock);return report;
}
#ifdef SAP_TESTING
void SAPNativeCacheMapResetForTesting(void) {
    os_unfair_lock_lock(&mappingLock);clearMemory(mappings,sizeof(mappings));mappingCount=nextMapping=0;
    observations=duplicates=evictions=readFailures=guardFailures=0;guardVerified=NO;os_unfair_lock_unlock(&mappingLock);
}
#endif
