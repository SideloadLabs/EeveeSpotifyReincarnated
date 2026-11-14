#include "TargetProfile.h"
#include "NativeTracePatch.h"
#include "NativeRestrictionsPatch.h"
#import "TracePlatform.h"
#import "DiagnosticTrace.h"
#import "NativeOffline.h"
#import "NativeKeyTrace.h"
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <Network/Network.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdatomic.h>
#import "BuildIdentity.h"
#include <sys/sysctl.h>

static NSMutableArray *observers;
static nw_path_monitor_t monitor;
static atomic_uint platformGeneration;
static NSDictionary *route(void) {
    NSMutableArray *outputs=[NSMutableArray array];
    for(AVAudioSessionPortDescription *p in AVAudioSession.sharedInstance.currentRoute.outputs)[outputs addObject:@{@"type":p.portType?:@"unknown",@"channels":@(p.channels.count)}];
    return @{@"outputs":outputs,@"local_audio_output_only":@YES,@"spotify_connect_destination_proven":@NO};
}
static NSString *hex(const uint8_t *bytes,NSUInteger count) {NSMutableString *s=[NSMutableString stringWithCapacity:count*2];for(NSUInteger i=0;i<count;i++)[s appendFormat:@"%02x",bytes[i]];return s;}
static NSArray *criticalSamples(uintptr_t base,NSString *uuid) {
    if(![uuid isEqual:@SAP_SPOTIFY_UUID_HEX])return @[];
    static const struct {const char *name;uintptr_t offset;size_t length;} points[]={
        {"key_request_call_site",SAPTraceRequestOffset,16},{"key_request_observer",SAPTraceRequestCaveOffset,sizeof(SAPTraceRequestCode)},
        {"key_success_entry",SAPTraceSuccessOffset,16},{"key_success_observer",SAPTraceSuccessCaveOffset,sizeof(SAPTraceSuccessCode)},
        {"key_failure_entry",SAPTraceFailureOffset,16},{"key_failure_observer",SAPTraceFailureCaveOffset,sizeof(SAPTraceFailureCode)},
        {"quota_setter_entry",SAP_TARGET_SETTER-UINT64_C(0x100000000),16},{"quota_guard",SAPRestrictionCaveOffset,52},
        {"native_key_provider_entry",SAP_TARGET_PROVIDER-UINT64_C(0x100000000),16}
    };
    NSMutableArray *samples=[NSMutableArray array];
    for(unsigned i=0;i<sizeof(points)/sizeof(points[0]);i++) {
        uint8_t bytes[256],digest[CC_SHA256_DIGEST_LENGTH];vm_size_t copied=0;
        kern_return_t status=vm_read_overwrite(mach_task_self(),base+points[i].offset,points[i].length,(vm_address_t)bytes,&copied);
        NSMutableDictionary *sample=[@{@"name":@(points[i].name),@"image_offset":[NSString stringWithFormat:@"0x%lx",(unsigned long)points[i].offset],
            @"requested_bytes":@(points[i].length),@"read_status":@(status),@"read_bytes":@(copied),@"scope":@"loaded code bytes; not a whole-file hash"}mutableCopy];
        if(status==KERN_SUCCESS&&copied==points[i].length){CC_SHA256(bytes,(CC_LONG)copied,digest);sample[@"sha256"]=hex(digest,sizeof(digest));sample[@"hex"]=hex(bytes,copied);}
        [samples addObject:sample];
    }
    return samples;
}
void SAPTraceCaptureRuntimeManifest(const char *reason) {
    if(!SAPTraceIsActive())return;
    NSMutableArray *images=[NSMutableArray array];
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char *name=_dyld_get_image_name(i);if(!name)continue;NSString *path=@(name),*base=path.lastPathComponent;
        if(![@[@"Spotify",@"SpotifyAudioProbe.dylib",@"spotifyglass.dylib",@"EeveeSpotify.dylib",@"LiveContainer"]containsObject:base])continue;
        const struct mach_header_64 *h=(void *)_dyld_get_image_header(i);if(h->magic!=MH_MAGIC_64||h->sizeofcmds>1048576||h->ncmds>1024)continue;
        const uint8_t *cursor=(void *)(h+1),*end=cursor+h->sizeofcmds;NSString *uuid=@"unavailable";NSMutableDictionary *fingerprints=[NSMutableDictionary dictionary];
        for(unsigned n=0;n<h->ncmds && cursor+sizeof(struct load_command)<=end;n++) {
            const struct load_command *c=(void *)cursor;if(c->cmdsize<8||cursor+c->cmdsize>end)break;
            if(c->cmd==LC_UUID&&c->cmdsize>=sizeof(struct uuid_command))uuid=hex(((struct uuid_command *)c)->uuid,16);
            if(c->cmd==LC_SEGMENT_64&&c->cmdsize>=sizeof(struct segment_command_64)) {
                const struct segment_command_64 *s=(void *)c;
                if(!strncmp(s->segname,"__TEXT",16)&&s->filesize>=sizeof(*h)+h->sizeofcmds) {
                    // This is explicitly a bounded loaded-memory sample, not a full-file hash.
                    NSUInteger length=MIN((uint64_t)65536,s->filesize-sizeof(*h)-h->sizeofcmds);uint8_t digest[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(h+1,(CC_LONG)MIN(length,h->sizeofcmds),digest);
                    fingerprints[@"load_commands_sample_sha256"]=hex(digest,sizeof(digest));fingerprints[@"sample_bytes"]=@(MIN(length,h->sizeofcmds));
                }
            }cursor+=c->cmdsize;
        }
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[[path stringByDeletingLastPathComponent]stringByAppendingPathComponent:@"Info.plist"]];
        NSMutableDictionary *image=[@{@"path":path,@"name":base,@"uuid":uuid,@"fingerprints":fingerprints,@"cpu_subtype":@(h->cpusubtype),@"mach_file_type":@(h->filetype)}mutableCopy];
        if([base isEqual:@"Spotify"])image[@"critical_loaded_code_samples"]=criticalSamples((uintptr_t)h,uuid);
        if(info[@"CFBundleIdentifier"])image[@"bundle_identifier"]=info[@"CFBundleIdentifier"];
        if(info[@"CFBundleShortVersionString"])image[@"declared_version"]=info[@"CFBundleShortVersionString"];
        [images addObject:image];
    }
    SAP_TRACE("runtime","manifest",0,@{@"reason":reason?@(reason):@"unknown",@"images":images,@"hooks":SAPTraceHookManifest(),@"key_mode":SAPKeyRequestModeReport(),
        @"pixie_revision":@SAP_BUILD_REVISION,@"vitrine_source_commit":@SAP_VITRINE_SOURCE_COMMIT,
        @"native_key_boundaries":SAPNativeKeyTraceReport(),
        @"os_version":NSProcessInfo.processInfo.operatingSystemVersionString,@"foreground_state":@(UIApplication.sharedApplication.applicationState),
        @"low_power_mode":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"route":route(),@"pre_library_calls_observed":@NO});
}
void SAPTracePlatformSetActive(bool enabled) {
    unsigned expected=atomic_fetch_add(&platformGeneration,1)+1;
    dispatch_async(dispatch_get_main_queue(),^{
        if(expected!=atomic_load(&platformGeneration))return;
        for(id token in observers)[NSNotificationCenter.defaultCenter removeObserver:token];observers=nil;
        if(monitor){nw_path_monitor_cancel(monitor);monitor=nil;}
        if(!enabled||!SAPTraceIsActive())return;
        observers=[NSMutableArray array];
        for(NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification,UIApplicationDidBecomeActiveNotification,UIApplicationWillResignActiveNotification,
             UIApplicationDidEnterBackgroundNotification,UIApplicationWillEnterForegroundNotification,UIApplicationWillTerminateNotification,
             UIApplicationProtectedDataWillBecomeUnavailable,UIApplicationProtectedDataDidBecomeAvailable,AVAudioSessionRouteChangeNotification,AVAudioSessionInterruptionNotification,NSProcessInfoPowerStateDidChangeNotification]) {
            id token=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                if(expected!=atomic_load(&platformGeneration)||!SAPTraceIsActive())return;
                SAP_TRACE("lifecycle","notification",0,@{@"name":note.name,@"application_state":@(UIApplication.sharedApplication.applicationState),@"route":route(),
                    @"route_change_reason":note.userInfo[AVAudioSessionRouteChangeReasonKey]?:NSNull.null,@"interruption_type":note.userInfo[AVAudioSessionInterruptionTypeKey]?:NSNull.null});
            }];[observers addObject:token];
        }
        monitor=nw_path_monitor_create();nw_path_monitor_set_queue(monitor,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        nw_path_monitor_set_update_handler(monitor,^(nw_path_t path){
            if(expected!=atomic_load(&platformGeneration)||!SAPTraceIsActive())return;
            SAP_TRACE("network","path_observed",0,@{@"status":@(nw_path_get_status(path)),@"wifi":@(nw_path_uses_interface_type(path,nw_interface_type_wifi)),
                @"cellular":@(nw_path_uses_interface_type(path,nw_interface_type_cellular)),@"wired":@(nw_path_uses_interface_type(path,nw_interface_type_wired)),
                @"expensive":@(nw_path_is_expensive(path)),@"constrained":@(nw_path_is_constrained(path)),@"endpoint_reachability_proven":@NO});
        });nw_path_monitor_start(monitor);SAPTraceCaptureRuntimeManifest("diagnostics_start");
    });
}
