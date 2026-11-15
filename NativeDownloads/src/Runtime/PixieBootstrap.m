#import "Localization.h"
#import "SupportLog.h"
#import "DownloadCompatibility.h"
#import "OfflineDevices.h"
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <dlfcn.h>
#import "AudioProbe.h"
#import "SourceGraph.h"
#import "OfflineFlags.h"
#import "TrackDownload.h"
#import "OfflineConfig.h"
#import "NativeOffline.h"
#import "TrackJournal.h"
#import "AudioProbeUI.h"
#import "Diagnostics.h"
#import "DiagnosticTrace.h"
#import "TracePlatform.h"
#import "NativeKeyTrace.h"
#import "TrackExport.h"
#import "NativeShareHooks.h"
#import "PlayerTrace.h"
#import "NativeErrorLog.h"
#import "BuildIdentity.h"
#import "NativeDownloadQuality.h"
#import "ProcessScope.h"
#import "ArtistPageButton.h"
#if SAP_JAILBREAK
#import "JailbreakSupport.h"
#endif

// Install the host backend once, preserving the original initialization order.
__attribute__((constructor)) static void SAPLoad(void) {
    @autoreleasepool {
        NSBundle *host=NSBundle.mainBundle;
        if(SAPIsAppExtensionProcess(host.infoDictionary,host.bundlePath))return;
#if SAP_JAILBREAK
        bool nativeReady=SAPInstallJailbreakSupport();
#else
        bool nativeReady=true;
#endif
        SAPInstallNativeDownloadQualityObservation();
        SAPDiagnosticsInitialize();
        if(SAPDiagnosticsEnabled()){SAPPlayerTraceSetActive(YES);SAPNativeErrorLogSetActive(YES);}
        [NSNotificationCenter.defaultCenter addObserverForName:SAPDiagnosticsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note){
            SAPPlayerTraceSetActive(SAPDiagnosticsEnabled());SAPNativeErrorLogSetActive(SAPDiagnosticsEnabled());
        }];
        if(nativeReady) {
        SpotifyAudioProbeInitialize();
        SAPInstallAVHooks();
        SAPInstallOfflineFlags();
        SAPInstallOfflineConfig();
        SAPInstallNativeOffline();
        SAPInstallTrackDownloader();
        SAPSetOfflineKeySuccessObserver(SAPExportObserveOfflineSuccess);
        }
        SAP_TRACE("startup","pixie_hooks_installed",0,@{@"offline_flags":SAPOfflineFlagsReport(),@"offline_config":SAPOfflineConfigReport(),@"native_offline":SAPNativeOfflineReport(),@"transport":SAPTrackDownloadReport(),@"hooks":SAPTraceHookManifest()});
        dispatch_async(dispatch_get_main_queue(), ^{ SAPInstallDownloadSettings();SAPInstallNativeShareHooks();SAPInstallArtistPageButton(); });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){SAPInstallDownloadSettings();SAPInstallArtistPageButton();}];
    }
}
