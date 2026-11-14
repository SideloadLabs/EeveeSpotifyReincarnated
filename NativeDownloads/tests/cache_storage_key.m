#import <Foundation/Foundation.h>
#import "../src/Export/CacheStorageKey.h"
#import "../src/Generated/CacheStorageLayout.h"
#import "../src/Generated/ExportSites.h"
#import "../src/Public/DiagnosticTrace.h"

BOOL SAPTraceIsActive(void){return NO;}
SAPTraceID SAPTraceCurrentOperation(void){return 0;}
uint64_t SAPTraceGeneration(void){return 1;}
void SAPTraceEvent(const char *a,const char *b,SAPTraceID c,NSDictionary *d){abort();}

int main(void){@autoreleasepool {
    uint8_t *image=calloc(1,SAPCacheStorageOwnerOffset+0x200);assert(image);
    memcpy(image+SAPCacheStorageOwnerOffset,SAPCacheStorageOwnerCode,sizeof(SAPCacheStorageOwnerCode));
    uint8_t source[20],copy[16];for(unsigned i=0;i<20;i++)source[i]=(uint8_t)(i+1);
    NSString *identifier=@"196ec80efd83eaa5eaa1e91b63aad79ec37d87b8";
    uint64_t frame[31]={0};frame[1]=(uintptr_t)source;frame[2]=16;
    frame[30]=(uintptr_t)image+SAPCacheStorageOwnerReturnA;
    SAPObserveCacheStorageKey(frame,(uintptr_t)image);
    assert(SAPCopyCacheStorageKey(identifier,copy) && !memcmp(copy,source,16));
    assert(!SAPCopyCacheStorageKey(@"invalid",copy));
    assert(!SAPCopyCacheStorageKey(@"196ec80efd83eaa5eaa1e91b63aad79ec37d87b9",copy));
    assert(!SAPCopyCacheStorageKey(nil,copy));
    assert(!SAPCopyCacheStorageKey(identifier,NULL));
    frame[30]++;source[0]++;
    SAPObserveCacheStorageKey(frame,(uintptr_t)image);
    assert([SAPCacheStorageKeyReport()[@"captures"]unsignedIntValue]==1);
    frame[30]--;image[SAPCacheStorageOwnerOffset]^=1;
    SAPObserveCacheStorageKey(frame,(uintptr_t)image);
    assert([SAPCacheStorageKeyReport()[@"guard_failures"]unsignedIntValue]==1);
    assert(SAPCopyCacheStorageKey(identifier,copy) && copy[0]==1);
    // A native mid-function snapshot is indexed by the actual register number.
    // Deliberately poison the historical vector slots: they must not be read.
    uint8_t fileID[20],record[36],records[56];
    for(unsigned i=0;i<20;i++)fileID[i]=(uint8_t)(80+i);
    for(unsigned i=0;i<36;i++)record[i]=(uint8_t)(100+i);
    uintptr_t vector=(uintptr_t)record;
    memset(frame,0,sizeof(frame));frame[20]=(uintptr_t)fileID;
    frame[21]=(uintptr_t)&vector;frame[22]=0;frame[23]=0x12345678;
    SAPObserveMediaRecord(frame,(uintptr_t)image);
    assert(SAPCopyRecentMediaRecords(records,1)==1);
    assert(!memcmp(records,fileID,20)&&!memcmp(records+20,record,36));
    uint8_t context[24]={0};memcpy(context,"test context",12);context[23]=12;
    frame[21]=(uintptr_t)context;frame[22]=0x12345678;
    SAPObserveMediaContext(frame,(uintptr_t)image);
    uint8_t contexts[64],lengths[1];
    assert(SAPCopyRecentMediaContexts(contexts,lengths,1)==1);
    assert(lengths[0]==12&&!memcmp(contexts,context,12));
    // Invalid native addresses are rejected without a crash or a trace event.
    frame[21]=1;SAPObserveMediaContext(frame,(uintptr_t)image);
    SAPObserveMediaRecord(frame,(uintptr_t)image);
    free(image);
    puts("PASS: exact namespace association, caller/code guards, invalid identifiers, Diagnostics off");
}}
