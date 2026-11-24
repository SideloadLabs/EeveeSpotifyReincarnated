#import "Localization.h"
#import "DownloadCompatibility.h"
#import "OfflineDevices.h"
#import "TrackExport.h"
#import "OfflineLibraryUI.h"
#import "OfflineLibraryCatalog.h"
#import "NativeDownloadQuality.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "AudioProbeUI.h"
#import "Diagnostics.h"
#import "DiagnosticTrace.h"
#import "TrackJournal.h"
#import "TargetProfile.h"
#import "GitHubIcon.h"
#import "PixiePageController.h"
#include <math.h>

static NSString *const SAPUIChanged=@"SAPDownloadSettingsChanged";
static const void *SAPAttachmentKey=&SAPAttachmentKey;
static void *SAPContentSizeContext=&SAPContentSizeContext;
static void (*originalSettingsLoad)(id,SEL);
static void (*originalSettingsLayout)(id,SEL);
static BOOL settingsInstalled;
static NSString *settingsInstallStatus=@"not_attempted";
NSDictionary *SAPDownloadSettingsInstallReport(void) {
    return @{@"installed":@(settingsInstalled),@"status":settingsInstallStatus};
}

// Resolve Spotify's bottom chrome once per page. Layout callbacks only read
// the cached views' current geometry; there is no timer or playback hook.
@interface SAPBottomChrome : NSObject
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic,strong) NSHashTable<UIView *> *views;
- (CGFloat)coveredBottomOfScroll:(UIScrollView *)scroll;
@end
@implementation SAPBottomChrome
- (void)collect:(UIViewController *)controller depth:(unsigned)depth {
    if(depth>20 || !controller)return;
    NSString *name=NSStringFromClass(controller.class);
    if([name isEqual:@"NowPlaying_BarImpl.NowPlayingBarContainerViewController"] ||
       [name isEqual:@"NowPlaying_BarImpl.NowPlayingBarViewController"] ||
       [name isEqual:@"_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController"] ||
       [name isEqual:@"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController"])
        if(controller.isViewLoaded)[self.views addObject:controller.view];
    if([controller isKindOfClass:UITabBarController.class])
        [self.views addObject:((UITabBarController *)controller).tabBar];
    if([name isEqual:@"NavigationUI_TabBarImpl.TabBarContainerImpl"] ||
       [name isEqual:@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"]) {
        SEL selector=NSSelectorFromString(@"tabBarView");
        if([controller respondsToSelector:selector]) {
            id bar=((id(*)(id,SEL))objc_msgSend)(controller,selector);
            if([bar isKindOfClass:UIView.class])[self.views addObject:bar];
        }
    }
    for(UIViewController *child in controller.childViewControllers)[self collect:child depth:depth+1];
}
- (CGFloat)coveredBottomOfScroll:(UIScrollView *)scroll {
    UIWindow *window=scroll.window;if(!window)return 0;
    if(self.window!=window) {
        self.window=window;self.views=[NSHashTable weakObjectsHashTable];
        [self collect:window.rootViewController depth:0];
    }
    CGRect viewport=[scroll convertRect:scroll.bounds toView:window];
    CGFloat top=CGRectGetMaxY(window.bounds)-window.safeAreaInsets.bottom;
    for(UIView *view in self.views) {
        BOOL visible=view.window==window;
        for(UIView *parent=view;visible && parent;parent=parent.superview)
            if(parent.hidden || parent.alpha<0.01)visible=NO;
        if(!visible)continue;
        CGRect rect=[view convertRect:view.bounds toView:window];
        if(rect.size.width<viewport.size.width*0.5 || rect.size.height<=0 ||
           rect.size.height>window.bounds.size.height*0.45 ||
           CGRectGetMinY(rect)<CGRectGetMidY(window.bounds) ||
           !CGRectIntersectsRect(viewport,rect))continue;
        top=MIN(top,CGRectGetMinY(rect));
    }
    return MAX(0,CGRectGetMaxY(viewport)-top);
}
@end

static CGFloat SAPBottomInset(UIScrollView *scroll,SAPBottomChrome *chrome,CGFloat base) {
    CGFloat automatic=scroll.adjustedContentInset.bottom-scroll.contentInset.bottom;
    return MAX(base,[chrome coveredBottomOfScroll:scroll]+12-automatic);
}

static UIImage *SAPSettingsIcon(NSString *symbol,UIColor *color,UITraitCollection *traits) {
    static NSCache *cache;static dispatch_once_t once;
    dispatch_once(&once,^{cache=[NSCache new];cache.countLimit=64;});
    UIColor *resolved=[color resolvedColorWithTraitCollection:traits];
    NSString *key=[NSString stringWithFormat:@"%@|%@|%ld|%.2f",symbol,resolved,(long)traits.accessibilityContrast,traits.displayScale];
    UIImage *cached=[cache objectForKey:key];if(cached)return cached;
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat preferredFormat];if(traits.displayScale>0)format.scale=traits.displayScale;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc]initWithSize:CGSizeMake(30,30) format:format];
    UIImage *result=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){
        UIBezierPath *shape=[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,30,30) cornerRadius:8];
        if([symbol isEqual:@"pixie.github"]) {
            [UIColor.whiteColor setFill];[shape fill];
            static UIImage *logo;static dispatch_once_t logoOnce;
            dispatch_once(&logoOnce,^{logo=[UIImage imageWithData:[NSData dataWithBytesNoCopy:(void *)SAPGitHubIconPNG length:sizeof(SAPGitHubIconPNG) freeWhenDone:NO]];});
            [logo drawInRect:CGRectMake(3,3,24,24)];return;
        }
        CGContextSaveGState(context.CGContext);[shape addClip];
        NSArray *colors=@[(id)[resolved colorWithAlphaComponent:0.85].CGColor,(id)resolved.CGColor];
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient=CGGradientCreateWithColors(space,(__bridge CFArrayRef)colors,NULL);
        CGContextDrawLinearGradient(context.CGContext,gradient,CGPointZero,CGPointMake(0,30),0);
        CGGradientRelease(gradient);CGColorSpaceRelease(space);CGContextRestoreGState(context.CGContext);
        UIImage *icon=[[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]]imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize size=icon.size;[icon drawInRect:CGRectMake((30-size.width)/2,(30-size.height)/2,size.width,size.height)];
    }];
    [cache setObject:result forKey:key];return result;
}
static UITableViewCell *SAPSettingsCell(UITableView *table,NSString *title,NSString *subtitle,NSString *symbol,UIColor *color,BOOL chevron) {
    UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"SAPSettingsRow"];
    if(!cell){cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SAPSettingsRow"];
        [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:64].active=YES;}
    UIListContentConfiguration *content=[UIListContentConfiguration subtitleCellConfiguration];
    content.text=title;content.secondaryText=subtitle;content.image=SAPSettingsIcon(symbol,color,table.traitCollection);
    content.textProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.textProperties.color=UIColor.labelColor;content.textProperties.numberOfLines=0;
    content.secondaryTextProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    content.secondaryTextProperties.color=UIColor.secondaryLabelColor;content.secondaryTextProperties.numberOfLines=0;
    content.imageToTextPadding=14;content.directionalLayoutMargins=NSDirectionalEdgeInsetsMake(12,20,12,20);
    content.imageProperties.reservedLayoutSize=CGSizeMake(30,30);
    cell.contentConfiguration=content;cell.accessoryType=chevron?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;
    cell.accessoryView=nil;
    // A read-only mode row may be reused for any action after reloadData.
    cell.userInteractionEnabled=YES;cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    cell.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;cell.accessibilityLabel=title;
    return cell;
}

