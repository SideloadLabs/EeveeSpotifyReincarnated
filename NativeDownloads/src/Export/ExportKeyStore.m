#import "ExportKeyStore.h"
#import "TrackExport.h"
#import "ExportKeyVault.h"
#import "ExportObservation.h"
#import "ExportLayout.h"
#import "ExportSites.h"
#import "ExportMediaUnsealPatch.h"
#import "DiagnosticTrace.h"
#import <mach/mach.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <string.h>

static NSString *keyHex(NSData *data){NSMutableString *s=[NSMutableString string];for(NSUInteger i=0;i<data.length;i++)[s appendFormat:@"%02x",((const uint8_t *)data.bytes)[i]];return s;}

// No files, queues, network requests or timers are created by this observer.
// The bounded process-only key cache lets a later explicit export read files
// downloaded in this session. Verified unsealed keys can also enter the device-only
// Keychain asynchronously; no key is included in a log or exported file.
static os_unfair_lock keyLock=OS_UNFAIR_LOCK_INIT;
static struct {uint8_t file[20],key[16];BOOL used,unsealed;} keys[1024];
// The native media-key record is a 28-byte opaque value. It is kept only in
// bounded process memory and is never serialized; export tries bounded
// interpretations of it instead of asserting a published layout.
static struct {uint8_t file[20],blob[28];BOOL used;} keyBlobs[256];
static unsigned nextKey,nextKeyBlob;
static atomic_uint_fast64_t storedKeyCallbacks,streamKeys,offlineKeys,keyBlobCaptures,unsealedKeyCaptures,unsealedScopeRejections;

