#import "NativeDownloadQuality.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <string.h>

NSString *const SAPNativeDownloadQualityOfferDidChangeNotification=@"SAPNativeDownloadQualityOfferDidChangeNotification";
static NSString *const decisionKey=@"pixie.nativeDownloadQualityHint.v1";
static NSString *const preferencesClassName=@"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation";
static NSString *const dispatcherClassName=@"SPTLinkDispatcherImplementation";
// Pixie captures Spotify's own preferences object and link dispatcher itself, so the hint works on any host
// (EeveeSpotify, Vitrine) and never depends on a host mod's helper functions. Weak: Spotify owns both.
static __weak id capturedPreferences,capturedDispatcher;
typedef NS_ENUM(NSUInteger,SAPQualityDecision){SAPQualityUnknown,SAPQualityOffer,SAPQualityQuiet,SAPQualitySuppressed};
static NSLock *policyLock;
static NSUserDefaults *defaults;
static SAPQualityDecision decision;
static atomic_bool terminal,observationInstalled,preferencesCaptureInstalled,dispatcherCaptureInstalled;

static void loadPolicy(void){
    static dispatch_once_t once;dispatch_once(&once,^{
        policyLock=NSLock.new;defaults=NSUserDefaults.standardUserDefaults;
        id saved=[defaults objectForKey:decisionKey];
        if([saved isEqual:@"offer"])decision=SAPQualityOffer;
        else if([saved isEqual:@"quiet"])decision=SAPQualityQuiet;
        else if([saved isEqual:@"suppressed"])decision=SAPQualitySuppressed;
        atomic_store_explicit(&terminal,decision==SAPQualitySuppressed,memory_order_release);
    });
}
static void notifyChange(void){
    dispatch_block_t notify=^{[NSNotificationCenter.defaultCenter postNotificationName:SAPNativeDownloadQualityOfferDidChangeNotification object:nil];};
    if(NSThread.isMainThread)notify();else dispatch_async(dispatch_get_main_queue(),notify);
}
// Called with policyLock held. Never invokes a native API or posts notifications.
static void saveDecision(SAPQualityDecision next){
    decision=next;
    if(next==SAPQualitySuppressed)atomic_store_explicit(&terminal,true,memory_order_release);
    NSString *saved=next==SAPQualityOffer?@"offer":next==SAPQualityQuiet?@"quiet":@"suppressed";
    [defaults setObject:saved forKey:decisionKey];
}
// Spotify 9.1.90 raw download enum: 1 Low, 2 Normal, 3 High,
// 4 Very high, 5 Lossless. Exact labels proven by stock Settings' formatter
// 0x10434e0ec and SPTStrings _i18n.KEYS/_i18n.en (research report).
static BOOL highQuality(NSInteger value){return value==3||value==4||value==5;}
static void observeHigh(NSInteger value){
    // After a terminal decision the hook forwards the original IMP and exits:
    // no lock, defaults access, getter, queued work, or notification.
    if(atomic_load_explicit(&terminal,memory_order_acquire)||!highQuality(value))return;
    [policyLock lock];BOOL changed=decision!=SAPQualitySuppressed;
    if(changed)saveDecision(SAPQualitySuppressed);
    [policyLock unlock];if(changed)notifyChange();
}
static BOOL methodABI(Method method,const char *result,BOOL setter){
    if(!method||method_getNumberOfArguments(method)!=(setter?3u:2u))return NO;
    char type[32]={0};method_getReturnType(method,type,sizeof(type));if(strcmp(type,result))return NO;
    method_getArgumentType(method,0,type,sizeof(type));if(strcmp(type,"@"))return NO;
    method_getArgumentType(method,1,type,sizeof(type));if(strcmp(type,":"))return NO;
    if(setter){method_getArgumentType(method,2,type,sizeof(type));if(strcmp(type,@encode(NSInteger)))return NO;}
    return YES;
}
// Wrap an instance method so `object` is remembered before the original runs. The original is always called
// unchanged with the same arguments; nothing is read or written on Spotify's object.
static BOOL methodMatches(Method method,const char *result,unsigned arguments){
    if(!method||method_getNumberOfArguments(method)!=arguments)return NO;
    char type[32]={0};method_getReturnType(method,type,sizeof(type));return !strcmp(type,result);
}
static void installPreferencesCapture(Class cls){
    if(atomic_load_explicit(&preferencesCaptureInstalled,memory_order_acquire))return;
    static dispatch_once_t once;dispatch_once(&once,^{
        // The object is made once at launch: -initWithScheduler: sees it first. The two getters cover a build
        // where it was made before this library loaded (Spotify reads them from its settings and player).
        SEL init=NSSelectorFromString(@"initWithScheduler:");Method initMethod=class_getInstanceMethod(cls,init);
        if(methodMatches(initMethod,"@",3)){
            IMP original=method_getImplementation(initMethod);
            IMP replacement=imp_implementationWithBlock(^id(id object,id scheduler){
                id made=((id(*)(id,SEL,id))original)(object,init,scheduler);
                if(!atomic_load_explicit(&terminal,memory_order_acquire))capturedPreferences=made;
                return made;
            });
            if(!class_addMethod(cls,init,replacement,method_getTypeEncoding(initMethod)))method_setImplementation(initMethod,replacement);
        }
        for(NSString *name in @[@"audioSyncBitrate",@"playbackSpeed"]) {
            SEL getter=NSSelectorFromString(name);Method method=class_getInstanceMethod(cls,getter);
            if(!methodABI(method,@encode(NSInteger),NO))continue;
            IMP original=method_getImplementation(method);
            IMP replacement=imp_implementationWithBlock(^NSInteger(id object){
                if(!atomic_load_explicit(&terminal,memory_order_acquire))capturedPreferences=object;
                return ((NSInteger(*)(id,SEL))original)(object,getter);
            });
            if(!class_addMethod(cls,getter,replacement,method_getTypeEncoding(method)))method_setImplementation(method,replacement);
        }
        atomic_store_explicit(&preferencesCaptureInstalled,true,memory_order_release);
    });
}
static void installDispatcherCapture(void){
    if(atomic_load_explicit(&dispatcherCaptureInstalled,memory_order_acquire))return;
    Class cls=NSClassFromString(dispatcherClassName);if(!cls)return;
    static dispatch_once_t once;dispatch_once(&once,^{
        // -setMainUILoaded: is the last call of the dispatcher's setup; every later navigation also passes by.
        SEL loaded=NSSelectorFromString(@"setMainUILoaded:");Method loadedMethod=class_getInstanceMethod(cls,loaded);
        if(methodMatches(loadedMethod,"v",3)){
            IMP original=method_getImplementation(loadedMethod);
            IMP replacement=imp_implementationWithBlock(^(id object,BOOL value){
                capturedDispatcher=object;((void(*)(id,SEL,BOOL))original)(object,loaded,value);
            });
            if(!class_addMethod(cls,loaded,replacement,method_getTypeEncoding(loadedMethod)))method_setImplementation(loadedMethod,replacement);
        }
        SEL navigate=NSSelectorFromString(@"navigateToURI:options:reason:completionHandler:resultHandler:");Method navigateMethod=class_getInstanceMethod(cls,navigate);
        if(methodMatches(navigateMethod,"v",7)){
            IMP original=method_getImplementation(navigateMethod);
            IMP replacement=imp_implementationWithBlock(^(id object,NSURL *uri,long long options,id reason,id completion,id result){
                capturedDispatcher=object;((void(*)(id,SEL,NSURL *,long long,id,id,id))original)(object,navigate,uri,options,reason,completion,result);
            });
            if(!class_addMethod(cls,navigate,replacement,method_getTypeEncoding(navigateMethod)))method_setImplementation(navigateMethod,replacement);
        }
        atomic_store_explicit(&dispatcherCaptureInstalled,true,memory_order_release);
    });
}
void SAPInstallNativeDownloadQualityObservation(void){
    loadPolicy();if(atomic_load_explicit(&terminal,memory_order_acquire)||atomic_load_explicit(&observationInstalled,memory_order_acquire))return;
    Class cls=NSClassFromString(preferencesClassName);SEL setter=NSSelectorFromString(@"setAudioSyncBitrate:");
    Method method=cls?class_getInstanceMethod(cls,setter):NULL;
    // Missing startup classes may become available by the next explicit entry.
    // Do not consume installation once until the exact native ABI is available.
    if(!methodABI(method,"v",YES))return;
    installPreferencesCapture(cls);installDispatcherCapture();
    static dispatch_once_t once;dispatch_once(&once,^{
        IMP original=method_getImplementation(method);
        IMP replacement=imp_implementationWithBlock(^(id object,NSInteger value){
            ((void(*)(id,SEL,NSInteger))original)(object,setter,value);
            observeHigh(value);
        });
        if(!class_addMethod(cls,setter,replacement,method_getTypeEncoding(method)))
            method_setImplementation(class_getInstanceMethod(cls,setter),replacement);
        atomic_store_explicit(&observationInstalled,true,memory_order_release);
    });
}
BOOL SAPShouldOfferNativeDownloadQuality(void){
    NSCAssert(NSThread.isMainThread,@"Download quality UI decisions require the main thread");
    SAPInstallNativeDownloadQualityObservation();if(atomic_load_explicit(&terminal,memory_order_acquire))return NO;
    [policyLock lock];SAPQualityDecision current=decision;[policyLock unlock];
    if(current!=SAPQualityUnknown)return current==SAPQualityOffer;
    // Nil until Spotify has made the object; its settings are in once the playback speed (a percent, never 0)
    // is set. Before that every user setting reads 0, which is not the user's. Reading changes nothing.
    id preferences=capturedPreferences;Class cls=NSClassFromString(preferencesClassName);
    SEL getter=NSSelectorFromString(@"audioSyncBitrate"),speed=NSSelectorFromString(@"playbackSpeed");
    if(!preferences||!cls||![preferences isKindOfClass:cls]||!methodABI(class_getInstanceMethod(object_getClass(preferences),getter),@encode(NSInteger),NO)||
       !methodABI(class_getInstanceMethod(object_getClass(preferences),speed),@encode(NSInteger),NO))return NO;
    if(((NSInteger(*)(id,SEL))objc_msgSend)(preferences,speed)<=0)return NO;
    NSInteger quality=((NSInteger(*)(id,SEL))objc_msgSend)(preferences,getter);
    SAPQualityDecision next=quality==2?SAPQualityOffer:quality==1?SAPQualityQuiet:highQuality(quality)?SAPQualitySuppressed:SAPQualityUnknown;
    if(next==SAPQualityUnknown)return NO; // Future values remain unknown, never guessed.
    [policyLock lock];BOOL changed=decision==SAPQualityUnknown;
    if(changed)saveDecision(next);
    BOOL offered=decision==SAPQualityOffer;[policyLock unlock];
    if(changed)notifyChange();return offered;
}
// Navigate through Spotify's own link dispatcher, the way a tap on a spotify: link does. 9.1.88 and later no
// longer have -navigateToURI:options:interactionID:; the full form needs a navigation reason. A nil reason
// crashes (Swift reads it as an enum), so build one exactly as Spotify does. NO when the dispatcher is unknown.
static BOOL openSpotifyURI(NSURL *uri){
    id dispatcher=capturedDispatcher;if(!uri||!dispatcher)return NO;
    SEL shortForm=NSSelectorFromString(@"navigateToURI:options:interactionID:");
    if([dispatcher respondsToSelector:shortForm]){((void(*)(id,SEL,NSURL *,long long,id))objc_msgSend)(dispatcher,shortForm,uri,0,nil);return YES;}
    SEL full=NSSelectorFromString(@"navigateToURI:options:reason:completionHandler:resultHandler:");
    Class reasonClass=NSClassFromString(@"SPTUBINavigationReason");SEL init=NSSelectorFromString(@"initWithSourceApplication:interactionID:");
    id reason=nil;
    if([reasonClass instancesRespondToSelector:init]){
        // alloc and init by hand: init consumes what alloc made and returns its own +1.
        void *raw=((void *(*)(Class,SEL))objc_msgSend)(reasonClass,@selector(alloc));
        reason=CFBridgingRelease(((void *(*)(void *,SEL,id,id))objc_msgSend)(raw,init,nil,nil));
    }
    if(![dispatcher respondsToSelector:full]||!reason)return NO;
    ((void(*)(id,SEL,NSURL *,long long,id,id,id))objc_msgSend)(dispatcher,full,uri,0,reason,nil,nil);return YES;
}
BOOL SAPDismissNativeDownloadQualityOfferAndOpenSettings(void){
    NSCAssert(NSThread.isMainThread,@"Download quality navigation requires the main thread");
    loadPolicy();[policyLock lock];BOOL changed=decision!=SAPQualitySuppressed;
    if(changed)saveDecision(SAPQualitySuppressed);
    [policyLock unlock];if(!changed)return NO;
    notifyChange();
    return openSpotifyURI([NSURL URLWithString:@"spotify:settings:quality"]);
}
