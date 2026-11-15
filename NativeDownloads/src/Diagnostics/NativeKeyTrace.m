#include "TargetProfile.h"
#import "NativeKeyTrace.h"
#import "NativeTracePatch.h"
#import "DiagnosticTrace.h"
#import "ExportSites.h"
#import "WireProto.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#include <stdatomic.h>

static const uint8_t uuidBytes[]=SAP_SPOTIFY_UUID_BYTES;
static os_unfair_lock mapLock=OS_UNFAIR_LOCK_INIT;
static struct {uintptr_t success,failure,wrapper,owner;SAPTraceID operation;uint64_t generation;uint8_t fileID[20];} requests[256];
static unsigned nextSlot;
static atomic_uint_fast64_t observedRequests,successCallbacks,failureCallbacks,unmatchedCallbacks,evictedMappings;
static atomic_int lastArgument=ATOMIC_VAR_INIT(-1);
static NSMutableDictionary<NSString *,NSString *> *fileTracks;
static atomic_uint_fast64_t metadataMappingsDropped;
void SAPNativeKeyTraceResetSegment(void) {
    os_unfair_lock_lock(&mapLock);
    memset(requests,0,sizeof(requests));nextSlot=0;fileTracks=nil;
    os_unfair_lock_unlock(&mapLock);
}
static BOOL readBytes(uintptr_t pointer,void *out,size_t count) {
    vm_size_t copied=0;return pointer&&vm_read_overwrite(mach_task_self(),pointer,count,(vm_address_t)out,&copied)==KERN_SUCCESS&&copied==count;
}
static BOOL supported(uintptr_t image) {
    struct mach_header_64 h;if(!readBytes(image,&h,sizeof(h))||h.magic!=MH_MAGIC_64||h.ncmds>1024||h.sizeofcmds>1048576)return NO;
    uintptr_t cursor=image+sizeof(h),end=cursor+h.sizeofcmds;
    for(unsigned i=0;i<h.ncmds;i++){struct load_command c;if(cursor+sizeof(c)>end||!readBytes(cursor,&c,sizeof(c))||c.cmdsize<8||cursor+c.cmdsize>end)return NO;
        if(c.cmd==LC_UUID){struct uuid_command u;return c.cmdsize>=sizeof(u)&&readBytes(cursor,&u,sizeof(u))&&!memcmp(u.uuid,uuidBytes,16);}cursor+=c.cmdsize;}return NO;
}
static NSString *hex(const uint8_t *bytes,NSUInteger count) {NSMutableString *out=[NSMutableString stringWithCapacity:count*2];for(NSUInteger i=0;i<count;i++)[out appendFormat:@"%02x",bytes[i]];return out;}
static NSString *trackForFile(const uint8_t *fileID) {
    NSString *key=hex(fileID,20);os_unfair_lock_lock(&mapLock);NSString *uri=fileTracks[key];os_unfair_lock_unlock(&mapLock);return uri;
}
static void metadataTrack(NSArray *fields,NSString *fallback,unsigned depth,uint64_t epoch) {
    if(depth>1)return;NSString *uri=SAPProtoString(fields,36);
    if(![uri hasPrefix:@"spotify:track:"]||uri.length!=36)uri=fallback;
    if(![uri hasPrefix:@"spotify:track:"]||uri.length!=36)return;
    for(NSDictionary *field in fields) {
        unsigned n=[field[@"number"]unsignedIntValue];if([field[@"wire"]unsignedIntValue]!=2)continue;
        if(n==13){metadataTrack(SAPProtoFields(field[@"value"]),nil,depth+1,epoch);continue;}
        if(n!=12)continue;NSData *file=SAPProtoData(SAPProtoFields(field[@"value"]),1);if(file.length!=20)continue;
        NSString *identifier=hex(file.bytes,file.length);os_unfair_lock_lock(&mapLock);
        if(!SAPTraceIsActive()||epoch!=SAPTraceGeneration()){os_unfair_lock_unlock(&mapLock);return;}
        if(!fileTracks)fileTracks=[NSMutableDictionary dictionary];NSString *prior=fileTracks[identifier];
        BOOL conflict=prior&&![prior isEqual:uri],changed=![prior isEqual:uri];
        if(fileTracks.count<4096||prior)fileTracks[identifier]=conflict?@"ambiguous":uri;else atomic_fetch_add(&metadataMappingsDropped,1);
        os_unfair_lock_unlock(&mapLock);
        if(changed)SAP_TRACE("metadata","audio_file_track_link",SAPTraceCurrentOperation(),@{@"file_identifier":identifier,@"track_uri":uri,
            @"source":@"ClassicMetadataService.GetEntity response; metadata Track.file(12).file_id(1)",@"ambiguous":@(conflict),@"key_material_read":@NO});
    }
}
void SAPNativeKeyTraceObserveMetadata(NSString *service,NSString *method,NSString *requestURI,NSData *response) {
    if(!SAPTraceIsActive()||![service isEqual:@"spotify.metadata_esperanto.proto.ClassicMetadataService"]||![method isEqual:@"GetEntity"]||![response isKindOfClass:NSData.class]||response.length>4*1024*1024)return;
    uint64_t epoch=SAPTraceGeneration();NSArray *item=SAPProtoFields(SAPProtoData(SAPProtoFields(response),1));if(SAPProtoNumber(item,1,0))return;
    NSData *track=SAPProtoData(item,4);if(track)metadataTrack(SAPProtoFields(track),requestURI,0,epoch);
    NSArray *album=SAPProtoFields(SAPProtoData(item,3));
    for(NSDictionary *disc in album) {
        if([disc[@"number"]unsignedIntValue]!=11||[disc[@"wire"]unsignedIntValue]!=2)continue;
        for(NSDictionary *t in SAPProtoFields(disc[@"value"])) {
            if([t[@"number"]unsignedIntValue]==3&&[t[@"wire"]unsignedIntValue]==2)metadataTrack(SAPProtoFields(t[@"value"]),nil,0,epoch);
        }
    }
}
static uintptr_t spotifyImage(void) {
    for(unsigned i=0;i<_dyld_image_count();i++){const char *path=_dyld_get_image_name(i);if(!path||strcmp(strrchr(path,'/')?strrchr(path,'/')+1:path,"Spotify"))continue;
        uintptr_t base=(uintptr_t)_dyld_get_image_header(i);if(supported(base))return base;}return 0;
}
static BOOL boundaryInstalled(uintptr_t base,uintptr_t entry,uintptr_t cave,const uint8_t *head,size_t headSize,const uint8_t *code,size_t size) {
    if(!base)return NO;uint8_t observed[512];
    return size<=sizeof(observed)&&readBytes(base+entry,observed,headSize)&&!memcmp(observed,head,headSize)&&readBytes(base+cave,observed,size)&&!memcmp(observed,code,size);
}
static void observe(unsigned kind,const uint64_t *frame,uintptr_t image) {
    if(!SAPTraceIsActive())return;
    uint64_t g=SAPTraceGeneration();
    if(kind==0){
        uint8_t fileID[20]={0};BOOL fileRead=readBytes(frame[1],fileID,sizeof(fileID));uintptr_t success=0,failure=0;
        BOOL successRead=readBytes(frame[4],&success,sizeof(success)),failureRead=readBytes(frame[5],&failure,sizeof(failure));
        Dl_info target={0};BOOL targetLocated=dladdr((void *)(uintptr_t)frame[9],&target)!=0;
        static const uint8_t providerHead[]={0xff,0x03,0x06,0xd1,0xfc,0x6f,0x12,0xa9,0xfa,0x67,0x13,0xa9,0xf8,0x5f,0x14,0xa9};
        uint8_t head[sizeof(providerHead)];
        BOOL providerVerified=image&&targetLocated&&(uintptr_t)target.dli_fbase==image&&frame[9]-image==SAP_TARGET_PROVIDER-UINT64_C(0x100000000)&&readBytes(frame[9],head,sizeof(head))&&!memcmp(head,providerHead,sizeof(head));
        NSString *trackURI=fileRead?trackForFile(fileID):nil;BOOL linked=[trackURI hasPrefix:@"spotify:track:"];
        SAPTraceID op=SAPTraceBegin(@"native_offline_key_request",@"verified_spotify_call_site",@{@"argument_before_call":@((uint32_t)frame[2]),
            @"target_is_verified_provider":@(providerVerified),@"target_image":target.dli_fname?@(target.dli_fname):@"unresolved",
            @"target_image_offset":targetLocated?[NSString stringWithFormat:@"0x%llx",(unsigned long long)(frame[9]-(uintptr_t)target.dli_fbase)]:NSNull.null,
            @"file_identifier":fileRead?hex(fileID,sizeof(fileID)):@"unavailable",@"track_uri":linked?trackURI:NSNull.null,@"track_uri_link":linked?@"previously_observed_metadata_file_id":@"not_available_at_this_boundary",@"key_material_read":@NO});
        atomic_store(&lastArgument,(int)(uint32_t)frame[2]);atomic_fetch_add(&observedRequests,1);
        if(successRead&&failureRead&&success&&failure){os_unfair_lock_lock(&mapLock);
            if(!SAPTraceIsActive()||g!=SAPTraceGeneration()){os_unfair_lock_unlock(&mapLock);return;}
            unsigned i=nextSlot++%256;
            BOOL evicted=requests[i].operation&&requests[i].generation==g;if(evicted)atomic_fetch_add(&evictedMappings,1);
            uintptr_t wrapper=0,owner=0;readBytes(success,&wrapper,sizeof(wrapper));if(wrapper)readBytes(wrapper+8,&owner,sizeof(owner));
            requests[i].success=success;requests[i].failure=failure;requests[i].wrapper=wrapper;requests[i].owner=owner;requests[i].operation=op;requests[i].generation=g;memcpy(requests[i].fileID,fileID,20);os_unfair_lock_unlock(&mapLock);
            if(evicted)SAP_TRACE("native_key","request_mapping_evicted",op,@{@"mapping_capacity":@256});
        }else SAP_TRACE("native_key","callback_mapping_unavailable",op,@{@"success_functor_read":@(successRead),@"failure_functor_read":@(failureRead)});
        return;
    }
    uintptr_t functor=0,wrapper=0,owner=0,descriptor=0;BOOL functorRead=readBytes(frame[0],&functor,sizeof(functor));SAPTraceID op=0;uint8_t fileID[20]={0},ownerFile[20]={0};
    if(functorRead&&functor)readBytes(functor,&wrapper,sizeof(wrapper));if(wrapper)readBytes(wrapper+8,&owner,sizeof(owner));
    BOOL ownerFileRead=owner&&readBytes(owner+SAPExportOwnerDescriptorOffset,&descriptor,sizeof(descriptor))&&readBytes(descriptor+4,ownerFile,20);
    NSMutableArray *candidates=[NSMutableArray array];BOOL exactIdentity=YES;
    if(functorRead){os_unfair_lock_lock(&mapLock);
        for(unsigned pass=0;pass<2;pass++){
            NSUInteger matches=0;unsigned selected=0;
            for(unsigned i=0;i<256;i++)if(requests[i].generation==g&&requests[i].operation){
                BOOL match=pass==0?(kind==1?requests[i].success:requests[i].failure)==functor:
                    ownerFileRead&&requests[i].wrapper==wrapper&&requests[i].owner==owner&&!memcmp(requests[i].fileID,ownerFile,20);
                if(match){matches++;selected=i;if(candidates.count<8)[candidates addObject:@(requests[i].operation)];}
            }
            if(matches==1){op=requests[selected].operation;memcpy(fileID,requests[selected].fileID,20);requests[selected].operation=0;exactIdentity=pass==0;break;}
            if(matches>1)break;
        }
        os_unfair_lock_unlock(&mapLock);
    }
    if(!op)atomic_fetch_add(&unmatchedCallbacks,1);
    NSMutableDictionary *facts=[@{@"request_link":op?(exactIdentity?@"exact_original_functor_identity":@"unique_captured_owner_and_file_identifier"):(candidates.count>1?@"ambiguous":@"unavailable"),@"candidate_operation_ids":candidates,@"file_identifier":op?hex(fileID,20):@"unavailable",
        @"key_material_read":@NO,@"native_callback_modified":@NO,@"source_of_key":@"unknown",@"track_uri":NSNull.null}mutableCopy];
    NSString *linked=op?trackForFile(fileID):nil;if([linked hasPrefix:@"spotify:track:"]){facts[@"track_uri"]=linked;facts[@"track_uri_link"]=@"previously_observed_metadata_file_id";}
    if(kind==1){atomic_fetch_add(&successCallbacks,1);facts[@"result_pointer_present"]=@(frame[1]!=0);facts[@"key_validity_tested"]=@NO;}
    else {atomic_fetch_add(&failureCallbacks,1);facts[@"first_error_word_signed32"]=@((int32_t)frame[1]);facts[@"server_rejection_reason_proven"]=@NO;
        Dl_info info={0};if(frame[2]&&dladdr((void *)(uintptr_t)frame[2],&info)){
            facts[@"error_category_image"]=info.dli_fname?@(info.dli_fname):@"unknown";
            facts[@"error_category_image_offset"]=[NSString stringWithFormat:@"0x%llx",(unsigned long long)(frame[2]-(uintptr_t)info.dli_fbase)];
        }else facts[@"error_category_image_offset"]=NSNull.null;
    }
    SAP_TRACE("native_key",kind==1?"success_callback_invoked":"failure_callback_invoked",op,facts);
}
static _Atomic(SAPOfflineKeySuccessObserver) offlineSuccessObserver;
void SAPSetOfflineKeySuccessObserver(SAPOfflineKeySuccessObserver observer) {
    atomic_store(&offlineSuccessObserver,observer);
}
__attribute__((visibility("default"))) void SAPTraceNativeBoundary(unsigned kind,const uint64_t *registers) {
    SAPOfflineKeySuccessObserver observer=kind==1?atomic_load(&offlineSuccessObserver):NULL;
    if(!observer&&!SAPTraceIsActive())return;
    Dl_info location={0};if(!dladdr(__builtin_return_address(0),&location)||!supported((uintptr_t)location.dli_fbase))return;
    @autoreleasepool {@try {
        if(observer)observer(registers,(uintptr_t)location.dli_fbase);
        if(SAPTraceIsActive())observe(kind,registers,(uintptr_t)location.dli_fbase);}
        @catch(NSException *exception){SAP_TRACE("native_key","observer_failed",0,@{@"exception":exception.name?:@"unknown",@"native_flow_modified":@NO});}}
}
NSDictionary *SAPNativeKeyTraceReport(void) {
    uintptr_t image=spotifyImage();
    void *helper=dlsym(RTLD_DEFAULT,"SAPTraceNativeBoundary");Dl_info binding={0};
    BOOL helperLocated=helper&&dladdr(helper,&binding);
    return @{@"request_boundary_installed":@(boundaryInstalled(image,SAPTraceRequestOffset,SAPTraceRequestCaveOffset,SAPTraceRequestHead,sizeof(SAPTraceRequestHead),SAPTraceRequestCode,sizeof(SAPTraceRequestCode))),
        @"success_boundary_installed":@(boundaryInstalled(image,SAPTraceSuccessOffset,SAPTraceSuccessCaveOffset,SAPTraceSuccessHead,sizeof(SAPTraceSuccessHead),SAPTraceSuccessCode,sizeof(SAPTraceSuccessCode))),
        @"failure_boundary_installed":@(boundaryInstalled(image,SAPTraceFailureOffset,SAPTraceFailureCaveOffset,SAPTraceFailureHead,sizeof(SAPTraceFailureHead),SAPTraceFailureCode,sizeof(SAPTraceFailureCode))),
        @"requests_observed":@(atomic_load(&observedRequests)),@"last_argument_before_call":@(atomic_load(&lastArgument)),@"success_callbacks_observed":@(atomic_load(&successCallbacks)),
        @"failure_callbacks_observed":@(atomic_load(&failureCallbacks)),@"unmatched_callbacks":@(atomic_load(&unmatchedCallbacks)),@"evicted_request_mappings":@(atomic_load(&evictedMappings)),
        @"metadata_links_dropped_at_capacity":@(atomic_load(&metadataMappingsDropped)),
        @"helper_binding_matches_this_library":@(helper==(void *)SAPTraceNativeBoundary),@"helper_image":helperLocated&&binding.dli_fname?@(binding.dli_fname):@"unresolved",
        @"counters_scope":@"process lifetime while diagnostics is enabled",@"metadata_mapping_scope":@"current diagnostics segment only",
        @"key_material_read":@NO,@"all_provider_call_sites_covered":@NO,@"track_uri_mapping":@"unavailable unless independently observed metadata establishes it"};
}
#ifdef SAP_TESTING
void SAPTraceNativeBoundaryForTesting(unsigned kind,const uint64_t *registers) {observe(kind,registers,0);}
#endif
