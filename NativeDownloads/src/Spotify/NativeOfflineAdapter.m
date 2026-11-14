#include "TargetProfile.h"
#import "Localization.h"
#import "NativeOffline.h"
#import "NativeRestrictionsPatch.h"
#import "NativeKeyModePatch.h"
#import "OfflineLimits.h"
#import "TrackJournal.h"
#import "Diagnostics.h"
#import "DownloadCompatibility.h"
#import "TrackDownload.h"
#import "Deadline.h"
#import "KeyModePolicy.h"
#import "DiagnosticTrace.h"
#import "NativeTracePatch.h"
#import "NativeSetupStatus.h"
#import "NativeAlbumCommand.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

static __weak id nativeWrapper;
static BOOL hookInstalled, queueHookInstalled, entityHookInstalled, iconHookInstalled;
static void (*originalMakeEntity)(id,SEL,id,id);
static void (*originalMakeEntityOnly)(id,SEL,id);
static void (*originalResetEntity)(id,SEL,id);
static NSInteger (*originalSyncStatus)(id,SEL,id);
static void *(*originalInit)(void *,SEL,void *,void *,void *,void *);
static unsigned long long (*originalStateForTrack)(id,SEL,id);
static os_unfair_lock stateLock=OS_UNFAIR_LOCK_INIT;
static NSDictionary *snapshot;
static const uint8_t supportedUUID[]=SAP_SPOTIFY_UUID_BYTES;
static const uint8_t setterCode[]=SAP_SETTER_ORIGINAL_BYTES;
static const uintptr_t setterOffset=SAP_TARGET_SETTER-UINT64_C(0x100000000);
static atomic_int requestedKeyMode=ATOMIC_VAR_INIT(0);
static atomic_int lastSelectorMode=ATOMIC_VAR_INIT(-1);
static atomic_uint_fast64_t selectorReads[2];
static NSString *const keyModePreference=@"PixieOfflineKeyRequestMode";
static int configuredKeyMode(void) {return atomic_load_explicit(&requestedKeyMode,memory_order_relaxed);}

// Called by the pre-installed, verified Spotify call-site trampoline. Its hot
// path only updates atomic counters. Reports read configuredKeyMode directly,
// so opening settings never manufactures a selector invocation.
__attribute__((visibility("default"))) int SAPCurrentKeyRequestMode(void) {
    int mode=configuredKeyMode();
    atomic_fetch_add_explicit(&selectorReads[mode==1?1:0],1,memory_order_relaxed);
    atomic_store_explicit(&lastSelectorMode,mode,memory_order_relaxed);
    return mode;
}

@interface SAPNativePreparation : NSObject {
    atomic_bool _finished;
}
@property(nonatomic,copy) void (^completion)(BOOL,NSString *);
@property(nonatomic) SAPTraceID traceOperation;
- (BOOL)finished;
- (void)finish:(BOOL)ready reason:(NSString *)reason report:(NSDictionary *)report;
@end
@implementation SAPNativePreparation
- (instancetype)init { if((self=[super init]))atomic_init(&_finished,false);return self; }
- (BOOL)finished { return atomic_load(&_finished); }
- (void)finish:(BOOL)ready reason:(NSString *)reason report:(NSDictionary *)report {
    bool wasFinished=false;
    if(!atomic_compare_exchange_strong(&_finished,&wasFinished,true))return;
    SAP_TRACE("native_setup","completed",self.traceOperation,@{@"local_prepared":@(ready),@"authorization_checked":@NO,@"reason":reason?:@"",
        @"before":report[@"before"]?:@{},@"after":report[@"after"]?:@{},@"changed":report[@"changed"]?:@NO});
    NSMutableDictionary *value=[report mutableCopy]?:[NSMutableDictionary dictionary];
    value[@"local_prepared"]=@(ready);value[@"authorization_checked"]=@NO;value[@"reason"]=reason?:@"";
    NSMutableDictionary *quota=[(value[@"after"]?:value[@"before"]) mutableCopy]?:[NSMutableDictionary dictionary];
    quota[@"local_prepared"]=@(ready);quota[@"authorization_checked"]=@NO;quota[@"reason"]=reason?:@"";quota[@"changed"]=value[@"changed"]?:@NO;
    SAPJournalNoteQuota(quota);
    SAP_JOURNAL_ACTION(@"native_setup_result",@{@"local_prepared":@(ready),@"authorization_checked":@NO,@"reason":reason?:@"",
        @"before":value[@"before"]?:@{},@"after":value[@"after"]?:@{},
        @"quota_values_changed":value[@"changed"]?:@NO});
    os_unfair_lock_lock(&stateLock);snapshot=[value copy];os_unfair_lock_unlock(&stateLock);
    dispatch_async(dispatch_get_main_queue(),^{
        void (^callback)(BOOL,NSString *)=self.completion;self.completion=nil;
        if(callback)callback(ready,reason);
    });
}
@end