@interface SAPSettingsTable : SAPPixiePageController
@property(nonatomic,strong) NSDictionary *snapshot;
@property(nonatomic,strong) id changeObserver;
@property(nonatomic,strong) SAPBottomChrome *bottomChrome;
@property(nonatomic) CGFloat baseBottom,appliedBottom;
- (void)refresh;
@end
@implementation SAPSettingsTable
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.tableView.backgroundColor=UIColor.blackColor;self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=70;self.tableView.separatorInset=UIEdgeInsetsMake(0,64,0,20);
    self.bottomChrome=[SAPBottomChrome new];
    self.baseBottom=self.appliedBottom=self.tableView.contentInset.bottom;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(refresh)];
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updateBottomInset];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];SAP_TRACE("ui","pixie_page_appeared",0,@{@"title":self.title?:@"",@"controller":NSStringFromClass(self.class)});}
- (void)viewSafeAreaInsetsDidChange {[super viewSafeAreaInsetsDidChange];[self updateBottomInset];}
- (void)updateBottomInset {
    if(!self.tableView.window)return;
    UIEdgeInsets inset=self.tableView.contentInset;
    if(fabs(inset.bottom-self.appliedBottom)>0.5)self.baseBottom=inset.bottom;
    self.appliedBottom=SAPBottomInset(self.tableView,self.bottomChrome,self.baseBottom);
    if(fabs(inset.bottom-self.appliedBottom)>0.5) {
        inset.bottom=self.appliedBottom;self.tableView.contentInset=inset;
    }
    UIEdgeInsets indicator=self.tableView.verticalScrollIndicatorInsets;
    indicator.bottom=self.appliedBottom;if(!UIEdgeInsetsEqualToEdgeInsets(indicator,self.tableView.verticalScrollIndicatorInsets))self.tableView.verticalScrollIndicatorInsets=indicator;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];[self refresh];
    __weak typeof(self) weak=self;
    self.changeObserver=[NSNotificationCenter.defaultCenter addObserverForName:SAPUIChanged object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){[weak refresh];}];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];if(self.changeObserver)[NSNotificationCenter.defaultCenter removeObserver:self.changeObserver];self.changeObserver=nil;
}
- (void)dealloc {if(_changeObserver)[NSNotificationCenter.defaultCenter removeObserver:_changeObserver];}
- (void)refresh {self.snapshot=[SAPSettingsActions snapshot];[self.tableView reloadData];}
- (void)tableView:(UITableView *)table willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header=(id)view;
        header.textLabel.text=[self tableView:table titleForHeaderInSection:section];
        header.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];header.textLabel.textColor=UIColor.secondaryLabelColor;
    }
}
@end

static NSString *SAPObservedValue(id value) {
    if(!value||value==NSNull.null)return SAPLocalized(@"unavailable_2");
    if([value isKindOfClass:NSNumber.class])return [value stringValue];
    return [value isKindOfClass:NSString.class]&&[value length]?SAPLocalizedValue(value):SAPLocalized(@"unavailable_2");
}
static UITableViewCell *SAPPlainSettingsCell(NSString *label,NSString *value) {
    UITableViewCell *cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text=label;cell.textLabel.numberOfLines=0;
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.text=value;cell.detailTextLabel.numberOfLines=0;
    cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    cell.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    return cell;
}
@interface SAPDetailsSettings : SAPSettingsTable
@property(nonatomic) NSUInteger detailsGeneration;
@property(nonatomic) BOOL checkingCompatibility;
@end
@implementation SAPDetailsSettings
- (void)viewDidLoad {[super viewDidLoad];self.title=SAPLocalized(@"download_status");self.tableView.separatorInset=UIEdgeInsetsMake(0,20,0,20);}
- (void)refresh {
    NSUInteger expected=++self.detailsGeneration;__weak typeof(self) weak=self;
    [SAPSettingsActions loadDetails:NO completion:^(NSDictionary *value){
        if(weak.detailsGeneration!=expected)return;weak.snapshot=value;[weak.tableView reloadData];
    }];
}
- (void)viewWillDisappear:(BOOL)animated {self.detailsGeneration++;[super viewWillDisappear:animated];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return 2;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return section==0?8:7;}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {return @[SAPLocalized(@"status"),SAPLocalized(@"offline_checks")][section];}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if(section==0)return SAPDiagnosticsEnabled()?SAPLocalized(@"unique_tracks_by_final_observed_state"):SAPLocalized(@"diagnostics_are_off_these_are_retained");
    return SAPLocalized(@"native_source_spotify_s_in_process");
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    if(index.section==1 && index.row==6) {
        UITableViewCell *cell=SAPSettingsCell(table,SAPLocalized(@"refresh_quotas_and_licenses"),self.checkingCompatibility?SAPLocalized(@"checking_spotify"):SAPLocalized(@"read_current_native_quotas_and_device"),@"arrow.clockwise.circle.fill",UIColor.systemOrangeColor,NO);
        cell.userInteractionEnabled=!self.checkingCompatibility;return cell;
    }
    if(index.section==1 && index.row==5)return SAPSettingsCell(table,SAPLocalized(@"check_current_track"),SAPLocalized(@"read_this_track_s_native_offline"),@"checkmark.circle.fill",UIColor.systemGreenColor,NO);
    NSDictionary *report=self.snapshot[@"report"]?:@{};NSString *label,*value;
    if(index.section==0) {
        NSArray *labels=@[SAPLocalized(@"downloaded_2"),SAPLocalized(@"downloading_4"),SAPLocalized(@"waiting"),SAPLocalized(@"paused"),SAPLocalized(@"errors"),SAPLocalized(@"limit_reached"),SAPLocalized(@"not_downloaded"),SAPLocalized(@"expired")];
        NSArray *keys=@[@"downloaded",@"downloading",@"waiting",@"awaiting_redownload",@"error",@"waiting_limit_exceeded",@"not_downloaded",@"expired"];
        NSDictionary *counts=report[@"track_journal"][@"state_counts"];
        label=labels[index.row];value=[counts isKindOfClass:NSDictionary.class]?SAPObservedValue(counts[keys[index.row]]?:@0):SAPLocalized(@"unavailable_2");
    }else if(index.section==1) {
        NSDictionary *check=report[@"compatibility_check"],*sources=check[@"sources"],*license=sources[@"licenses"];
        label=@[SAPLocalized(@"native_check"),SAPLocalized(@"free_device_slots_2"),SAPLocalized(@"offline_playback_2"),SAPLocalized(@"local_track_quota"),SAPLocalized(@"local_device_read")][index.row];
        if(index.row==0) {
            NSString *status=check[@"status"];
            double age=NSDate.date.timeIntervalSince1970-[check[@"finished_at"]doubleValue];
            value=check[@"finished_at"]?[NSString stringWithFormat:@"%@ · %@",SAPObservedValue(status),age>90?SAPLocalized(@"stale"):SAPLocalized(@"recent_snapshot")]:SAPObservedValue(status);
        }else if(index.row==1)value=[license[@"read_status"]isEqual:@"received"]&&license[@"free_licenses"]&&license[@"max_licenses"]?[NSString stringWithFormat:@"%@ / %@",license[@"free_licenses"],license[@"max_licenses"]]:SAPObservedValue(license[@"read_status"]);
        else if(index.row==2)value=[sources[@"playback"][@"read_status"]isEqual:@"received"]?([sources[@"playback"][@"allowed"]boolValue]?SAPLocalized(@"allowed_2"):SAPLocalized(@"not_allowed")):SAPObservedValue(sources[@"playback"][@"read_status"]);
        else if(index.row==3)value=sources[@"native"][@"current_tracks"]&&sources[@"native"][@"music_limit"]?[NSString stringWithFormat:@"%@ / %@",sources[@"native"][@"current_tracks"],sources[@"native"][@"music_limit"]]:SAPObservedValue(sources[@"native"][@"read_status"]);
        else value=SAPObservedValue(sources[@"local_device"][@"read_status"]);
    }
    return SAPPlainSettingsCell(label,value);
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];
    if(index.section==1 && index.row==5)[SAPSettingsActions perform:SAPSettingsVerify];
    if(index.section==1 && index.row==6 && !self.checkingCompatibility) {
        self.checkingCompatibility=YES;[self.tableView reloadData];
        __weak typeof(self) weak=self;
        [SAPSettingsActions refreshDownloadCompatibility:^(NSDictionary *result){
            typeof(self) page=weak;if(!page)return;
            page.checkingCompatibility=NO;[page refresh];
            if(!page.viewIfLoaded.window || page.presentedViewController)return;
            UIAlertController *status=[UIAlertController alertControllerWithTitle:SAPLocalized(@"quota_and_license_check") message:SAPDownloadCompatibilityText(result) preferredStyle:UIAlertControllerStyleAlert];
            [status addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"ok") style:UIAlertActionStyleCancel handler:nil]];
            [page presentViewController:status animated:YES completion:nil];
        }];
    }
}

@end

