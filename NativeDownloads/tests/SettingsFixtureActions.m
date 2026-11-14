#import <UIKit/UIKit.h>
#import "AudioProbeUI.h"
#import "OfflineDevices.h"
static BOOL fixtureSourceMismatch;
@implementation SAPSettingsActions
+ (NSDictionary *)snapshot {
#ifdef SAP_VITRINE_FIXTURE
 BOOL unsupported=[NSProcessInfo.processInfo.arguments containsObject:@"--unsupported"];
 return @{@"download_active":@NO,@"key_request_mode":@{@"configured_mode":unsupported?@(-1):@0,@"configuration_source":unsupported?@"unverified":@"verified_direct_instruction"},
   @"jailbreak_bootstrap":@{@"native_patches_ready":@(!unsupported),@"reason":unsupported?@"unsupported_image":@"applied",@"detected_spotify_version":unsupported?@"9.1.92":@"9.1.90"}};
#else
 return @{@"report":@{@"track_journal":@{@"state_counts":@{@"downloaded":@118,@"downloading":@2,@"waiting":@1,@"awaiting_redownload":@3,@"error":@4,@"waiting_limit_exceeded":@5,@"not_downloaded":@6,@"expired":@7}}},@"diagnostics":@"Audio diagnostics disabled",@"journal_summary":@"Downloaded: 118\nWaiting: 0\nErrors: 0",@"download_active":@NO,@"key_request_mode":@{@"selected_mode":@0,@"configured_mode":@0,@"configuration_source":@"verified_direct_instruction",@"last_selector_returned_mode":@(-1),@"runtime_selection_supported":@YES,@"restart_required":@NO,@"detail":@"Mode 0 is verified in the executable. This status does not confirm download authorization."}};
#endif
}
+ (NSDictionary *)snapshotForDetails:(BOOL)journal {return [self snapshot];}
+ (void)loadDetails:(BOOL)journal completion:(void (^)(NSDictionary *))completion {dispatch_async(dispatch_get_main_queue(),^{completion([self snapshot]);});}
+ (void)perform:(SAPSettingsAction)action { }
+ (void)setKeyRequestMode:(NSInteger)mode completion:(void (^)(BOOL,NSString *))completion {NSCAssert(mode==0,@"Selecting mode 1 must not be offered");if(completion)completion(NO,@"Spotify reports 0 free device-license slots. Mode was not changed.");}
+ (void)refreshDownloadCompatibility:(void (^)(NSDictionary *))completion {if(completion)completion(@{@"status":@"complete"});}
+ (void)previewOfflineDeviceSlots:(void (^)(NSDictionary *,NSString *))completion {completion(nil,@"fixture: no mutation performed");}
+ (void)releaseOfflineDeviceSlots:(NSString *)planID cacheIDs:(NSArray *)cacheIDs completion:(void (^)(NSDictionary *,NSString *))completion {completion(nil,@"fixture: no mutation performed");}
+ (void)enableOfflineOnCurrentDevice:(void (^)(NSDictionary *,NSString *))completion {completion(nil,@"fixture: no mutation performed");}
@end
void SAPJournalNoteAction(NSString *name,NSDictionary *facts) {}
NSString *SAPDownloadCompatibilityText(NSDictionary *report) {return @"Device licenses: 0 of 5 free. Mode was not changed.";}

// SAPFixtureChrome: stand-in for Spotify's existing mini-player controller.
@interface _TtC18NowPlaying_BarImpl27NowPlayingBarViewController : UIViewController @end
@implementation _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLoad {
 [super viewDidLoad];self.view.backgroundColor=[UIColor colorWithRed:0.22 green:0.08 blue:0.15 alpha:1];self.view.layer.cornerRadius=8;
 UILabel *label=[UILabel new];label.text=@"   Текущий трек · мини-плеер                 ▶";label.textColor=UIColor.whiteColor;
 label.frame=CGRectMake(0,0,430,56);label.autoresizingMask=UIViewAutoresizingFlexibleWidth;[self.view addSubview:label];
}
@end

@protocol SPTPageController <NSObject>
- (NSString *)spt_pageIdentifier;
- (NSURL *)spt_pageURI;
@end
@protocol _TtP19Tome_PageAttributes17SPTPageController_ <NSObject>
- (NSString *)spt_pageIdentifier;
- (NSURL *)spt_pageURI;
@end
__attribute__((constructor)) static void SAPFixtureRegisterProtocols(void) {
 (void)[NSObject conformsToProtocol:@protocol(SPTPageController)];
 (void)[NSObject conformsToProtocol:@protocol(_TtP19Tome_PageAttributes17SPTPageController_)];
}

void SAPPreviewOfflineDeviceSlots(void (^completion)(NSDictionary *,NSString *)) {
    NSDictionary *current=@{@"device_id":@"this-device",@"cache_id":@"this-cache",@"name":@"iPhone",@"offline_enabled":@NO,@"is_current_device":@YES,@"selection_token":@"current-token"};
    NSDictionary *old=@{@"device_id":@"old-device",@"cache_id":@"old-cache",@"name":@"iPhone",@"offline_enabled":@YES,@"is_current_device":@NO,@"selection_token":@"old-token"};
    NSDictionary *older=@{@"device_id":@"historical-device",@"cache_id":@"historical-cache",@"name":@"Historical iPhone",@"offline_enabled":@NO,@"is_current_device":@NO,@"selection_token":@"historical-token"};
    NSDictionary *other=@{@"device_id":@"other-device",@"cache_id":@"other-cache",@"name":@"iPhone",@"offline_enabled":@YES,@"is_current_device":@NO,@"selection_token":@"other-token"};
    BOOL mismatch=fixtureSourceMismatch;fixtureSourceMismatch=NO;
    completion(@{@"id":@"fixture-plan",@"created_at":@(NSDate.date.timeIntervalSince1970),@"devices":@[older,old,current,other],@"free_licenses":@3,@"max_licenses":@5,@"native_read_status":@"complete",@"direct_read_status":@"received",@"quota_source":@"direct",@"actions_allowed":@(!mismatch)},mismatch?@"Native and direct sources disagree. Snapshot is read only.":nil);
}
void SAPDisableOfflineDevice(NSString *plan,NSString *token,void (^completion)(NSDictionary *,NSString *)) {completion(nil,@"Fixture: no mutation performed.");}
void SAPEnableOfflineOnCurrentDevice(void (^completion)(NSDictionary *,NSString *)) {fixtureSourceMismatch=YES;completion(nil,@"Fixture: no mutation performed.");}