static BOOL readMemory(uintptr_t address,void *out,size_t size) {
    vm_size_t copied=0;
    return address && vm_read_overwrite(mach_task_self(),address,size,(vm_address_t)out,&copied)==KERN_SUCCESS && copied==size;
}
static BOOL supportedImage(uintptr_t image) {
    struct mach_header_64 header;
    if(!readMemory(image,&header,sizeof(header))||header.magic!=MH_MAGIC_64||header.ncmds>1024||header.sizeofcmds>1048576)return NO;
    uintptr_t cursor=image+sizeof(header),end=cursor+header.sizeofcmds;
    for(unsigned i=0;i<header.ncmds;i++) {
        struct load_command command;
        if(cursor>end||end-cursor<sizeof(command)||!readMemory(cursor,&command,sizeof(command))||command.cmdsize<sizeof(command)||command.cmdsize>end-cursor)return NO;
        if(command.cmd==LC_UUID) {
            struct uuid_command uuid;
            return command.cmdsize>=sizeof(uuid)&&readMemory(cursor,&uuid,sizeof(uuid))&&!memcmp(uuid.uuid,supportedUUID,sizeof(supportedUUID));
        }
        cursor+=command.cmdsize;
    }
    return NO;
}
// 2 means the signed runtime selector is installed; 0/1 are older fixed
// binaries. -1 means these executable bytes are unknown and must not be used.
static int keyModeKind(uintptr_t image) {
    uint32_t instruction=0;
    if(!image || !readMemory(image+SAPTraceRequestOffset,&instruction,sizeof(instruction)))return -1;
    if(instruction==UINT32_C(0x52800002))return 0;
    if(instruction==UINT32_C(0x52800022))return 1;
    if(!memcmp(&instruction,SAPTraceRequestHead,sizeof(SAPTraceRequestHead))) {
        uint8_t trace[sizeof(SAPTraceRequestCode)];
        if(readMemory(image+SAPTraceRequestCaveOffset,trace,sizeof(trace))&&!memcmp(trace,SAPTraceRequestCode,sizeof(trace)))return 0;
        return -1;
    }
    if(memcmp(&instruction,SAPKeyModeCallerHead,sizeof(SAPKeyModeCallerHead)))return -1;
    uint8_t code[sizeof(SAPKeyModeTrampoline)];
    if(!readMemory(image+SAPKeyModeCaveOffset,code,sizeof(code)) ||
       memcmp(code,SAPKeyModeTrampoline,sizeof(code)))return -1;
    return 2;
}
static int installedKeyModeKind(void) {
    uint32_t count=_dyld_image_count();
    for(uint32_t i=0;i<count;i++) {
        const char *path=_dyld_get_image_name(i);
        if(!path || strcmp(strrchr(path,'/')?strrchr(path,'/')+1:path,"Spotify"))continue;
        uintptr_t image=(uintptr_t)_dyld_get_image_header(i);
        if(supportedImage(image))return keyModeKind(image);
    }
    return -1;
}
NSDictionary *SAPKeyRequestModeReport(void) {
    SAPInstallNativeOffline();
    int kind=installedKeyModeKind();
    BOOL tracedFixedZero=NO;
    for(unsigned i=0;i<_dyld_image_count();i++){
        const char *p=_dyld_get_image_name(i);if(!p||strcmp(strrchr(p,'/')?strrchr(p,'/')+1:p,"Spotify"))continue;
        uintptr_t image=(uintptr_t)_dyld_get_image_header(i);uint32_t word=0;
        if(kind==0&&supportedImage(image)&&readMemory(image+SAPTraceRequestOffset,&word,sizeof(word)))tracedFixedZero=!memcmp(&word,SAPTraceRequestHead,sizeof(SAPTraceRequestHead));
    }
    void *resolved=dlsym(RTLD_DEFAULT,"SAPCurrentKeyRequestMode");
    BOOL symbolMatches=resolved==(void *)&SAPCurrentKeyRequestMode;
    Dl_info resolvedInfo={0};if(resolved)dladdr(resolved,&resolvedInfo);
    int configured=kind==2?configuredKeyMode():kind;
    int last=atomic_load_explicit(&lastSelectorMode,memory_order_relaxed);
    uint64_t readsOne=atomic_load_explicit(&selectorReads[1],memory_order_relaxed);
    BOOL confirmedOne=SAPModeOneConfirmed(kind,symbolMatches,configured,last,readsOne);
    BOOL restoreZero=SAPCanRestoreZero(kind,symbolMatches,configured,last,readsOne);
    return @{@"selected_mode":@(configured),@"configured_mode":@(configured),
             @"last_selector_returned_mode":@(atomic_load_explicit(&lastSelectorMode,memory_order_relaxed)),
             @"selector_reads_mode_0":@(atomic_load_explicit(&selectorReads[0],memory_order_relaxed)),
             @"selector_reads_mode_1":@(atomic_load_explicit(&selectorReads[1],memory_order_relaxed)),
             @"provider_argument_observed":@NO,@"authorization_confirmed":@NO,
             @"runtime_selector_installed":@(kind==2),@"selector_symbol_matches_this_image":@(symbolMatches),
             @"configuration_source":tracedFixedZero?@"verified_static_trace_argument":kind==0||kind==1?@"verified_direct_instruction":kind==2?@"runtime_selector":@"unverified",
             @"selector_resolved_image":resolvedInfo.dli_fname?[NSString stringWithUTF8String:resolvedInfo.dli_fname]:@"unresolved",
             @"mode_one_selection_allowed":@NO,@"mode_one_confirmed":@(confirmedOne),
             @"mode_one_confirmation_source":kind==1?@"verified_direct_instruction":confirmedOne?@"verified_selector_returned_one":@"not_confirmed",
             @"restore_zero_supported":@(restoreZero),@"runtime_selection_supported":@(restoreZero),
             @"restart_required":@NO,
             @"compatibility_check":SAPDownloadCompatibilityReport(),
             @"detail":restoreZero?@"The verified selector returned 1. Restoring mode 0 is available. Download authorization is separate.":
                 (kind==0?@"Mode 0 is verified in the executable. This status does not confirm download authorization.":kind==1?@"Mode 1 is verified in the executable. This status does not confirm download authorization.":kind==2&&symbolMatches?@"Only restoring a confirmed mode 1 to mode 0 is allowed. A saved preference alone is not confirmation.":@"The installed request mode cannot be verified. Changes are disabled.")};
}
void SAPSetKeyRequestMode(NSInteger mode,void (^completion)(BOOL,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPSetKeyRequestMode(mode,completion);});return;}
    if(mode!=0) {
        SAP_JOURNAL_ACTION(@"key_mode_change_rejected",@{@"requested_mode":@(mode),@"reason":@"only_restoring_zero_is_allowed"});
        if(completion)completion(NO,@"Only restoring a confirmed mode 1 to mode 0 is allowed.");return;
    }
    int kind=installedKeyModeKind();
    BOOL matches=dlsym(RTLD_DEFAULT,"SAPCurrentKeyRequestMode")== (void *)&SAPCurrentKeyRequestMode;
    if(!SAPCanRestoreZero(kind,matches,configuredKeyMode(),atomic_load(&lastSelectorMode),atomic_load(&selectorReads[1]))) {
        SAP_JOURNAL_ACTION(@"key_mode_change_rejected",@{@"requested_mode":@(mode),@"installed_kind":@(kind),@"reason":@"no_confirmed_restorable_mode_one"});
        if(completion)completion(NO,@"A verified executing mode-1 selector was not confirmed. No change was made.");return;
    }
    SAP_JOURNAL_ACTION(@"key_mode_change_requested",@{@"requested_mode":@(mode),@"configured_mode":@(configuredKeyMode())});
    SAPRefreshDownloadCompatibility(^(NSDictionary *check){
        NSString *blocked=SAPModeChangeBlockReason(check);
        BOOL matches=dlsym(RTLD_DEFAULT,"SAPCurrentKeyRequestMode")== (void *)&SAPCurrentKeyRequestMode;
        if(blocked || !SAPCanRestoreZero(installedKeyModeKind(),matches,configuredKeyMode(),atomic_load(&lastSelectorMode),atomic_load(&selectorReads[1]))) {
            NSString *reason=blocked?:@"The installed selector changed during the check.";
            SAP_JOURNAL_ACTION(@"key_mode_change_rejected",@{@"requested_mode":@(mode),@"check_id":check[@"id"]?:@"",@"reason":reason,@"configured_mode":@(configuredKeyMode())});
            if(completion)completion(NO,reason);return;
        }
        int previous=atomic_exchange_explicit(&requestedKeyMode,0,memory_order_relaxed);
        [NSUserDefaults.standardUserDefaults setInteger:0 forKey:keyModePreference];
        SAP_JOURNAL_ACTION(@"key_mode_configuration_changed",@{@"previous_configured_mode":@(previous),@"configured_mode":@(mode),
            @"check_id":check[@"id"]?:@"",@"provider_argument_observed":@NO,@"authorization_confirmed":@NO});
        if(completion)completion(YES,previous==(int)mode?@"Mode was already configured.":@"Local mode configuration changed. Spotify's response is not yet known.");
    });
}
static NSString *urlText(id value) {
    if([value respondsToSelector:@selector(absoluteString)])return [value absoluteString];
    return [value isKindOfClass:NSString.class]?value:nil;
}
static BOOL nativeState(id wrapper,void **manager,uintptr_t *image,NSMutableDictionary *out) {
    uintptr_t pointer=0,table=0;
    if(!readMemory((uintptr_t)(__bridge void *)wrapper+8,&pointer,8)||!pointer||!readMemory(pointer,&table,8))return NO;
    Dl_info info={0};
    if(!dladdr((void *)table,&info)||!info.dli_fbase)return NO;
    *image=(uintptr_t)info.dli_fbase;
    if(table-*image+UINT64_C(0x100000000)!=SAP_TARGET_MANAGER_VTABLE||!supportedImage(*image))return NO;
    // This wrapper is captured only from SPTOfflineManagerImplementation's
    // verified initializer. Require its C++ vtable and first method to resolve
    // inside the same exact Spotify image before using the unchanged field layout.
    uintptr_t firstMethod=0;Dl_info methodInfo={0};
    if(!readMemory(table,&firstMethod,sizeof(firstMethod)) ||
       !dladdr((void *)firstMethod,&methodInfo) ||
       (uintptr_t)methodInfo.dli_fbase!=*image)return NO;
    out[@"manager_vtable_va"]=[NSString stringWithFormat:@"0x%llx",(unsigned long long)(table-*image+UINT64_C(0x100000000))];
    uint8_t code[sizeof(setterCode)];
    if(!readMemory(*image+setterOffset,code,sizeof(code)))return NO;
    BOOL guarded=!memcmp(code,SAPGuardedSetterHead,sizeof(SAPGuardedSetterHead));
    if(guarded) {
        uint8_t stub[sizeof(SAPRestrictionTrampoline)];
        if(memcmp(code+4,setterCode+4,sizeof(code)-4) ||
            !readMemory(*image+SAPRestrictionCaveOffset,stub,sizeof(stub)) ||
            memcmp(stub,SAPRestrictionTrampoline,sizeof(stub)))return NO;
    } else if(memcmp(code,setterCode,sizeof(code)))return NO;
    out[@"restriction_guard_active"]=@(guarded);
    int modeKind=keyModeKind(*image);
    out[@"key_mode_runtime_selectable"]=@(modeKind==2);
    out[@"key_mode_selector_binding_verified"]=@(modeKind==2 &&
        dlsym(RTLD_DEFAULT,"SAPCurrentKeyRequestMode")== (void *)&SAPCurrentKeyRequestMode);
    out[@"configured_key_request_mode"]=@(modeKind==2?configuredKeyMode():modeKind);
    out[@"offline_key_request_mode"]=out[@"configured_key_request_mode"];
    // Widened to also cover +0x2b0/+0x2b4: the live reservation counters the slot-reserving
    // function (analysis/queue_track_limit.txt @0x10533b28c) compares against these same
    // limits before it returns TOO_MANY_TRACKS(19). Cross-checked against analysis/queue_restriction_refs.txt.
    uint8_t data[0x30];
    if(!readMemory(pointer+0x2b0,data,sizeof(data)))return NO;
    int32_t currentTracks,currentEpisodes,tracks,episodes;int64_t duration,episodeDuration,abpDuration;
    memcpy(&currentTracks,data,4);memcpy(&currentEpisodes,data+4,4);memcpy(&tracks,data+8,4);
    memcpy(&duration,data+0x10,8);memcpy(&episodes,data+0x18,4);
    memcpy(&episodeDuration,data+0x20,8);memcpy(&abpDuration,data+0x28,8);
    if(currentTracks<0||currentEpisodes<0||tracks<0||episodes<0||duration<0||duration>INT32_MAX||episodeDuration<0||episodeDuration>INT32_MAX||abpDuration<0||abpDuration>INT32_MAX)return NO;
    out[@"current_tracks"]=@(currentTracks);out[@"current_episodes"]=@(currentEpisodes);
    out[@"music_limit"]=@(tracks);out[@"music_duration_seconds"]=@(duration);
    out[@"episode_limit"]=@(episodes);out[@"episode_duration_seconds"]=@(episodeDuration);out[@"abp_duration_seconds"]=@(abpDuration);
    out[@"supported_build"]=@YES;*manager=(void *)pointer;
    // Флаги самой очереди офлайна. Смещения сняты отладчиком на этой же сборке
    // (build/device-v14/queue_breakpoint.py): manager+0x220, вот что отвечает на
    // вопрос «почему трек стоит в waiting» — сеть, политика соединения, лицензия.
    out[@"queue_flags_valid"]=@NO;
    uint8_t flags[0x30];
    if(readMemory(pointer+0x220,flags,sizeof(flags))) {
        uint32_t syncLevel;memcpy(&syncLevel,flags+0x18,4);
        if(flags[1]<=1&&flags[2]<=1&&flags[4]<=1&&flags[0x1c]<=1&&syncLevel<=64) {
            out[@"queue_flags_valid"]=@YES;
            out[@"online"]=@(flags[1]);out[@"connection_allows_offlining"]=@(flags[2]);
            out[@"track_license_expired"]=@(flags[4]);out[@"sync_level"]=@(syncLevel);
            out[@"allow_spotify_tracks"]=@(flags[0x1c]);out[@"token_flag"]=@(flags[0x28]);
            if(flags[5]<=1)out[@"episode_license_expired"]=@(flags[5]);
            if(flags[9]<=1)out[@"disk_full"]=@(flags[9]);
        }
    }
    return YES;
}
static void requestQuotaRaise(NSString *trigger) {
    SAPPrepareNativeOffline(^BOOL{return YES;}, ^(BOOL ready, NSString *reason){
        if(SAPDiagnosticsEnabled())NSLog(@"[SpotifyAudioProbe] offline-quota check (%@): ready=%d reason=%@", trigger, ready, reason);
    });
}
static void *captureInit(void *self,SEL sel,void *scheduler,void *manager,void *sync,void *metadata) {
    SAPTraceHookCalled(object_getClass((__bridge id)self),sel);
    SAP_TRACE("native_manager","initializer_invoked",SAPTraceCurrentOperation(),@{@"scheduler_present":@(scheduler!=NULL),@"offline_manager_present":@(manager!=NULL)});
    // Raw pointers preserve the init method's retained-result/consumed-self ABI.
    void *result=originalInit(self,sel,scheduler,manager,sync,metadata);
    if(result) {
        nativeWrapper=(__bridge id)result;
        // Previously the track/duration quota was only raised on demand, from the
        // single-track probe button. Spotify's own playlist download UI never went
        // through that path, so it kept whatever small limit the account synced.
        // Apply the raise as soon as the native manager exists, before any download starts.
        requestQuotaRaise(@"native manager ready");
    }
    return result;
}
static BOOL methodSignature(Class cls,SEL sel,unsigned arguments,char returns,Method *out) {
    *out=class_getInstanceMethod(cls,sel);
    if(!*out||method_getNumberOfArguments(*out)!=arguments)return NO;
    char type[16];method_getReturnType(*out,type,sizeof(type));return type[0]==returns;
}
void SAPInstallNativeOffline(void) {
#if SAP_JAILBREAK
    extern NSDictionary *SAPJailbreakSupportReport(void);
    if(![SAPJailbreakSupportReport()[@"native_patches_ready"]boolValue])return;
#endif
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSInteger saved=[NSUserDefaults.standardUserDefaults integerForKey:keyModePreference];
        atomic_store_explicit(&requestedKeyMode,saved==1?1:0,memory_order_relaxed);
        Class cls=NSClassFromString(@"SPTOfflineManagerImplementation");
        if(!cls)return;
        SEL selector=NSSelectorFromString(@"initWithScheduler:offlineManager:syncManager:metadataModel:");
        Method method=class_getInstanceMethod(cls,selector);char type[16];
        if(method&&method_getNumberOfArguments(method)==6) {
            method_getReturnType(method,type,sizeof(type));
            if(type[0]=='@') {
                originalInit=(void *)method_getImplementation(method);
                class_replaceMethod(cls,selector,(IMP)captureInit,method_getTypeEncoding(method));hookInstalled=YES;
                SAPTraceRegisterHook(cls,selector,(IMP)captureInit,(IMP)originalInit);
            }
        }
        // Observes the exact call Spotify's playlist rows use to pick a download icon
        // (native-download-api.md: stateForTrackWithURL:, Q24@0:8@16). Read-only: the
        // original return value is always passed through unchanged.
        SEL stateSelector=NSSelectorFromString(@"stateForTrackWithURL:");Method stateMethod;
        if(methodSignature(cls,stateSelector,3,'Q',&stateMethod)) {
            originalStateForTrack=(void *)method_getImplementation(stateMethod);
            IMP replacement=imp_implementationWithBlock(^unsigned long long(id receiver,id url){
                SAPTraceHookCalled(object_getClass(receiver),stateSelector);
                unsigned long long result=originalStateForTrack(receiver,stateSelector,url);
                if(SAPDiagnosticsEnabled())SAPJournalNoteRowState(urlText(url),(NSUInteger)result);
                return result;
            });
            if(!class_addMethod(cls,stateSelector,replacement,method_getTypeEncoding(stateMethod)))
                class_replaceMethod(cls,stateSelector,replacement,method_getTypeEncoding(stateMethod));
            queueHookInstalled=YES;
            SAPTraceRegisterHook(cls,stateSelector,replacement,(IMP)originalStateForTrack);
        }
        // Кнопка «Скачать» на плейлисте/альбоме: полный список треков, которые Spotify
        // действительно отправил в офлайн (analysis/native-download-api.md).
        SEL entitySelector=NSSelectorFromString(@"makeEntityAvailableOfflineWithURL:trackURLs:");Method entityMethod;
        if(methodSignature(cls,entitySelector,4,'v',&entityMethod)) {
            originalMakeEntity=(void *)method_getImplementation(entityMethod);
            IMP replacement=imp_implementationWithBlock(^(id receiver,id url,id trackURLs){
                SAPTraceHookCalled(object_getClass(receiver),entitySelector);
                SAPTraceID trace=SAPTraceIsActive()?SAPTraceBegin(@"native_entity_download",@"spotify_ui",@{@"uri":urlText(url)?:@"",@"track_count":@([trackURLs isKindOfClass:NSArray.class]?[trackURLs count]:0)}):0;
                if(SAPDiagnosticsEnabled())SAPJournalNoteEntityRequest(urlText(url),trackURLs);
                SAP_JOURNAL_ACTION(@"native_entity_add_called",@{@"entity_uri":urlText(url)?:@"",
                    @"track_count":@([trackURLs isKindOfClass:NSArray.class]?[(NSArray *)trackURLs count]:0),
                    @"result_observed":@NO});
                SAPTraceWithOperation(trace,^{originalMakeEntity(receiver,entitySelector,url,trackURLs);});
                SAP_TRACE("native_entity","handler_returned",trace,@{@"download_completion_confirmed":@NO});
            });
            class_replaceMethod(cls,entitySelector,replacement,method_getTypeEncoding(entityMethod));entityHookInstalled=YES;
            SAPTraceRegisterHook(cls,entitySelector,replacement,(IMP)originalMakeEntity);
        }
        SEL entityOnly=NSSelectorFromString(@"makeEntityAvailableOfflineWithURL:");Method entityOnlyMethod;
        if(methodSignature(cls,entityOnly,3,'v',&entityOnlyMethod)) {
            originalMakeEntityOnly=(void *)method_getImplementation(entityOnlyMethod);
            IMP replacement=imp_implementationWithBlock(^(id receiver,id url){
                SAPTraceHookCalled(object_getClass(receiver),entityOnly);
                SAPTraceID trace=SAPTraceIsActive()?SAPTraceBegin(@"native_entity_download",@"spotify_ui",@{@"uri":urlText(url)?:@""}):0;
                if(SAPDiagnosticsEnabled())SAPJournalNoteEntityRequest(urlText(url),nil);
                SAP_JOURNAL_ACTION(@"native_entity_add_called",@{@"entity_uri":urlText(url)?:@"",
                    @"track_count":NSNull.null,@"result_observed":@NO});
                SAPTraceWithOperation(trace,^{originalMakeEntityOnly(receiver,entityOnly,url);});
                SAP_TRACE("native_entity","handler_returned",trace,@{@"download_completion_confirmed":@NO});
            });
            class_replaceMethod(cls,entityOnly,replacement,method_getTypeEncoding(entityOnlyMethod));
            SAPTraceRegisterHook(cls,entityOnly,replacement,(IMP)originalMakeEntityOnly);
        }
        SEL resetSelector=NSSelectorFromString(@"resetEntityOfflineAvailabilityWithURL:");Method resetMethod;
        if(methodSignature(cls,resetSelector,3,'v',&resetMethod)) {
            originalResetEntity=(void *)method_getImplementation(resetMethod);
            IMP replacement=imp_implementationWithBlock(^(id receiver,id url){
                SAPTraceHookCalled(object_getClass(receiver),resetSelector);
                SAPTraceID trace=SAPTraceIsActive()?SAPTraceBegin(@"native_entity_remove",@"spotify_ui",@{@"uri":urlText(url)?:@""}):0;
                if(SAPDiagnosticsEnabled())SAPJournalNoteEntityReset(urlText(url));
                SAP_JOURNAL_ACTION(@"native_entity_remove_called",@{@"entity_uri":urlText(url)?:@"",
                    @"result_observed":@NO});
                SAPTraceWithOperation(trace,^{originalResetEntity(receiver,resetSelector,url);});
                SAP_TRACE("native_entity","handler_returned",trace,@{@"removal_completion_confirmed":@NO});
            });
            class_replaceMethod(cls,resetSelector,replacement,method_getTypeEncoding(resetMethod));
            SAPTraceRegisterHook(cls,resetSelector,replacement,(IMP)originalResetEntity);
        }
        // Значок, который получает строка списка: 0 нет, 1 ожидание, 2 идёт, 3 скачан, 4 ошибка.
        Class iconClass=NSClassFromString(@"SPTFreeTierOfflineStatusUpdatingContentOperation");
        SEL iconSelector=NSSelectorFromString(@"offlineSyncStatusForURL:");Method iconMethod;
        if(iconClass&&methodSignature(iconClass,iconSelector,3,'q',&iconMethod)) {
            originalSyncStatus=(NSInteger (*)(id,SEL,id))method_getImplementation(iconMethod);
            IMP replacement=imp_implementationWithBlock(^NSInteger(id receiver,id url){
                SAPTraceHookCalled(object_getClass(receiver),iconSelector);
                NSInteger status=originalSyncStatus(receiver,iconSelector,url);
                if(SAPDiagnosticsEnabled())SAPJournalNoteUIStatus(urlText(url),status);
                return status;
            });
            if(!class_addMethod(iconClass,iconSelector,replacement,method_getTypeEncoding(iconMethod)))
                class_replaceMethod(iconClass,iconSelector,replacement,method_getTypeEncoding(iconMethod));
            iconHookInstalled=YES;
            SAPTraceRegisterHook(iconClass,iconSelector,replacement,(IMP)originalSyncStatus);
        }
        // Spotify can resync the real server-granted quota later (e.g. after a restrictions
        // refresh) and lower it again; these two cheap, bounded re-checks catch that instead
        // of leaving the raise as a one-shot applied only at launch.
        dispatch_async(dispatch_get_main_queue(),^{
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                requestQuotaRaise(@"foreground");
            }];
        });
        // Sampling is read-only, every 30 seconds while a journal session is active.
        // No permanent quota timer and no periodic setter invocation.
        SAPJournalSetQuotaSampler(^{SAPSampleNativeOffline();});
    });
}
BOOL SAPSubmitNativeAlbumDownload(NSString *albumURI,NSArray<NSString *> *trackURIs,NSString **reason) {
    SAPInstallNativeOffline();
    id wrapper=nativeWrapper;NSString *failure=nil;
    SAP_JOURNAL_ACTION(@"artist_native_album_handler_requested",@{@"album_uri":albumURI?:@"",@"track_count":@(trackURIs.count),@"automatic_replay":@NO});
    BOOL returned=SAPInvokeNativeAlbumCommand(wrapper,albumURI,trackURIs,&failure);
    SAP_JOURNAL_ACTION(@"artist_native_album_handler_returned",@{@"album_uri":albumURI?:@"",@"handler_returned":@(returned),
        @"track_count":@(trackURIs.count),@"download_completion_confirmed":@NO,@"error":failure?:@""});
    if(reason)*reason=failure;return returned;
}
BOOL SAPResetNativeEntityDownload(NSString *uri,NSString **reason) {
    if(!NSThread.isMainThread){if(reason)*reason=@"The native reset action requires the main thread.";return NO;}
    SAPInstallNativeOffline();
    id wrapper=nativeWrapper;
    SEL selector=NSSelectorFromString(@"resetEntityOfflineAvailabilityWithURL:");
    NSURL *url=[uri isKindOfClass:NSString.class]?[NSURL URLWithString:uri]:nil;
    Method method=class_getInstanceMethod(object_getClass(wrapper),selector);char type[16]={0};
    if(!wrapper||![uri hasPrefix:@"spotify:album:"]||uri.length!=36||!url||!method||method_getNumberOfArguments(method)!=3) {
        if(reason)*reason=@"The native album reset method is unavailable.";return NO;
    }
    method_getReturnType(method,type,sizeof(type));BOOL valid=type[0]=='v';
    method_getArgumentType(method,2,type,sizeof(type));valid=valid&&type[0]=='@';
    if(!valid){if(reason)*reason=@"The native album reset signature does not match.";return NO;}
    @try {((void(*)(id,SEL,id))objc_msgSend)(wrapper,selector,url);}
    @catch(NSException *exception){if(reason)*reason=exception.name;return NO;}
    return YES;
}
void SAPPrepareNativeOffline(BOOL (^stillRequested)(void),void (^completion)(BOOL,NSString *)) {
    SAPInstallNativeOffline();
    SAPNativePreparation *operation=[SAPNativePreparation new];operation.completion=completion;operation.traceOperation=SAPTraceCurrentOperation();
    id wrapper=nativeWrapper;
    if(!wrapper) { [operation finish:NO reason:SAPL(@"Нативный менеджер загрузки ещё не получен. Начни воспроизведение и повтори.",@"The native download manager is not available yet. Start playback and try again.") report:nil];return; }
    SEL schedulerSelector=NSSelectorFromString(@"scheduler"),post=NSSelectorFromString(@"postBlock:");
    id scheduler=((id(*)(id,SEL))objc_msgSend)(wrapper,schedulerSelector);
    if(!scheduler||![scheduler respondsToSelector:post]) { [operation finish:NO reason:SAPL(@"Очередь нативного менеджера загрузки недоступна.",@"The native download manager queue is unavailable.") report:nil];return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        [operation finish:NO reason:SAPL(@"Менеджер загрузки не ответил за 5 секунд. Запрос скачивания не отправлен.",@"The download manager did not reply within 5 seconds. No download request was sent.") report:nil];
    });
    ((void(*)(id,SEL,id))objc_msgSend)(scheduler,post,^{
        if(operation.finished)return;
        if(stillRequested&&!stillRequested()) { [operation finish:NO reason:SAPL(@"Подготовка отменена.",@"Preparation cancelled.") report:nil];return; }
        void *manager=NULL;uintptr_t image=0;NSMutableDictionary *before=[NSMutableDictionary dictionary];
        // The app's invalidate method clears wrapper+8. Read it only on its queue.
        if(!nativeState(wrapper,&manager,&image,before)) { [operation finish:NO reason:SAPL(@"Нативный менеджер завершён или сборка Spotify не совпадает с проверенной версией.",@"The native manager has shut down, or this Spotify build does not match the verified version.") report:nil];return; }
        // v16: previously only raised the quota when it was exactly (0,0) — the
        // "never synced" sentinel. A real account can sync a small nonzero limit
        // (this is what capped the user's playlist download after a handful of
        // tracks: current_tracks reached music_limit and new reservations started
        // returning TOO_MANY_TRACKS=19). Now raise whenever it's below the target,
        // and never lower an existing higher value.
        const int32_t desiredDurationSeconds=SAPMinimumMusicDurationSeconds, desiredTrackLimit=SAPMinimumTrackLimit;
        BOOL changed=[before[@"music_limit"] intValue]<desiredTrackLimit || [before[@"music_duration_seconds"] longLongValue]<desiredDurationSeconds;
        if(changed) {
            int32_t newDuration=(int32_t)MAX([before[@"music_duration_seconds"] longLongValue],(long long)desiredDurationSeconds);
            int32_t newTrackLimit=(int32_t)MAX([before[@"music_limit"] intValue],desiredTrackLimit);
            ((void(*)(void *,int32_t,int32_t,int32_t,int32_t,int32_t))(image+setterOffset))(manager,newDuration,newTrackLimit,[before[@"episode_duration_seconds"] intValue],[before[@"episode_limit"] intValue],[before[@"abp_duration_seconds"] intValue]);
        }
        NSMutableDictionary *after=[NSMutableDictionary dictionary];
        BOOL stateValid=nativeState(wrapper,&manager,&image,after);
        NSDictionary *assessment=SAPAssessNativeSetup(after,stateValid);
        [after addEntriesFromDictionary:assessment];
        BOOL ready=[assessment[@"local_prepared"]boolValue];
        BOOL valuesChanged=![[before objectForKey:@"music_limit"]isEqual:[after objectForKey:@"music_limit"]] ||
            ![[before objectForKey:@"music_duration_seconds"]isEqual:[after objectForKey:@"music_duration_seconds"]];
        after[@"quota_setter_invoked"]=@(changed);after[@"quota_values_changed"]=@(valuesChanged);
        [operation finish:ready reason:ready?assessment[@"reason"]:[assessment[@"reason"] stringByAppendingString:@"\nNo download request was sent."] report:
            @{@"before":before,@"after":after,@"changed":@(valuesChanged),@"setter_invoked":@(changed),@"native_queue":@YES}];
    });
}
void SAPReadNativeOfflineQuota(void (^completion)(NSDictionary *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPReadNativeOfflineQuota(completion);});return;}
    SAPInstallNativeOffline();
    id wrapper=nativeWrapper;
    SEL get=NSSelectorFromString(@"scheduler"),post=NSSelectorFromString(@"postBlock:");
    id scheduler=[wrapper respondsToSelector:get]?((id(*)(id,SEL))objc_msgSend)(wrapper,get):nil;
    if(!scheduler || ![scheduler respondsToSelector:post]) {
        if(completion)completion(@{@"read_status":@"unavailable",@"error":@"Native manager queue is unavailable"});return;
    }
    __block BOOL finished=NO;__block dispatch_source_t timeout;
    void (^finish)(NSDictionary *)=^(NSDictionary *result){
        if(finished)return;finished=YES;
        if(timeout){dispatch_source_cancel(timeout);timeout=nil;}
        if(completion)completion(result);
    };
    timeout=SAPScheduleDeadline(dispatch_get_main_queue(),5,^{finish(@{@"read_status":@"timeout",@"error":@"Native manager did not answer within 5 seconds"});});
    ((void(*)(id,SEL,id))objc_msgSend)(scheduler,post,^{
        NSMutableDictionary *result=[NSMutableDictionary dictionary];void *manager=NULL;uintptr_t image=0;
        BOOL valid=wrapper==nativeWrapper && nativeState(wrapper,&manager,&image,result);
        [result addEntriesFromDictionary:SAPAssessNativeSetup(result,valid)];
        result[@"read_status"]=valid?@"received":@"invalid";
        result[@"observed_at"]=@(NSDate.date.timeIntervalSince1970);result[@"read_only"]=@YES;
        if(!valid)result[@"error"]=@"Native manager identity or state could not be verified";
        dispatch_async(dispatch_get_main_queue(),^{finish(result);});
    });
}
void SAPReadNativeTrackState(NSString *uri) {
    id wrapper=nativeWrapper;
    if(!wrapper || !originalStateForTrack || ![uri hasPrefix:@"spotify:track:"])return;
    // This public wrapper uses scheduler.runBlock: internally. Call it as the UI
    // does, outside that scheduler; never nest a synchronous runBlock inside postBlock.
    void (^read)(void)=^{
        if(wrapper!=nativeWrapper)return;
        NSUInteger legacy=originalStateForTrack(wrapper,NSSelectorFromString(@"stateForTrackWithURL:"),[NSURL URLWithString:uri]);
        SAPJournalNoteRowState(uri,legacy);
    };
    if(NSThread.isMainThread)read();else dispatch_async(dispatch_get_main_queue(),read);
}

