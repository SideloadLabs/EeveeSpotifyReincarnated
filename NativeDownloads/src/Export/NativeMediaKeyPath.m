#import <Foundation/Foundation.h>
#import "DiagnosticTrace.h"
#import "ExportSites.h"
#import <mach/mach.h>
#import <os/lock.h>
#import <dlfcn.h>
#include <string.h>

static BOOL readPointer(uintptr_t p,void *out,size_t size) {
    vm_size_t n=0;return p && p<=UINTPTR_MAX-size && vm_read_overwrite(mach_task_self(),p,size,(vm_address_t)out,&n)==KERN_SUCCESS && n==size;
}
static NSDictionary *methodTarget(uintptr_t object,unsigned slot,uintptr_t image) {
    uintptr_t table=0,target=0;
    if(!readPointer(object,&table,8)||!table||table>UINTPTR_MAX-slot||!readPointer(table+slot,&target,8)||!target)return @{@"resolved":@NO};
    Dl_info info={0};
    if(!dladdr((void *)target,&info))return @{@"resolved":@NO};
    const char *path=info.dli_fname?:"",*name=strrchr(path,'/');
    return @{@"resolved":@YES,@"image":@(name?name+1:path),
        @"image_offset":[NSString stringWithFormat:@"0x%llx",(unsigned long long)(target-(uintptr_t)info.dli_fbase)],
        @"spotify_image":@((uintptr_t)info.dli_fbase==image)};
}
void SAPObserveMediaKeyPath(const uint64_t *registers,uintptr_t image) {
    if(!SAPTraceIsActive()||!registers||!image)return;
    uint64_t generation=SAPTraceGeneration();
    uintptr_t owner=registers[0],descriptor=0,cached=0,request=0,cipher=0;uint8_t file[20]={0};
    if(owner>UINTPTR_MAX-SAPExportOwnerDescriptorOffset || !readPointer(owner+SAPExportOwnerDescriptorOffset,&descriptor,8)||descriptor>UINTPTR_MAX-4||
       !readPointer(descriptor+4,file,sizeof(file)) || !readPointer(owner+0x20,&cached,8) ||
       !readPointer(owner+0x10,&request,8)||!readPointer(owner+0x18,&cipher,8)) {
        SAP_TRACE("export","native_media_key_path_unreadable",0,@{@"key_bytes_read":@NO});return;
    }
    // Diagnostics retain only opaque identities for deduplication, never keys.
    static os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;
    static struct {uint8_t file[20];uintptr_t cached,cipher;} seen[128];
    static unsigned count;static uint64_t epoch;
    BOOL added=NO;os_unfair_lock_lock(&lock);
    if(epoch!=generation){memset(seen,0,sizeof(seen));count=0;epoch=generation;}
    BOOL found=NO;
    for(unsigned i=0;i<count;i++)if(!memcmp(seen[i].file,file,20)&&seen[i].cached==cached&&seen[i].cipher==cipher){found=YES;break;}
    if(!found&&count<128){memcpy(seen[count].file,file,20);seen[count].cached=cached;seen[count++].cipher=cipher;added=YES;}
    os_unfair_lock_unlock(&lock);
    if(!added||!SAPTraceIsActive()||SAPTraceGeneration()!=generation)return;
    char hex[41];for(unsigned i=0;i<20;i++)snprintf(hex+2*i,3,"%02x",file[i]);
    SAP_TRACE("export","native_media_key_path",0,@{@"file_identifier":@(hex),
        @"cached_key_lookup":methodTarget(cached,0x28,image),
        @"new_key_request":methodTarget(request,0x10,image),
        @"cipher_use_file_key":methodTarget(cipher,0x10,image),
        @"source":@"guarded native media-reader entry before cached-key lookup",
        @"cache_hit_proven":@NO,@"key_bytes_read":@NO,@"native_method_called_by_observer":@NO,
        @"coverage":@"first 128 file/provider/cipher identities per diagnostic generation"});
}