static BOOL readMemory(uintptr_t p,void *out,size_t n){vm_size_t copied=0;return p&&vm_read_overwrite(mach_task_self(),p,n,(vm_address_t)out,&copied)==KERN_SUCCESS&&copied==n;}
static void storeKey(const uint8_t file[20],const uint8_t key[16]);
static void storeKeyWithOrigin(const uint8_t file[20],const uint8_t key[16],BOOL unsealed);
void SAPExportObserveUnsealedMediaKey(const SAPExportRegisterFrame *frame,uintptr_t image) {
    if(!frame||!image)return;
#ifndef SAP_EXPORT_TESTING
    uint8_t code[sizeof(SAPMediaUnsealCallerCode)];
    if(!readMemory(image+SAPMediaUnsealCodeOffset,code,sizeof(SAPMediaUnsealCode))||
       memcmp(code,SAPMediaUnsealCode,sizeof(SAPMediaUnsealCode))||
       !readMemory(image+SAPMediaUnsealCallerOffset,code,sizeof(SAPMediaUnsealCallerCode))||
       memcmp(code,SAPMediaUnsealCallerCode,sizeof(SAPMediaUnsealCallerCode)))return;
#endif
    // The unsealing function saves caller x20 at [fp-16] and caller LR at [fp+8].
    // Only the native key-store call at SAPMediaUnsealCallerOffset has a proven file-ID x20;
    // its return address is SAPExportUnsealCallerReturnOffset.
    uintptr_t fp=(uintptr_t)frame->x[29],caller=0,fileAddress=0;
    uint8_t file[20]={0},key[16]={0};
    if(fp<16||fp>UINTPTR_MAX-8||!readMemory(fp+8,&caller,8)||caller!=image+SAPExportUnsealCallerReturnOffset||
       !readMemory(fp-16,&fileAddress,8)||!readMemory(fileAddress,file,sizeof(file))) {
        atomic_fetch_add(&unsealedScopeRejections,1);return;
    }
    memcpy(key,frame->q[0],sizeof(key));
    storeKeyWithOrigin(file,key,YES);atomic_fetch_add(&unsealedKeyCaptures,1);
    SAP_TRACE("export","native_media_key_unsealed",0,@{
        @"file_identifier":keyHex([NSData dataWithBytes:file length:sizeof(file)]),
        @"source":@"native VM output q0 before key-store record encryption",
        @"captured_bytes":@16,@"file_association_verified":@YES,
        @"audio_validity_proven":@NO,@"key_in_log":@NO,@"key_written_to_disk":@NO});
    memset_s(key,sizeof(key),0,sizeof(key));
}
void SAPExportObserveOfflineSuccess(const uint64_t *r,uintptr_t image) {
#ifndef SAP_EXPORT_TESTING
    uint8_t body[40];
    if(!image||!readMemory(image+SAPExportLayoutOffset0,body,sizeof(SAPExportLayoutCode0))||memcmp(body,SAPExportLayoutCode0,sizeof(SAPExportLayoutCode0))||
       !readMemory(image+SAPExportLayoutOffset1,body,sizeof(SAPExportLayoutCode1))||memcmp(body,SAPExportLayoutCode1,sizeof(SAPExportLayoutCode1)))return;
#else
    (void)image;
#endif
    uintptr_t functor=0,wrapper=0,owner=0,descriptor=0;uint8_t file[20],key[16];
    if(!r||!readMemory(r[0],&functor,8)||!readMemory(functor,&wrapper,8)||!readMemory(wrapper+8,&owner,8)||
       !readMemory(owner+SAPExportOwnerDescriptorOffset,&descriptor,8)||!readMemory(descriptor+4,file,20)||!readMemory(r[1],key,16))return;
    storeKey(file,key);
    SAP_TRACE("export","media_key_candidate_observed",0,@{@"file_identifier":keyHex([NSData dataWithBytes:file length:20]),@"source":@"native_offline_success",@"key_in_log":@NO,@"validity_proven":@NO});
    atomic_fetch_add(&offlineKeys,1);memset_s(key,sizeof(key),0,sizeof(key));
}
void SAPExportObserveStreamSuccess(const uint64_t *r,uintptr_t image) {
#ifndef SAP_EXPORT_TESTING
    uint8_t body[12];
    if(!image||!readMemory(image+SAPExportLayoutOffset2,body,sizeof(body))||memcmp(body,SAPExportLayoutCode2,sizeof(body))||
       !readMemory(image+SAPExportLayoutOffset3,body,sizeof(body))||memcmp(body,SAPExportLayoutCode3,sizeof(body)))return;
#else
    (void)image;
#endif
    uintptr_t capture=0;uint8_t file[20],key[16];
    if(!r||!readMemory(r[0],&capture,8)||!readMemory(capture+8,file,20)||!readMemory(r[1],key,16))return;
    storeKey(file,key);atomic_fetch_add(&streamKeys,1);memset_s(key,sizeof(key),0,sizeof(key));
    SAP_TRACE("export","stream_key_observed",0,@{@"file_identifier":keyHex([NSData dataWithBytes:file length:20]),@"key_written_to_disk":@NO});
}
// Called at the UUID-guarded entry of the native cached-key setter. Its
// arguments are (cipher object, file identifier, key material). The observer
// copies only the opaque 28-byte value; it does not call or alter native code.
void SAPExportObserveMediaKeyBlob(const uint64_t *r,uintptr_t image) {
    if(!r||!image)return;
    uint8_t file[20],blob[28];
    if(!readMemory(r[1],file,sizeof(file))||!readMemory(r[2],blob,sizeof(blob)))return;
    os_unfair_lock_lock(&keyLock);
    unsigned slot=256;
    for(unsigned i=0;i<256;i++)if(keyBlobs[i].used&&!memcmp(keyBlobs[i].file,file,20)){slot=i;break;}
    if(slot==256)slot=nextKeyBlob++%256;
    memcpy(keyBlobs[slot].file,file,20);memcpy(keyBlobs[slot].blob,blob,28);keyBlobs[slot].used=YES;
    os_unfair_lock_unlock(&keyLock);
    atomic_fetch_add(&keyBlobCaptures,1);
    memset_s(blob,sizeof(blob),0,sizeof(blob));
}
BOOL SAPExportKeyStoreCopyBlob(NSData *file,uint8_t blob[28]) {
    if(![file isKindOfClass:NSData.class]||file.length!=20||!blob)return NO;
    BOOL found=NO;os_unfair_lock_lock(&keyLock);
    for(unsigned i=0;i<256;i++)if(keyBlobs[i].used&&!memcmp(keyBlobs[i].file,file.bytes,20)){memcpy(blob,keyBlobs[i].blob,28);found=YES;break;}
    os_unfair_lock_unlock(&keyLock);return found;
}
static void storeKey(const uint8_t file[20],const uint8_t key[16]) {
    storeKeyWithOrigin(file,key,NO);
}
static void storeKeyWithOrigin(const uint8_t file[20],const uint8_t key[16],BOOL unsealed) {
    os_unfair_lock_lock(&keyLock);unsigned slot=1024;
    for(unsigned i=0;i<1024;i++)if(keys[i].used&&!memcmp(keys[i].file,file,20)){slot=i;break;}
    // A later success callback carries the protected representation. It must
    // never overwrite an observed unsealing result for this same file ID.
    if(slot!=1024&&keys[slot].unsealed&&!unsealed){os_unfair_lock_unlock(&keyLock);return;}
    BOOL changed=slot==1024||!keys[slot].unsealed||memcmp(keys[slot].key,key,16)!=0;
    if(slot==1024)slot=nextKey++%1024;
    memcpy(keys[slot].file,file,20);memcpy(keys[slot].key,key,16);keys[slot].used=YES;keys[slot].unsealed=unsealed;
    os_unfair_lock_unlock(&keyLock);atomic_fetch_add(&storedKeyCallbacks,1);
    if(unsealed&&changed)SAPVaultObserveMedia([NSData dataWithBytes:file length:20],[NSData dataWithBytes:key length:16]);
}
BOOL SAPExportKeyStoreCopyKey(NSData *file,uint8_t key[16]) {
    if(![file isKindOfClass:NSData.class] || file.length!=20 || !key)return NO;
    BOOL found=NO;os_unfair_lock_lock(&keyLock);
    for(unsigned i=0;i<1024;i++)if(keys[i].used&&!memcmp(keys[i].file,file.bytes,20)){memcpy(key,keys[i].key,16);found=YES;break;}
    os_unfair_lock_unlock(&keyLock);return found;
}
BOOL SAPExportKeyStoreIsUnsealed(NSData *file) {
    if(![file isKindOfClass:NSData.class]||file.length!=20)return NO;
    BOOL unsealed=NO;os_unfair_lock_lock(&keyLock);
    for(unsigned i=0;i<1024;i++)if(keys[i].used&&!memcmp(keys[i].file,file.bytes,20)){unsealed=keys[i].unsealed;break;}
    os_unfair_lock_unlock(&keyLock);return unsealed;
}

NSDictionary *SAPExportKeyStoreReport(void) {
    return @{@"key_callbacks_stored":@(atomic_load(&storedKeyCallbacks)),@"stream_key_callbacks_stored":@(atomic_load(&streamKeys)),@"offline_key_callbacks_stored":@(atomic_load(&offlineKeys)),@"media_key_blobs_stored":@(atomic_load(&keyBlobCaptures)),@"native_unsealed_keys_observed":@(atomic_load(&unsealedKeyCaptures)),@"native_unsealed_scope_rejections":@(atomic_load(&unsealedScopeRejections))};
}