@interface SAPOfflineDevicesSettings : SAPSettingsTable
@property(nonatomic,strong) NSDictionary *plan;
@property(nonatomic,copy) NSArray *enabledDevices;
@property(nonatomic,copy) NSString *readError;
@property(nonatomic) BOOL busy;
@property(nonatomic) NSUInteger refreshGeneration;
@end
@implementation SAPOfflineDevicesSettings
@synthesize plan=_plan;
- (void)setPlan:(NSDictionary *)plan {
    _plan=plan;
    NSMutableArray *enabled=[NSMutableArray array];
    for(NSDictionary *device in plan[@"devices"])
        if([device[@"offline_enabled"]boolValue])[enabled addObject:device];
    self.enabledDevices=enabled;
}
- (void)viewDidLoad {[super viewDidLoad];self.title=SAPLocalized(@"offline_devices");self.tableView.separatorInset=UIEdgeInsetsMake(0,20,0,20);}
- (void)refresh {
    if(self.busy)return;self.busy=YES;self.readError=nil;[self.tableView reloadData];
    NSUInteger expected=++self.refreshGeneration;
    SAPPreviewOfflineDeviceSlots(^(NSDictionary *plan,NSString *error){
        if(expected!=self.refreshGeneration)return;self.busy=NO;self.plan=plan;self.readError=error;[self.tableView reloadData];
    });
}
- (NSArray *)devices {return self.enabledDevices?:@[];}
- (BOOL)actionsAllowed {
    double age=NSDate.date.timeIntervalSince1970-[self.plan[@"created_at"]doubleValue];
    return !self.busy&&[self.plan[@"actions_allowed"]boolValue]&&age>=0&&age<=90;
}
- (NSDictionary *)currentDevice {for(NSDictionary *device in self.plan[@"devices"])if([device[@"is_current_device"]boolValue])return device;return nil;}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return 3;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return section==0?MAX(1,self.devices.count):section==1?1:3;}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if(section==1) {
        NSDictionary *current=self.currentDevice;
        if(current)return [NSString stringWithFormat:SAPLocalized(@"current_2"),[current[@"name"]length]?current[@"name"]:SAPLocalized(@"spotify_device")];
        return SAPLocalized(@"current_device");
    }
    return section==0?SAPLocalized(@"devices"):SAPLocalized(@"source_checks");
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if(section==2) {
        if(self.busy)return SAPLocalized(@"refreshing_native_and_direct_sources");
        double age=NSDate.date.timeIntervalSince1970-[self.plan[@"created_at"]doubleValue];
        if(self.plan&&age>90)return SAPLocalized(@"this_snapshot_is_stale_refresh_before");
        return self.readError?:self.plan[@"detail"]?:SAPLocalized(@"native_and_direct_source_states_agree");
    }
    if(section==0)return SAPLocalized(@"only_devices_with_offline_access_enabled");
    return SAPLocalized(@"play_one_track_online_on_this");
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    if(index.section==2) {
        NSString *value=index.row==0?SAPObservedValue(self.plan[@"native_read_status"]):index.row==1?SAPObservedValue(self.plan[@"direct_read_status"]):self.plan[@"free_licenses"]?[NSString stringWithFormat:@"%@ / %@",self.plan[@"free_licenses"],self.plan[@"max_licenses"]]:SAPLocalized(@"unavailable_2");
        return SAPPlainSettingsCell(@[SAPLocalized(@"native_source"),SAPLocalized(@"direct_source"),[NSString stringWithFormat:SAPLocalized(@"free_maximum_slots"),self.plan[@"quota_source"]?:@"unavailable"]][index.row],value);
    }
    if(index.section==1) {
        BOOL enable=self.actionsAllowed&&self.currentDevice&&![self.currentDevice[@"offline_enabled"]boolValue];
        NSString *title=self.actionsAllowed&&[self.currentDevice[@"offline_enabled"]boolValue]?SAPLocalized(@"offline_enabled_on_this_device"):SAPLocalized(@"enable_offline_on_this_device");
        UITableViewCell *cell=SAPSettingsCell(table,title,self.busy?SAPLocalized(@"checking"):self.actionsAllowed&&[self.currentDevice[@"offline_enabled"]boolValue]?SAPLocalized(@"offline_enabled"):enable?SAPLocalized(@"uses_one_available_slot"):SAPLocalized(@"refresh_to_confirm_the_current_registration"),@"iphone.badge.play",UIColor.systemBlueColor,NO);
        cell.userInteractionEnabled=enable;cell.selectionStyle=enable?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;return cell;
    }
    if(!self.devices.count) {
        BOOL unavailable=!self.plan||self.readError;
        return SAPPlainSettingsCell(self.busy?SAPLocalized(@"offline_devices"):unavailable?SAPLocalized(@"device_list_unavailable"):SAPLocalized(@"no_offline_enabled_devices"),
            self.busy?SAPLocalized(@"loading_2"):unavailable?SAPLocalized(@"refresh_to_read_the_current_list"):SAPLocalized(@"no_active_offline_registrations_in_this"));
    }
    NSDictionary *device=self.devices[index.row];NSString *cache=device[@"cache_id"]?:@"";
    NSString *suffix=[cache substringFromIndex:cache.length>8?cache.length-8:0];
    NSString *identifier=device[@"device_id"]?:@"";NSString *deviceSuffix=[identifier substringFromIndex:identifier.length>8?identifier.length-8:0];
    NSString *name=[device[@"name"]length]?device[@"name"]:SAPLocalized(@"spotify_device");
    NSString *subtitle=[device[@"registration_status"]isEqual:@"not_registered"]?SAPLocalized(@"not_registered_not_listed"):[device[@"offline_enabled"]boolValue]?SAPLocalized(@"offline_enabled"):SAPLocalized(@"offline_disabled");
    NSUInteger matchingNames=0,matchingIdentifiers=0;
    for(NSDictionary *candidate in self.devices) {
        NSString *candidateName=[candidate[@"name"]length]?candidate[@"name"]:SAPLocalized(@"spotify_device");
        if([candidateName isEqual:name]) {
            matchingNames++;if([candidate[@"device_id"]isEqual:identifier])matchingIdentifiers++;
        }
    }
    if(matchingNames>1)subtitle=[NSString stringWithFormat:SAPLocalized(@"device"),subtitle,deviceSuffix];
    if(matchingIdentifiers>1)subtitle=[NSString stringWithFormat:SAPLocalized(@"cache"),subtitle,suffix];
    UITableViewCell *cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content=[UIListContentConfiguration subtitleCellConfiguration];
    content.text=[device[@"is_current_device"]boolValue]?[name stringByAppendingString:SAPLocalized(@"current")]:name;content.secondaryText=subtitle;
    content.textProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.secondaryTextProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    content.secondaryTextProperties.color=UIColor.secondaryLabelColor;content.secondaryTextProperties.numberOfLines=0;
    cell.contentConfiguration=content;cell.accessibilityLabel=content.text;
    cell.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)showResult:(NSString *)title message:(NSString *)message {
    if(!self.view.window)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"ok") style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)enableCurrent {
    if(!self.actionsAllowed||!self.currentDevice||[self.currentDevice[@"offline_enabled"]boolValue])return;
    self.busy=YES;[self.tableView reloadData];
    SAPEnableOfflineOnCurrentDevice(^(NSDictionary *result,NSString *error){
        self.busy=NO;[self refresh];[self showResult:error?SAPLocalized(@"enable_not_confirmed"):SAPLocalized(@"offline_registration_confirmed") message:error?:SAPLocalized(@"spotify_confirms_offline_access_for_this")];
    });
}
- (void)confirmDisable:(NSDictionary *)device {
    if(!self.actionsAllowed)return;
    NSString *cache=device[@"cache_id"],*suffix=[cache substringFromIndex:cache.length>8?cache.length-8:0];
    NSString *identifier=device[@"device_id"];NSString *deviceSuffix=[identifier substringFromIndex:identifier.length>8?identifier.length-8:0];
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:SAPLocalized(@"disable_offline_access_2") message:[NSString stringWithFormat:SAPLocalized(@"device_cache_cached_tracks_on_this"),device[@"name"]?:SAPLocalized(@"spotify_device"),deviceSuffix,suffix] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"disable_offline_access") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        if(!self.actionsAllowed)return;self.busy=YES;[self.tableView reloadData];
        SAPDisableOfflineDevice(self.plan[@"id"],device[@"selection_token"],^(NSDictionary *result,NSString *error){
            self.busy=NO;[self refresh];[self showResult:error?SAPLocalized(@"disable_not_confirmed"):SAPLocalized(@"offline_access_disabled") message:error?:[NSString stringWithFormat:SAPLocalized(@"free_device_slots"),result[@"free_licenses"],result[@"max_licenses"]]];
        });
    }]];[self presentViewController:confirm animated:YES completion:nil];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)index {
    if(index.section!=0||(NSUInteger)index.row>=self.devices.count||!self.actionsAllowed)return nil;
    NSDictionary *device=self.devices[index.row];if([device[@"synthetic_record"]boolValue]||![device[@"offline_enabled"]boolValue])return nil;
    UIContextualAction *action=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:SAPLocalized(@"remove") handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){done(YES);[self confirmDisable:device];}];
    UISwipeActionsConfiguration *configuration=[UISwipeActionsConfiguration configurationWithActions:@[action]];configuration.performsFirstActionWithFullSwipe=NO;return configuration;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {[table deselectRowAtIndexPath:index animated:YES];if(index.section==1)[self enableCurrent];}
