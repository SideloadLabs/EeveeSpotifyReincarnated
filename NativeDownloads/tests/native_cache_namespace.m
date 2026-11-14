#import <Foundation/Foundation.h>
#import "NativeCacheMap.h"
#import "ExportSites.h"
#include <assert.h>
#import "../src/Export/NativeCacheMap.m"

static NSDictionary *observed;
void SAPVaultObserveMapping(NSData *file, NSString *namespaceID) {}
void SAPExportCacheIndexObserve(NSData *file, NSDictionary *candidate) { observed = candidate; }
NSArray *SAPExportCacheIndexCandidates(NSData *file) { return @[]; }
BOOL SAPTraceIsActive(void) { return NO; }
uint64_t SAPTraceCurrentOperation(void) { return 0; }
void SAPTraceEvent(const char *category,const char *stage,uint64_t operation,NSDictionary *facts) {}

int main(void) { @autoreleasepool {
    // Independent Spotify 9.1.98 layout: a decoy at the old member must not be hashed.
    uint8_t owner[0x2cc] = {0}, descriptor[24] = {0};
    memset(owner+0x230,0xa5,20);
    for(unsigned i=0;i<20;i++){owner[0x2b8+i]=(uint8_t)(i+1);descriptor[i]=(uint8_t)i;}
    descriptor[20]=7;descriptor[22]=0x34;descriptor[23]=0x12;
    uint8_t *image=calloc(1,SAPExportCacheKeyBodyOffset+sizeof(SAPExportCacheKeyBody));
    assert(image);
    memcpy(image+SAPExportCacheKeyBodyOffset,SAPExportCacheKeyBody,sizeof(SAPExportCacheKeyBody));
    uint64_t frame[2]={(uintptr_t)owner,(uintptr_t)descriptor};
    SAPNativeCacheObserve(frame,(uintptr_t)image);
    assert([observed[@"cache_id_hex"] isEqual:@"70393e65aca204e6a06e14a88375a3acb972c8ab"]);
    assert([observed[@"namespace_id_hex"] isEqual:@"05670b9c09f7940648fbe79accb0051872b2bbea"]);
    observed=nil;image[SAPExportCacheKeyBodyOffset]^=1;
    SAPNativeCacheObserve(frame,(uintptr_t)image);assert(!observed);
    free(image);
    puts("PASS 9.1.98 namespace offset, independent digest, old-member decoy and guard rejection");
} return 0; }