void SAPSampleNativeOffline(void) {
    id wrapper=nativeWrapper;
    if(!wrapper) {SAPJournalNoteQuota(@{@"local_prepared":@NO,@"authorization_checked":@NO,@"reason":@"read-only: manager unavailable"});return;}
    SEL getScheduler=NSSelectorFromString(@"scheduler"),post=NSSelectorFromString(@"postBlock:");
    if(![wrapper respondsToSelector:getScheduler])return;
    id scheduler=((id(*)(id,SEL))objc_msgSend)(wrapper,getScheduler);
    if(![scheduler respondsToSelector:post])return;
    ((void(*)(id,SEL,id))objc_msgSend)(scheduler,post,^{
        void *manager=NULL;uintptr_t image=0;NSMutableDictionary *value=[NSMutableDictionary dictionary];
        BOOL valid=nativeState(wrapper,&manager,&image,value);value[@"valid"]=@(valid);
        [value addEntriesFromDictionary:SAPAssessNativeSetup(value,valid)];
        value[@"sample_source"]=@"read_only_native_manager";
        SAPJournalNoteQuota(value);
    });
}
NSDictionary *SAPNativeOfflineReport(void) {
    os_unfair_lock_lock(&stateLock);NSDictionary *state=snapshot;os_unfair_lock_unlock(&stateLock);
    NSMutableDictionary *out=[state mutableCopy]?:[NSMutableDictionary dictionary];
    out[@"hook_installed"]=@(hookInstalled);out[@"wrapper_available"]=@(nativeWrapper!=nil);
    out[@"queue_hook_installed"]=@(queueHookInstalled);out[@"entity_hook_installed"]=@(entityHookInstalled);
    out[@"icon_hook_installed"]=@(iconHookInstalled);
    out[@"key_request_mode"]=SAPKeyRequestModeReport();
    return out;
}
#ifdef SAP_RUNTIME_TESTING
id SAPNativeOfflineWrapperForTesting(void) { return nativeWrapper; }
void SAPNativeOfflineSnapshotForTesting(void (^completion)(NSDictionary *)) {
    id wrapper=nativeWrapper;
    id scheduler=((id(*)(id,SEL))objc_msgSend)(wrapper,NSSelectorFromString(@"scheduler"));
    ((void(*)(id,SEL,id))objc_msgSend)(scheduler,NSSelectorFromString(@"postBlock:"),^{
        NSMutableDictionary *state=[NSMutableDictionary dictionary];void *manager=NULL;uintptr_t image=0;
        state[@"valid"]=@(nativeState(wrapper,&manager,&image,state));
        // Test-only identity lookup: inspect executable pointers, never key data.
        uintptr_t provider=0,table=0,request=0;
        if(manager && readMemory((uintptr_t)manager+0x290,&provider,sizeof(provider)) &&
            readMemory(provider,&table,sizeof(table)) && readMemory(table+0x10,&request,sizeof(request))) {
            Dl_info tableInfo={0},requestInfo={0};
            if(dladdr((void *)table,&tableInfo) && (uintptr_t)tableInfo.dli_fbase==image)
                state[@"key_provider_vtable_va"]=[NSString stringWithFormat:@"0x%llx",(unsigned long long)(table-image+UINT64_C(0x100000000))];
            if(dladdr((void *)request,&requestInfo) && (uintptr_t)requestInfo.dli_fbase==image)
                state[@"key_provider_request_va"]=[NSString stringWithFormat:@"0x%llx",(unsigned long long)(request-image+UINT64_C(0x100000000))];
        }
        dispatch_async(dispatch_get_main_queue(),^{completion(state);});
    });
}
void SAPNativeOfflineZeroUpdateForTesting(void (^completion)(NSDictionary *)) {
    id wrapper=nativeWrapper;if(!wrapper){completion(@{@"error":@"no wrapper"});return;}
    id scheduler=((id(*)(id,SEL))objc_msgSend)(wrapper,NSSelectorFromString(@"scheduler"));
    ((void(*)(id,SEL,id))objc_msgSend)(scheduler,NSSelectorFromString(@"postBlock:"),^{
        NSMutableDictionary *before=[NSMutableDictionary dictionary];void *manager=NULL;uintptr_t image=0;
        BOOL guarded=nativeState(wrapper,&manager,&image,before)&&[before[@"restriction_guard_active"] boolValue];
        if(guarded)((void(*)(void *,int32_t,int32_t,int32_t,int32_t,int32_t))(image+setterOffset))
            (manager,0,0,[before[@"episode_duration_seconds"] intValue],[before[@"episode_limit"] intValue],[before[@"abp_duration_seconds"] intValue]);
        NSMutableDictionary *after=[NSMutableDictionary dictionary];BOOL valid=nativeState(wrapper,&manager,&image,after);
        NSDictionary *result=@{@"guarded":@(guarded),@"zero_update_tested":@(guarded),@"before":before,@"after":after,@"valid":@(valid)};
        dispatch_async(dispatch_get_main_queue(),^{completion(result);});
    });
}
#endif
