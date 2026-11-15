#import "ExportObservation.h"
#import "ExportRegisterFrame.h"
#import "ExportObservationV2Patch.h"
#import "ExportMediaUnsealPatch.h"
#import "TargetProfile.h"
#import "DiagnosticTrace.h"
extern void SAPObserveMediaKeyPath(const uint64_t *,uintptr_t);
extern void SAPObserveMediaRecord(const uint64_t *,uintptr_t);
extern void SAPObserveAesCtr(const uint64_t *,uintptr_t);
extern void SAPObserveAesBlock(const uint64_t *,uintptr_t);
#import "NativeCacheMap.h"
#import "TrackExport.h"
#import "CacheStorageKey.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#include <stdatomic.h>
static atomic_uintptr_t verifiedImage;
static atomic_uint_fast64_t cacheBoundaries,streamBoundaries,blobBoundaries,recordBoundaries;
static BOOL readBytes(uintptr_t p,void *out,size_t size){vm_size_t copied=0;return p&&vm_read_overwrite(mach_task_self(),p,size,(vm_address_t)out,&copied)==KERN_SUCCESS&&copied==size;}
static BOOL supported(uintptr_t image) {
    if(image&&image==atomic_load(&verifiedImage))return YES;
    static const uint8_t uuid[]=SAP_SPOTIFY_UUID_BYTES;
    struct mach_header_64 h;if(!readBytes(image,&h,sizeof(h))||h.magic!=MH_MAGIC_64||h.ncmds>1024||h.sizeofcmds>1048576)return NO;
    uintptr_t cursor=image+sizeof(h),end=cursor+h.sizeofcmds;
    for(unsigned i=0;i<h.ncmds;i++){struct load_command c;if(cursor>end||end-cursor<sizeof(c)||!readBytes(cursor,&c,sizeof(c))||c.cmdsize<sizeof(c)||c.cmdsize>end-cursor)return NO;
        if(c.cmd==LC_UUID){struct uuid_command u;if(c.cmdsize<sizeof(u)||!readBytes(cursor,&u,sizeof(u))||memcmp(u.uuid,uuid,16))return NO;atomic_store(&verifiedImage,image);return YES;}cursor+=c.cmdsize;}
    return NO;
}
static void dispatchBoundary(unsigned kind,const uint64_t *registers,uintptr_t image) {
    if((kind>7&&kind!=10)||!registers||!supported(image))return;
    @autoreleasepool {@try {
        if(kind==0){atomic_fetch_add(&cacheBoundaries,1);SAPNativeCacheObserve(registers,image);}
        else if(kind==1){atomic_fetch_add(&streamBoundaries,1);SAPExportObserveStreamSuccess(registers,image);}
        else if(kind<4)SAPObserveCacheStorageKey(registers,image);
        else if(kind==4)SAPObserveMediaKeyPath(registers,image);
        else if(kind==5){atomic_fetch_add(&blobBoundaries,1);SAPExportObserveMediaKeyBlob(registers,image);}
        else if(kind==6)SAPObserveMediaContext(registers,image);
        else if(kind==7){atomic_fetch_add(&recordBoundaries,1);SAPObserveMediaRecord(registers,image);}
        else if(kind==10)SAPExportObserveUnsealedMediaKey((const SAPExportRegisterFrame *)registers,image);
    }@catch(__unused NSException *exception){/* Observation must not change native execution. */}}
}
__attribute__((visibility("default"))) void SAPObserveExportBoundaryV2(unsigned kind,const SAPExportRegisterFrame *frame) {
    Dl_info info={0};
    if(!frame||!dladdr(__builtin_return_address(0),&info))return;
    dispatchBoundary(kind,frame->x,(uintptr_t)info.dli_fbase);
}
// Compatibility with historical entry thunks only. Mid-function probes with
// missing callee-saved registers are deliberately rejected.
__attribute__((visibility("default"))) void SAPObserveExportBoundary(unsigned kind,const uint64_t *legacy) {
    Dl_info info={0};
    if(!legacy||kind>=6||!dladdr(__builtin_return_address(0),&info))return;
    SAPExportRegisterFrame frame={0};
    memcpy(frame.x,legacy,19*sizeof(uint64_t));frame.x[30]=legacy[19];
    dispatchBoundary(kind,frame.x,(uintptr_t)info.dli_fbase);
}
static BOOL installed(uintptr_t base,uintptr_t offset,const uint8_t *head,size_t headSize,uintptr_t cave,const uint8_t *code,size_t codeSize) {
    uint8_t bytes[512];return base&&headSize<=sizeof(bytes)&&codeSize<=sizeof(bytes)&&readBytes(base+offset,bytes,headSize)&&!memcmp(bytes,head,headSize)&&readBytes(base+cave,bytes,codeSize)&&!memcmp(bytes,code,codeSize);
}
NSDictionary *SAPExportObservationReport(void) {
    uintptr_t base=atomic_load(&verifiedImage);
    return @{@"cache_boundary_calls":@(atomic_load(&cacheBoundaries)),@"stream_success_boundary_calls":@(atomic_load(&streamBoundaries)),@"media_key_blob_boundary_calls":@(atomic_load(&blobBoundaries)),@"media_record_boundary_calls":@(atomic_load(&recordBoundaries)),
        @"cache_boundary_verified_after_first_call":@(installed(base,SAPExportV2CacheKeyOffset,SAPExportV2CacheKeyHead,sizeof(SAPExportV2CacheKeyHead),SAPExportV2CacheKeyCaveOffset,SAPExportV2CacheKeyCode,sizeof(SAPExportV2CacheKeyCode))),
        @"stream_boundary_verified_after_first_call":@(installed(base,SAPExportV2StreamKeyOffset,SAPExportV2StreamKeyHead,sizeof(SAPExportV2StreamKeyHead),SAPExportV2StreamKeyCaveOffset,SAPExportV2StreamKeyCode,sizeof(SAPExportV2StreamKeyCode))),
        @"cache_cipher_boundary_installed":@(installed(base,SAPExportV2CacheCipherOffset,SAPExportV2CacheCipherHead,sizeof(SAPExportV2CacheCipherHead),SAPExportV2CacheCipherCaveOffset,SAPExportV2CacheCipherCode,sizeof(SAPExportV2CacheCipherCode))),
        @"cache_cipher_apple_boundary_installed":@(installed(base,SAPExportV2CacheCipherAppleOffset,SAPExportV2CacheCipherAppleHead,sizeof(SAPExportV2CacheCipherAppleHead),SAPExportV2CacheCipherAppleCaveOffset,SAPExportV2CacheCipherAppleCode,sizeof(SAPExportV2CacheCipherAppleCode))),
        @"media_key_path_boundary_installed":@(installed(base,SAPExportV2MediaKeyPathOffset,SAPExportV2MediaKeyPathHead,sizeof(SAPExportV2MediaKeyPathHead),SAPExportV2MediaKeyPathCaveOffset,SAPExportV2MediaKeyPathCode,sizeof(SAPExportV2MediaKeyPathCode))),
        @"media_key_blob_boundary_installed":@(installed(base,SAPExportV2MediaKeyBlobOffset,SAPExportV2MediaKeyBlobHead,sizeof(SAPExportV2MediaKeyBlobHead),SAPExportV2MediaKeyBlobCaveOffset,SAPExportV2MediaKeyBlobCode,sizeof(SAPExportV2MediaKeyBlobCode))),
        @"media_context_boundary_installed":@(installed(base,SAPExportV2MediaContextOffset,SAPExportV2MediaContextHead,sizeof(SAPExportV2MediaContextHead),SAPExportV2MediaContextCaveOffset,SAPExportV2MediaContextCode,sizeof(SAPExportV2MediaContextCode))),
        @"media_unseal_boundary_installed":@(installed(base,SAPExportV2UnsealedMediaKeyOffset,SAPExportV2UnsealedMediaKeyHead,sizeof(SAPExportV2UnsealedMediaKeyHead),SAPExportV2UnsealedMediaKeyCaveOffset,SAPExportV2UnsealedMediaKeyCode,sizeof(SAPExportV2UnsealedMediaKeyCode))),
        @"media_output_boundary_installed":@NO,@"register_snapshot_abi":@2,@"all_gprs_and_vectors_preserved":@YES,
        @"per_block_aes_probes_installed":@NO,
        @"media_record_boundary_installed":@(installed(base,SAPExportV2MediaRecordOffset,SAPExportV2MediaRecordHead,sizeof(SAPExportV2MediaRecordHead),SAPExportV2MediaRecordCaveOffset,SAPExportV2MediaRecordCode,sizeof(SAPExportV2MediaRecordCode))),
        @"counter_scope":@"process lifetime; functional export observations also run with Diagnostics off"};
}