@end

// Eevee owns the sidecar and queue. The companion only presents controls and
// obtains a fresh, validated native catalog for the explicit backfill action.
static Class SAPLyricsBridge(void) {return NSClassFromString(@"EeveeOfflineLyricsDownloader");}
static NSDictionary *SAPLyricsSnapshot(void) {
    Class cls=SAPLyricsBridge();SEL selector=NSSelectorFromString(@"settingsSnapshot");
    return [cls respondsToSelector:selector]?((id(*)(id,SEL))objc_msgSend)(cls,selector):@{};
}
// Counts wrap only after a "·" separator, so a label never splits from its number.
static NSString *SAPLyricsCountsText(NSString *text) {
    NSString *glued=[text stringByReplacingOccurrencesOfString:@" " withString:@" "];
    return [glued stringByReplacingOccurrencesOfString:@" · " withString:@" · "];
}
// The native catalog read belongs to the download action, not to a page's lifetime.
static dispatch_block_t SAPLyricsCatalogCancel;
static id SAPLyricsCatalogObserver;
@interface SAPLyricsSettings : SAPSettingsTable
@property(nonatomic,strong) NSDictionary *lyrics;
@property(nonatomic,strong) id lyricsObserver;
@property(nonatomic) BOOL scanning,clearing;
@property(nonatomic) NSUInteger scanCompleted,scanTotal;
@property(nonatomic,strong) UIView *progressHeader,*progressPanel;
@property(nonatomic,strong) UILabel *progressTitle,*progressDetail;
@property(nonatomic,strong) UIProgressView *progressBar;
@property(nonatomic,strong) UIButton *progressAction;
@property(nonatomic,strong) NSLayoutConstraint *progressActionHeight;
@property(nonatomic) BOOL updatingProgressPanel,displayedScan,displayedRefresh;
@end
@implementation SAPLyricsSettings
- (void)viewDidLoad {[super viewDidLoad];self.title=SAPLocalized(@"lyrics_2");}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];__weak typeof(self) weak=self;
    self.lyricsObserver=[NSNotificationCenter.defaultCenter addObserverForName:@"EeveeOfflineLyricsSettingsChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){[weak refresh];}];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];if(self.lyricsObserver)[NSNotificationCenter.defaultCenter removeObserver:self.lyricsObserver];self.lyricsObserver=nil;
}
- (void)dealloc {if(_lyricsObserver)[NSNotificationCenter.defaultCenter removeObserver:_lyricsObserver];}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self layoutProgressPanel:NO];}
- (void)refresh {
    self.lyrics=SAPLyricsSnapshot();self.scanning=[self.lyrics[@"scan_active"]boolValue];
    self.scanCompleted=[self.lyrics[@"scan_completed"]unsignedIntegerValue];self.scanTotal=[self.lyrics[@"scan_total"]unsignedIntegerValue];
    [self.tableView reloadData];
    [self updateProgressPanel];
}
- (BOOL)busy {return self.scanning || ([self.lyrics[@"batch"][@"active"]boolValue] && ![self.lyrics[@"batch"][@"kind"]isEqual:@"refresh"]);}
// Match Downloaded tracks' active progress panel. Lyrics have only a Cancel action.
- (void)updateProgressPanel {
    if(self.updatingProgressPanel || !self.isViewLoaded)return;
    self.updatingProgressPanel=YES;
    NSDictionary *batch=self.lyrics[@"batch"];
    BOOL refresh=[batch[@"kind"]isEqual:@"refresh"] && !self.scanning;
    if(![self downloadsOn] || (!self.scanning && ![batch[@"active"]boolValue])) {
        if(self.progressHeader && self.tableView.tableHeaderView==self.progressHeader)self.tableView.tableHeaderView=nil;
        self.updatingProgressPanel=NO;return;
    }
    BOOL continuing=self.tableView.tableHeaderView==self.progressHeader && self.displayedScan==self.scanning && self.displayedRefresh==refresh;
    if(!self.progressHeader) {
        self.progressHeader=UIView.new;self.progressHeader.autoresizingMask=UIViewAutoresizingFlexibleWidth;
        self.progressPanel=UIView.new;self.progressPanel.backgroundColor=[UIColor colorWithWhite:1 alpha:0.1008];self.progressPanel.translatesAutoresizingMaskIntoConstraints=NO;
        self.progressPanel.layer.cornerRadius=24;self.progressPanel.layer.cornerCurve=kCACornerCurveContinuous;
        self.progressTitle=UILabel.new;self.progressTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];self.progressTitle.textColor=UIColor.labelColor;self.progressTitle.adjustsFontForContentSizeCategory=YES;
        self.progressTitle.numberOfLines=1;self.progressTitle.lineBreakMode=NSLineBreakByTruncatingTail;
        self.progressDetail=UILabel.new;self.progressDetail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.progressDetail.textColor=UIColor.secondaryLabelColor;self.progressDetail.adjustsFontForContentSizeCategory=YES;
        self.progressDetail.numberOfLines=2;self.progressDetail.lineBreakMode=NSLineBreakByTruncatingTail;
        for(UILabel *label in @[self.progressTitle,self.progressDetail]) {
            label.translatesAutoresizingMaskIntoConstraints=NO;[label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        }
        self.progressBar=[[UIProgressView alloc]initWithProgressViewStyle:UIProgressViewStyleDefault];self.progressBar.progressTintColor=UIColor.systemGreenColor;self.progressBar.translatesAutoresizingMaskIntoConstraints=NO;
        self.progressAction=[UIButton buttonWithType:UIButtonTypeSystem];self.progressAction.translatesAutoresizingMaskIntoConstraints=NO;
        UIButtonConfiguration *button=[UIButtonConfiguration filledButtonConfiguration];button.buttonSize=UIButtonConfigurationSizeSmall;button.baseForegroundColor=UIColor.whiteColor;button.baseBackgroundColor=UIColor.systemGray4Color;button.cornerStyle=UIButtonConfigurationCornerStyleCapsule;
        button.contentInsets=NSDirectionalEdgeInsetsMake(5,10,5,10);button.titleLineBreakMode=NSLineBreakByTruncatingTail;
        button.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];return result;};
        self.progressAction.configuration=button;[self.progressAction setTitle:SAPLocalized(@"cancel") forState:UIControlStateNormal];
        [self.progressAction addTarget:self action:@selector(cancelDownload) forControlEvents:UIControlEventTouchUpInside];
        self.progressAction.titleLabel.numberOfLines=1;self.progressAction.titleLabel.adjustsFontSizeToFitWidth=YES;self.progressAction.titleLabel.minimumScaleFactor=0.6;
        self.progressActionHeight=[self.progressAction.heightAnchor constraintEqualToConstant:30];
        [self.progressHeader addSubview:self.progressPanel];
        for(UIView *child in @[self.progressTitle,self.progressDetail,self.progressBar,self.progressAction])[self.progressPanel addSubview:child];
        [NSLayoutConstraint activateConstraints:@[
            [self.progressPanel.leadingAnchor constraintEqualToAnchor:self.progressHeader.layoutMarginsGuide.leadingAnchor],
            [self.progressPanel.trailingAnchor constraintEqualToAnchor:self.progressHeader.layoutMarginsGuide.trailingAnchor],
            [self.progressPanel.topAnchor constraintEqualToAnchor:self.progressHeader.topAnchor constant:8],
            [self.progressPanel.bottomAnchor constraintEqualToAnchor:self.progressHeader.bottomAnchor constant:-8],
            [self.progressAction.topAnchor constraintEqualToAnchor:self.progressPanel.topAnchor constant:10],
            [self.progressAction.trailingAnchor constraintEqualToAnchor:self.progressPanel.trailingAnchor constant:-14],
            [self.progressAction.widthAnchor constraintEqualToConstant:76],self.progressActionHeight,
            [self.progressTitle.leadingAnchor constraintEqualToAnchor:self.progressPanel.leadingAnchor constant:16],
            [self.progressTitle.trailingAnchor constraintEqualToAnchor:self.progressAction.leadingAnchor constant:-12],
            [self.progressTitle.centerYAnchor constraintEqualToAnchor:self.progressAction.centerYAnchor],
            [self.progressDetail.leadingAnchor constraintEqualToAnchor:self.progressPanel.leadingAnchor constant:16],
            [self.progressDetail.trailingAnchor constraintEqualToAnchor:self.progressPanel.trailingAnchor constant:-16],
            [self.progressDetail.topAnchor constraintEqualToAnchor:self.progressAction.bottomAnchor constant:8],
            [self.progressBar.leadingAnchor constraintEqualToAnchor:self.progressPanel.leadingAnchor constant:16],
            [self.progressBar.trailingAnchor constraintEqualToAnchor:self.progressPanel.trailingAnchor constant:-16],
            [self.progressBar.topAnchor constraintEqualToAnchor:self.progressDetail.bottomAnchor constant:10],
            [self.progressBar.heightAnchor constraintEqualToConstant:4],
            [self.progressBar.bottomAnchor constraintEqualToAnchor:self.progressPanel.bottomAnchor constant:-14]]];
    }
    NSUInteger done=self.scanning?self.scanCompleted:[batch[@"completed"]unsignedIntegerValue];
    NSUInteger total=self.scanning?self.scanTotal:[batch[@"total"]unsignedIntegerValue];
    NSString *title=refresh?SAPLocalized(@"updating_lyrics"):SAPLocalized(@"downloading_lyrics");
    if(self.scanning)title=SAPLocalized(@"checking_downloads");
    self.progressTitle.text=[NSString stringWithFormat:title,(unsigned long)done,(unsigned long)total];
    self.progressDetail.text=self.scanning?SAPLocalized(@"preparing_lyrics_download"):
        SAPLyricsCountsText([NSString stringWithFormat:SAPLocalized(@"saved_already_saved_failed_not_found"),
            batch[@"saved"]?:@0,batch[@"skipped"]?:@0,batch[@"failed"]?:@0,batch[@"not_found"]?:@0]);
    float fraction=total?MIN(1,(float)done/total):0;
    BOOL animate=continuing && self.progressBar.window!=nil && fraction>self.progressBar.progress && !UIAccessibilityIsReduceMotionEnabled();
    if(!continuing || fraction!=self.progressBar.progress || UIAccessibilityIsReduceMotionEnabled())[self.progressBar setProgress:fraction animated:animate];
    self.displayedScan=self.scanning;
    self.displayedRefresh=refresh;
    [self layoutProgressPanel:YES];self.updatingProgressPanel=NO;
}
- (void)layoutProgressPanel:(BOOL)insert {
    if(!self.progressHeader || (!insert && self.tableView.tableHeaderView!=self.progressHeader))return;
    CGFloat width=self.tableView.bounds.size.width;
    if(width<=0)return;
    UIEdgeInsets margins=self.tableView.layoutMargins;
    UIEdgeInsets headerMargins=UIEdgeInsetsMake(0,MAX(16,margins.left),0,MAX(16,margins.right));
    if(!UIEdgeInsetsEqualToEdgeInsets(headerMargins,self.progressHeader.layoutMargins))self.progressHeader.layoutMargins=headerMargins;
    CGFloat actionHeight=ceil(MAX(30,MAX(self.progressTitle.font.lineHeight,[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1].lineHeight+10)));
    if(fabs(self.progressActionHeight.constant-actionHeight)>.5)self.progressActionHeight.constant=actionHeight;
    CGFloat detailWidth=MAX(1,width-headerMargins.left-headerMargins.right-32);
    if(fabs(self.progressDetail.preferredMaxLayoutWidth-detailWidth)>.5)self.progressDetail.preferredMaxLayoutWidth=detailWidth;
    CGFloat detailHeight=ceil([self.progressDetail sizeThatFits:CGSizeMake(detailWidth,CGFLOAT_MAX)].height);
    CGFloat height=16+10+actionHeight+8+detailHeight+10+4+14;
    CGSize size=CGSizeMake(width,height);BOOL resized=!CGSizeEqualToSize(self.progressHeader.bounds.size,size);
    if(resized)self.progressHeader.frame=(CGRect){CGPointZero,size};
    if(self.tableView.tableHeaderView!=self.progressHeader || resized)self.tableView.tableHeaderView=self.progressHeader;
}
- (void)cancelDownload {
    dispatch_block_t cancel=SAPLyricsCatalogCancel;SAPLyricsCatalogCancel=nil;
    Class cls=SAPLyricsBridge();SEL selector=NSSelectorFromString(@"cancelDownloads");
    if([cls respondsToSelector:selector])((void(*)(id,SEL))objc_msgSend)(cls,selector);
    if(cancel)cancel();
    [self refresh];
}
// Everything except the switch appears only while lyrics downloading is on.
- (BOOL)downloadsOn {return [self.lyrics[@"enabled"]boolValue];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return [self downloadsOn]?2:1;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return section==0?([self downloadsOn]?2:1):2;}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {return section==0?SAPLocalized(@"downloading_4"):SAPLocalized(@"saved_lyrics");}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if(section==1)return SAPLocalized(@"deleting_lyrics_keeps_your_music_removing");
    return [NSString stringWithFormat:SAPLocalized(@"source_save_lyrics_alongside_music_turning"),self.lyrics[@"source"]?:@"—"];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    if(index.section==1) {
        if(index.row==0){
            NSUInteger count=[self.lyrics[@"tracks"]unsignedIntegerValue];
            NSString *format=count==1?SAPLocalized(@"lyrics_for_song"):SAPLocalized(@"lyrics_for_songs");
            NSString *title=[NSString stringWithFormat:format,(unsigned long)count];
            UITableViewCell *cell=SAPSettingsCell(table,title,nil,@"music.note.list",UIColor.systemPurpleColor,NO);
            UILabel *size=[UILabel new];size.text=[NSByteCountFormatter stringFromByteCount:[self.lyrics[@"bytes"]longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
            size.textColor=UIColor.secondaryLabelColor;size.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];[size sizeToFit];
            cell.accessoryView=size;cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;
        }
        UITableViewCell *cell=SAPSettingsCell(table,SAPLocalized(@"delete_saved_lyrics"),nil,@"trash.fill",UIColor.systemRedColor,NO);
        cell.userInteractionEnabled=!self.clearing;return cell;
    }
    if(index.row==0) {
        NSString *title=SAPLocalized(@"download_lyrics");
        UITableViewCell *cell=SAPSettingsCell(table,title,nil,@"text.quote",UIColor.systemPurpleColor,NO);
        UISwitch *toggle=[UISwitch new];toggle.on=[self.lyrics[@"enabled"]boolValue];toggle.enabled=SAPLyricsBridge()!=Nil && !self.clearing;toggle.accessibilityLabel=title;
        [toggle addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;
    }
    NSString *detail=nil;
    if(![self.lyrics[@"available"]boolValue])detail=SAPLocalized(@"choose_a_lyrics_provider_in_eeveespotify");
    BOOL allSaved=[self.lyrics[@"all_saved"]boolValue];
    BOOL checking=[self.lyrics[@"statistics_loading"]boolValue];
    if(![self busy] && checking)detail=SAPLocalized(@"checking_saved_lyrics");
    else if(![self busy] && [self.lyrics[@"library_known"]boolValue] && !allSaved)
        detail=[NSString stringWithFormat:SAPLocalized(@"missing_lyrics_for_songs"),self.lyrics[@"library_missing"]?:@0];
    NSString *title=allSaved?([self.lyrics[@"library_total"]unsignedIntegerValue]?SAPLocalized(@"all_lyrics_are_downloaded"):SAPLocalized(@"no_downloaded_songs")):SAPLocalized(@"download_missing_lyrics");
    UITableViewCell *cell=SAPSettingsCell(table,title,detail,allSaved?@"checkmark.circle.fill":@"arrow.down.circle.fill",UIColor.systemGreenColor,NO);
    cell.userInteractionEnabled=[self.lyrics[@"enabled"]boolValue]&&[self.lyrics[@"available"]boolValue]&&![self busy]&&!self.clearing&&!allSaved&&!checking;
    if(!cell.userInteractionEnabled)cell.selectionStyle=UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)enabledChanged:(UISwitch *)toggle {
    if(!toggle.on && SAPLyricsCatalogCancel){SAPLyricsCatalogCancel();SAPLyricsCatalogCancel=nil;self.scanning=NO;}
    Class cls=SAPLyricsBridge();SEL selector=NSSelectorFromString(@"setDownloadsEnabled:");
    if([cls respondsToSelector:selector])((void(*)(id,SEL,BOOL))objc_msgSend)(cls,selector,toggle.on);
    [UIView transitionWithView:self.tableView duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{[self refresh];} completion:nil];
}
- (void)showError:(NSString *)error {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:SAPLocalized(@"lyrics_2") message:SAPLocalizedValue(error) preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"ok") style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)downloadExisting {
    if([self busy] || self.clearing || [self.lyrics[@"all_saved"]boolValue])return;
    self.scanning=YES;
    if(!SAPLyricsCatalogObserver)SAPLyricsCatalogObserver=[NSNotificationCenter.defaultCenter addObserverForName:@"EeveeOfflineLyricsSettingsChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
        if(SAPLyricsCatalogCancel && ![SAPLyricsSnapshot()[@"scan_active"]boolValue]){dispatch_block_t cancel=SAPLyricsCatalogCancel;SAPLyricsCatalogCancel=nil;cancel();}
    }];
    Class bridge=SAPLyricsBridge();SEL begin=NSSelectorFromString(@"beginLibraryScan");
    if([bridge respondsToSelector:begin])((void(*)(id,SEL))objc_msgSend)(bridge,begin);
    [self refresh];__weak typeof(self) weak=self;
    SAPLyricsCatalogCancel=SAPFetchOfflineLibrary(^(NSUInteger done,NSUInteger total){
        Class cls=SAPLyricsBridge();SEL update=NSSelectorFromString(@"libraryScanProgress:total:");
        if([cls respondsToSelector:update])((void(*)(id,SEL,NSInteger,NSInteger))objc_msgSend)(cls,update,(NSInteger)done,(NSInteger)total);
        [weak refresh];
    },^(NSArray *tracks,NSString *error){
        typeof(self) self=weak;SAPLyricsCatalogCancel=nil;self.scanning=NO;
        if(![SAPLyricsSnapshot()[@"scan_active"]boolValue]){[self refresh];return;}
        if(!tracks){Class cls=SAPLyricsBridge();SEL end=NSSelectorFromString(@"endLibraryScan");if([cls respondsToSelector:end])((void(*)(id,SEL))objc_msgSend)(cls,end);[self refresh];[self showError:error?:SAPLocalized(@"could_not_verify_downloaded_songs")];return;}
        Class cls=SAPLyricsBridge();SEL selector=NSSelectorFromString(@"downloadForTracks:");
        if([cls respondsToSelector:selector])((void(*)(id,SEL,id))objc_msgSend)(cls,selector,tracks);
        [self refresh];
        if(!tracks.count)[self showError:SAPLocalized(@"spotify_reported_no_downloaded_songs")];
    });
}
- (void)deleteAll {
    if(self.clearing)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:SAPLocalized(@"delete_all_saved_lyrics") message:SAPLocalized(@"your_music_stays_pending_lyrics_downloads") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"delete_lyrics") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        if(SAPLyricsCatalogCancel){SAPLyricsCatalogCancel();SAPLyricsCatalogCancel=nil;self.scanning=NO;}
        self.clearing=YES;[self refresh];Class cls=SAPLyricsBridge();SEL selector=NSSelectorFromString(@"deleteSavedLyricsWithCompletion:");
        if([cls respondsToSelector:selector])((void(*)(id,SEL,id))objc_msgSend)(cls,selector,^(NSString *error){self.clearing=NO;[self refresh];if(error)[self showError:error];});
        else {self.clearing=NO;[self refresh];}
    }]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];
    if(index.section==1 && index.row==1){[self deleteAll];return;}
    if(index.section==0 && index.row==1){[self downloadExisting];return;}
}
@end

@interface SAPDownloadsSettings : SAPSettingsTable
@property(nonatomic) BOOL checkingCompatibility;
@property(nonatomic) BOOL qualityOffer;
@property(nonatomic,strong) id qualityObserver;
@end
@implementation SAPDownloadsSettings
- (void)viewDidLoad {
    [super viewDidLoad];self.title=SAPLocalized(@"pixie_download_manager");
    [self updateQualityOffer];
    __weak typeof(self) weak=self;
    self.qualityObserver=[NSNotificationCenter.defaultCenter addObserverForName:SAPNativeDownloadQualityOfferDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){[weak updateQualityOffer];}];
}
- (void)dealloc {if(_qualityObserver)[NSNotificationCenter.defaultCenter removeObserver:_qualityObserver];}
// The download-quality offer is a real first section with one row in the same style as every other menu row.
// It is shown only while Spotify's download quality is Normal and has never been High; a tap hides it for good.
- (void)updateQualityOffer {
    BOOL offer=SAPShouldOfferNativeDownloadQuality();
    if(offer==self.qualityOffer)return;
    self.qualityOffer=offer;[self.tableView reloadData];
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self updateQualityOffer];}
- (void)qualityOfferTapped {
    // Persist suppression before native navigation starts; the notification then removes the row.
    SAPDismissNativeDownloadQualityOfferAndOpenSettings();
}
// Lyrics downloads are EeveeSpotify's: the section exists only when it is installed.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return 4+(self.qualityOffer?1:0)+(SAPLyricsBridge()?1:0);}
- (NSInteger)topic:(NSInteger)section {return !SAPLyricsBridge()&&section>=3?section+1:section;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if(self.qualityOffer){if(section==0)return 1;section--;}
    section=[self topic:section];
    if(section==0)return [self.snapshot[@"download_active"]boolValue]?3:2;
    if(section==3)return 1;
    if(section==4)return SAPDiagnosticsEnabled()?4:3;
    if(section==1||section==2)return 2;
    return 2;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if(self.qualityOffer){if(section==0)return nil;section--;}
    return @[SAPLocalized(@"download"),SAPLocalized(@"download_compatibility"),SAPLocalized(@"export"),SAPLocalized(@"lyrics_2"),SAPLocalized(@"diagnostics")][[self topic:section]];
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if(self.qualityOffer){if(section==0)return nil;section--;}
    section=[self topic:section];
    if(section==0) {
        NSDictionary *startup=self.snapshot[@"jailbreak_bootstrap"];
        if(startup&&![startup[@"native_patches_ready"]boolValue])return [NSString stringWithFormat:SAPLocalized(@"pixie_could_not_initialize_downloads_supported"),startup[@"reason"],@SAP_SPOTIFY_VERSION,startup[@"detected_spotify_version"]];
        return SAPLocalized(@"downloads_stay_in_spotify_audio_export");
    }
    if(section==1) {
        NSDictionary *mode=self.snapshot[@"key_request_mode"];
        // The adapter reports a fixed English sentence; it is a Localizable.strings key.
        return [NSString stringWithFormat:SAPLocalized(@"only_change_settings_in_this_menu"),SAPLocalizedValue(mode[@"detail"]?:@"")];
    }
    if(section==2)return SAPLocalized(@"export_downloaded_spotify_audio_to_external");
    if(section==3)return SAPLocalized(@"download_lyrics_for_downloaded_songs_and");
    if(section==4)return SAPLocalized(@"enable_diagnostics_for_detailed_passive_events");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    if(self.qualityOffer) {
        if(index.section==0)return SAPSettingsCell(table,SAPLocalized(@"download_quality_is_normal"),SAPLocalized(@"tap_to_switch_to_high_in"),@"arrow.up.circle.fill",UIColor.systemGreenColor,YES);
        index=[NSIndexPath indexPathForRow:index.row inSection:index.section-1];
    }
    index=[NSIndexPath indexPathForRow:index.row inSection:[self topic:index.section]];
    if(index.section==4 && !SAPDiagnosticsEnabled() && index.row>0)index=[NSIndexPath indexPathForRow:index.row+1 inSection:index.section];
    NSString *title,*subtitle=nil,*symbol;UIColor *color;BOOL chevron=NO;
    if(index.section==0) {
        NSArray *titles=@[[self.snapshot[@"download_active"]boolValue]?SAPLocalized(@"track_download_status"):SAPLocalized(@"download_current_track"),SAPLocalized(@"download_current_track_s_album"),SAPLocalized(@"cancel_download")];
        title=titles[index.row];symbol=@[@"arrow.down.circle.fill",@"square.stack.fill",@"xmark.circle.fill"][index.row];
        color=index.row==2?UIColor.systemOrangeColor:UIColor.systemGreenColor;
    }else if(index.section==1) {
        NSDictionary *mode=self.snapshot[@"key_request_mode"];
        if(index.row==1)return SAPSettingsCell(table,SAPLocalized(@"offline_devices"),SAPLocalized(@"review_registrations_and_offline_access"),@"externaldrive.badge.person.crop",UIColor.systemOrangeColor,YES);
        NSInteger configured=[mode[@"configured_mode"]integerValue];
        title=SAPLocalized(@"configured_request_mode");
        NSNumber *last=mode[@"last_selector_returned_mode"];
        subtitle=self.checkingCompatibility?SAPLocalized(@"checking_quotas_and_licenses"):([mode[@"configuration_source"]isEqual:@"verified_direct_instruction"]||[mode[@"configuration_source"]isEqual:@"verified_static_trace_argument"])?SAPLocalized(@"verified_fixed_argument_in_the_executable"):
            (last && last.integerValue>=0?[NSString stringWithFormat:SAPLocalized(@"last_selector_returned_authorization_unconfirmed"),last]:SAPLocalized(@"no_selector_invocation_observed_this_launch"));
        symbol=@"arrow.triangle.2.circlepath";color=UIColor.systemOrangeColor;chevron=YES;
        UITableViewCell *cell=SAPSettingsCell(table,title,subtitle,symbol,color,chevron);
        UILabel *status=[UILabel new];status.font=[UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold];
        status.text=configured<0?@"?":configured==0?@"0":@"1";
        status.textColor=configured==0?UIColor.systemGreenColor:configured==1?UIColor.systemRedColor:UIColor.secondaryLabelColor;
        [status sizeToFit];cell.accessoryView=status;
        BOOL restore=[mode[@"restore_zero_supported"]boolValue];
        cell.selectionStyle=restore?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled=restore;
        return cell;
    }else if(index.section==2) {
        if(index.row==1)return SAPSettingsCell(table,SAPLocalized(@"downloaded_tracks"),SAPLocalized(@"browse_spotify_offline_music"),@"music.note.list",UIColor.systemGreenColor,YES);
        UITableViewCell *cell=SAPSettingsCell(table,SAPLocalized(@"use_ogg_format"),nil,@"waveform",UIColor.systemBlueColor,NO);
        UISwitch *toggle=[UISwitch new];toggle.on=[SAPAudioExportFormat()isEqual:@"ogg"];toggle.accessibilityLabel=SAPLocalized(@"use_ogg_format");
        [toggle addTarget:self action:@selector(oggFormatChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
        cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;
    }else if(index.section==3) {
        return SAPSettingsCell(table,SAPLocalized(@"lyrics_downloads"),nil,@"arrow.down.circle.fill",UIColor.systemPurpleColor,YES);
    }else {
        title=@[SAPLocalized(@"diagnostics"),SAPLocalized(@"download_status"),SAPLocalized(@"send_log"),SAPLocalized(@"reset_log_2")][index.row];
        symbol=@[@"slider.horizontal.3",@"waveform.path.ecg",@"square.and.arrow.up",@"trash.fill"][index.row];color=index.row==3?UIColor.systemGrayColor:UIColor.systemTealColor;chevron=index.row==1;
        if(index.row==3)subtitle=SAPLocalized(@"clear_previous_logs_and_start_a");
    }
    UITableViewCell *cell=SAPSettingsCell(table,title,subtitle,symbol,color,chevron);
    if(index.section==4 && index.row==0) {
        UISwitch *toggle=[UISwitch new];toggle.on=SAPDiagnosticsEnabled();
        toggle.accessibilityLabel=SAPLocalized(@"diagnostics");toggle.accessibilityIdentifier=@"SpotifyDiagnosticsSwitch";
        [toggle addTarget:self action:@selector(diagnosticsChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    }
    return cell;
}
- (void)oggFormatChanged:(UISwitch *)toggle {
    [NSUserDefaults.standardUserDefaults setObject:toggle.on?@"ogg":@"m4a" forKey:@"PixieExportFormat"];
}
- (void)applyDiagnostics:(BOOL)enabled {
    BOOL before=SAPDiagnosticsEnabled();SAPDiagnosticsSetEnabled(enabled);
    SAP_JOURNAL_ACTION(@"diagnostics_changed",@{@"before":@(before),@"after":@(SAPDiagnosticsEnabled())});[self refresh];
    [self.tableView layoutIfNeeded];[self updateBottomInset];
}
- (void)requestDiagnostics:(BOOL)enabled {
    if(enabled==SAPDiagnosticsEnabled() || self.presentedViewController)return;
    if(!enabled){[self applyDiagnostics:NO];return;}
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:SAPLocalized(@"are_you_sure") message:SAPLocalized(@"enable_detailed_diagnostics_logging") preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"no_2") style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"yes_2") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[self applyDiagnostics:YES];}]];
    [self presentViewController:confirm animated:YES completion:nil];
}
- (void)diagnosticsChanged:(UISwitch *)toggle {
    BOOL requested=toggle.on;[toggle setOn:SAPDiagnosticsEnabled() animated:YES];[self requestDiagnostics:requested];
}
- (void)slotMessage:(NSString *)title message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"ok") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];
    if(self.qualityOffer) {
        if(index.section==0){SAP_TRACE("ui","pixie_menu_selection",0,@{@"title":self.title?:@"",@"item":@"download_quality_offer"});[self qualityOfferTapped];return;}
        index=[NSIndexPath indexPathForRow:index.row inSection:index.section-1];
    }
    index=[NSIndexPath indexPathForRow:index.row inSection:[self topic:index.section]];
    if(index.section==4 && !SAPDiagnosticsEnabled() && index.row>0)index=[NSIndexPath indexPathForRow:index.row+1 inSection:index.section];
    SAP_TRACE("ui","pixie_menu_selection",0,@{@"title":self.title?:@"",@"section":@(index.section),@"row":@(index.row)});
    if(index.section==2) {
        if(index.row==1){SAPShowOfflineLibrary(self);return;}
        return;
    }
    if(index.section==3){[self.navigationController pushViewController:[SAPLyricsSettings new] animated:YES];return;}
    if(index.section==4 && index.row==0){[self requestDiagnostics:!SAPDiagnosticsEnabled()];return;}
    if(index.section==4 && index.row==2){[SAPSettingsActions perform:SAPSettingsSendLog];return;}
    if(index.section==4 && index.row==3){[SAPSettingsActions perform:SAPSettingsResetJournal];return;}
    if(index.section==1) {
        if(self.checkingCompatibility)return;
        if(index.row==1){[self.navigationController pushViewController:[SAPOfflineDevicesSettings new] animated:YES];return;}
        NSDictionary *mode=self.snapshot[@"key_request_mode"];
        if(![mode[@"restore_zero_supported"]boolValue])return;
        UIAlertController *choice=[UIAlertController alertControllerWithTitle:SAPLocalized(@"restore_mode_0") message:SAPLocalized(@"the_verified_selector_was_observed_returning") preferredStyle:UIAlertControllerStyleAlert];
        [choice addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"restore_mode_0_2") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            self.checkingCompatibility=YES;[self.tableView reloadData];
            [SAPSettingsActions setKeyRequestMode:0 completion:^(BOOL changed,NSString *reason){
                self.checkingCompatibility=NO;[self refresh];
                [self slotMessage:changed?SAPLocalized(@"mode_0_restored"):SAPLocalized(@"mode_unchanged") message:reason];
            }];
        }]];
        [choice addAction:[UIAlertAction actionWithTitle:SAPLocalized(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:choice animated:YES completion:nil];return;
    }
    if(index.section==4 && index.row==1) {
        SAPDetailsSettings *page=[SAPDetailsSettings new];
        [self.navigationController pushViewController:page animated:YES];return;
    }
    SAPSettingsAction action;
    if(index.section==0) {
        const SAPSettingsAction actions[]={SAPSettingsDownload,SAPSettingsDownloadAlbum,SAPSettingsCancelDownload};
        if(index.row<0||index.row>=3)return;action=actions[index.row];
    }
    else return;
    [SAPSettingsActions perform:action];
    if(action==SAPSettingsCancelDownload)[self refresh];
}
@end

// Embedded footer is a view/data source, not a child view controller. The
// existing SwiftUI hosting controller retains sole ownership of its view tree.
@interface SAPDownloadsEntry : NSObject <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,weak) UIViewController *settingsHost;
@property(nonatomic,strong) UITableView *view;
@end
@implementation SAPDownloadsEntry
- (instancetype)init {
    if((self=[super init])) {
        self.view=[[UITableView alloc]initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
        self.view.dataSource=self;self.view.delegate=self;
        self.view.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
        self.view.rowHeight=UITableViewAutomaticDimension;self.view.estimatedRowHeight=76;
        self.view.scrollEnabled=NO;self.view.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
        self.view.backgroundColor=UIColor.clearColor;self.view.accessibilityIdentifier=@"SpotifyTrackDownloadsSection";
    }
    return self;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return 1;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return 1;}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {return SAPLocalized(@"pixie_download_manager");}
- (void)tableView:(UITableView *)table willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header=(id)view;
        header.textLabel.text=SAPLocalized(@"pixie_download_manager");
        header.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        header.textLabel.textColor=UIColor.secondaryLabelColor;
    }
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    return SAPSettingsCell(table,SAPLocalized(@"manage_downloads_2"),SAPLocalized(@"current_track_mode_and_download_status"),@"arrow.down.circle.fill",UIColor.systemGreenColor,YES);
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];
    if(index.row==0)[self.settingsHost.navigationController pushViewController:[SAPDownloadsSettings new] animated:YES];
}
@end

@interface SAPSettingsAttachment : NSObject
@property(nonatomic,weak) UIViewController *host;
@property(nonatomic,weak) UIScrollView *scroll;
@property(nonatomic,strong) SAPDownloadsEntry *entry;
@property(nonatomic,strong) SAPBottomChrome *bottomChrome;
@property(nonatomic) CGFloat baseBottom,appliedBottom,measuredWidth,measuredHeight;
@property(nonatomic,copy) NSString *measuredCategory;
@property(nonatomic) BOOL observing,updating;
- (void)layout;
@end
@implementation SAPSettingsAttachment
// The entry is a non-scrolling table whose height is whatever its rows, section header and footer need. Measure it
// (once per width and text size) instead of reserving a fixed height: a fixed one left a blank gap and pushed
// the group too low whenever its row count changed.
- (CGFloat)entryHeightForWidth:(CGFloat)width {
    NSString *category=self.scroll.traitCollection.preferredContentSizeCategory;
    if(self.measuredHeight>0 && fabs(self.measuredWidth-width)<0.5 && [self.measuredCategory isEqual:category])return self.measuredHeight;
    UITableView *table=self.entry.view;
    table.frame=CGRectMake(0,0,width,800);[table reloadData];[table layoutIfNeeded];
    CGFloat height=ceil(table.contentSize.height);
    if(height<1)return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]scaledValueForValue:130];
    self.measuredWidth=width;self.measuredHeight=height;self.measuredCategory=category;return height;
}
- (void)dealloc {
    if(_observing && _scroll)[_scroll removeObserver:self forKeyPath:@"contentSize" context:SAPContentSizeContext];
}
- (void)layout {
    if(self.updating || !self.scroll || !self.host.view.window)return;
    self.updating=YES;
    UIScrollView *scroll=self.scroll;
    CGFloat height=[self entryHeightForWidth:scroll.bounds.size.width];
    if(fabs(scroll.contentInset.bottom-self.appliedBottom)>0.5)self.baseBottom=scroll.contentInset.bottom;
    // Eevee ends its SwiftUI List with a separate, empty Spacer section.
    // Start after the final real footer, before that reserved blank space.
    CGFloat start=scroll.contentSize.height;
    if([scroll isKindOfClass:UICollectionView.class]) {
        UICollectionView *list=(id)scroll;
        for(NSInteger section=list.numberOfSections-1;section>=0;section--) {
            UICollectionViewLayoutAttributes *footer=[list.collectionViewLayout layoutAttributesForSupplementaryViewOfKind:UICollectionElementKindSectionFooter atIndexPath:[NSIndexPath indexPathForItem:0 inSection:section]];
            if(footer && footer.frame.size.height>1){start=CGRectGetMaxY(footer.frame);break;}
        }
    }else if([scroll isKindOfClass:UITableView.class]) {
        UITableView *list=(id)scroll;
        for(NSInteger section=list.numberOfSections-1;section>=0;section--) {
            CGRect footer=[list rectForFooterInSection:section];
            if(footer.size.height>1){start=CGRectGetMaxY(footer);break;}
        }
    }
    CGRect frame=CGRectMake(0,start,scroll.bounds.size.width,height);
    if(!CGRectEqualToRect(self.entry.view.frame,frame))self.entry.view.frame=frame;
    if(self.entry.view.superview!=scroll)[scroll addSubview:self.entry.view];
    if(scroll.subviews.lastObject!=self.entry.view)[scroll bringSubviewToFront:self.entry.view];
    CGFloat extension=MAX(0,start+height-scroll.contentSize.height);
    UIEdgeInsets inset=scroll.contentInset;
    self.appliedBottom=SAPBottomInset(scroll,self.bottomChrome,self.baseBottom)+extension;
    if(fabs(inset.bottom-self.appliedBottom)>0.5){inset.bottom=self.appliedBottom;scroll.contentInset=inset;}
    UIEdgeInsets indicator=scroll.verticalScrollIndicatorInsets;
    indicator.bottom=MAX(self.baseBottom,self.appliedBottom-extension);
    if(!UIEdgeInsetsEqualToEdgeInsets(indicator,scroll.verticalScrollIndicatorInsets))scroll.verticalScrollIndicatorInsets=indicator;
    self.updating=NO;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=SAPContentSizeContext){[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];return;}
    if(NSThread.isMainThread)[self layout];else dispatch_async(dispatch_get_main_queue(),^{[self layout];});
}
@end
static UIScrollView *SAPSettingsList(UIView *root,CGFloat width,unsigned depth) {
    if(depth>12)return nil;
    if([root isKindOfClass:UIScrollView.class] && root.bounds.size.width>width*0.65 &&
        ([root isKindOfClass:UITableView.class] || [root isKindOfClass:UICollectionView.class]))return (id)root;
    for(UIView *view in root.subviews){UIScrollView *found=SAPSettingsList(view,width,depth+1);if(found)return found;}
    return nil;
}
static void SAPAttachSettings(UIViewController *host) {
    if(![host.title isEqual:@"EeveeSpotify"])return;
    // Newer EeveeSpotify lists the download manager as a row of its own; do not add a second entry.
    if(dlsym(RTLD_DEFAULT,"EeveePixieDownloadsRowProvided"))return;
    SAPSettingsAttachment *attachment=objc_getAssociatedObject(host,SAPAttachmentKey);
    if(attachment){[attachment layout];return;}
    UIScrollView *list=SAPSettingsList(host.view,host.view.bounds.size.width,0);if(!list)return;
    attachment=[SAPSettingsAttachment new];attachment.host=host;attachment.scroll=list;
    attachment.bottomChrome=[SAPBottomChrome new];
    attachment.baseBottom=list.contentInset.bottom;attachment.appliedBottom=list.contentInset.bottom;
    SAPDownloadsEntry *entry=[SAPDownloadsEntry new];entry.settingsHost=host;attachment.entry=entry;
    [list addSubview:entry.view];
    objc_setAssociatedObject(host,SAPAttachmentKey,attachment,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [list addObserver:attachment forKeyPath:@"contentSize" options:NSKeyValueObservingOptionNew context:SAPContentSizeContext];attachment.observing=YES;
    [attachment layout];
}
static void SAPSettingsLoaded(id self,SEL selector) {originalSettingsLoad(self,selector);SAPAttachSettings(self);}
static void SAPSettingsLayout(id self,SEL selector) {originalSettingsLayout(self,selector);SAPAttachSettings(self);}
__attribute__((visibility("default"))) UIViewController *SAPCreateDownloadsSettings(void) {return [SAPDownloadsSettings new];}
// The lyrics page, also created directly by the UI fixtures.
__attribute__((visibility("default"))) UIViewController *SAPCreateLyricsSettings(void) {return [SAPLyricsSettings new];}
void SAPInstallDownloadSettings(void) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPInstallDownloadSettings();});return;}
    if(settingsInstalled)return;
        #ifdef SAP_UI_FIXTURE
        Class cls=NSClassFromString(@"SAPFixtureEeveeSettingsViewController");
#else
        Class cls=NSClassFromString(@"EeveeSpotify.EeveeSettingsViewController");
#endif
        if(!cls)cls=NSClassFromString(@"_TtC12EeveeSpotify27EeveeSettingsViewController");
        if(!cls){settingsInstallStatus=@"settings_host_not_loaded";return;}
        SEL load=@selector(viewDidLoad),layout=@selector(viewDidLayoutSubviews);
        Method lm=class_getInstanceMethod(cls,load),dm=class_getInstanceMethod(cls,layout);
        if(!lm || !dm || method_getNumberOfArguments(lm)!=2 || method_getNumberOfArguments(dm)!=2){settingsInstallStatus=@"settings_host_signature_mismatch";return;}
        originalSettingsLoad=(void *)method_getImplementation(lm);originalSettingsLayout=(void *)method_getImplementation(dm);
        // Add overrides only to Eevee's existing controller; inherited UIKit methods are not changed.
        class_replaceMethod(cls,load,(IMP)SAPSettingsLoaded,method_getTypeEncoding(lm));
        class_replaceMethod(cls,layout,(IMP)SAPSettingsLayout,method_getTypeEncoding(dm));
        settingsInstalled=YES;settingsInstallStatus=@"settings_host_hook_installed";
}
