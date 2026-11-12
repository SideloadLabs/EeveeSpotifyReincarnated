// Whether the user follows the page's artist, read from Spotify's collection state (following saves the
// artist to the collection) rather than the Follow button, whose only state is its localized title.
// The provider is the one Spotify's own code uses, kept weakly.
#import <os/lock.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "include/Tweak.h"
#define SGLog(...) ((void)0)
%config(generator=internal);
%group EeveePixieArtistFollow

@protocol EeveePixieCollectionState <NSObject>
+ (id)saved;
- (BOOL)contains:(id)state;
- (NSInteger)rawValue;
@end

@protocol EeveePixieCollectionStateProvider <NSObject>
- (id)subscribeCollectionStateForURL:(NSURL *)url completion:(void (^)(id state, NSError *error))completion;
@end

static __weak id sg_provider;
// Guards sg_provider and keepProvider's `logged`; a lock of this file's own, so Spotify's threads binding rows
// never queue behind another file's.
static os_unfair_lock sg_providerLock = OS_UNFAIR_LOCK_INIT;

// Called from wherever Spotify reaches for its provider, any thread.
static void keepProvider(id provider) {
    if (!provider || ![provider respondsToSelector:@selector(subscribeCollectionStateForURL:completion:)]) return;
    // Nearly every call brings the provider already kept; a weak load is atomic, and the lock below decides.
    if (provider == sg_provider) return;
    static NSMutableSet<NSString *> *logged;
    NSString *name = nil;
    os_unfair_lock_lock(&sg_providerLock);
    if (provider != sg_provider) {
        sg_provider = provider;
        if (!logged) logged = [NSMutableSet set];
        name = NSStringFromClass([provider class]);
        if ([logged containsObject:name]) name = nil;
        else [logged addObject:name];
    }
    os_unfair_lock_unlock(&sg_providerLock);
    if (name) SGLog(@"redesign artist: collection state from %@", name);
}

static __weak id sg_platform;

static id currentProvider(void) {
    os_unfair_lock_lock(&sg_providerLock);
    id provider = sg_provider;
    os_unfair_lock_unlock(&sg_providerLock);
    if (!provider && [sg_platform respondsToSelector:@selector(stateProvider)]) {
        provider = [sg_platform performSelector:@selector(stateProvider)];
        keepProvider(provider);
    }
    return provider;
}

%hook SPTCollectionPlatformImplementation
- (id)initWithCosmosDataLoader:(id)loader isGatedEntityRelationsEnabled:(BOOL)gated {
    id platform = %orig;
    sg_platform = platform;
    return platform;
}
- (id)stateProvider {
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC23Collection_PlatformImpl22CollectionPlatformImpl
- (id)stateProvider {
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC23Collection_PlatformImpl27CollectionPlatformMigration
- (id)stateProvider {
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC26AlignedCuration_CommonImpl21ACUCollectionPlatform
- (id)stateProvider {
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC23Collection_PlatformImpl35CollectionPlatformStateProviderImpl
- (id)subscribeCollectionStateForURL:(id)url completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURL:(id)url inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
%end

%hook _TtC26AlignedCuration_CommonImpl25ACUEsperantoStateProvider
- (id)subscribeCollectionStateForURL:(id)url completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURL:(id)url inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
%end

// The Follow element asks Curation's provider, which wraps the collection one.
%hook _TtC21Curation_PlatformImpl30CUPStateProviderImplementation
- (id)subscribeCollectionStateForURL:(id)url inContext:(id)context completion:(id)completion {
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "collectionPlatformStateProvider");
    if (ivar) keepProvider(object_getIvar(self, ivar));
    return %orig;
}
%end

#pragma mark - one subscription per page

// Held by the page, so the subscription ends with it.
@interface EeveePixieFollowWatch : NSObject
@property (nonatomic, copy) NSURL *uri;
@property (nonatomic, strong) id token;
@property (nonatomic) BOOL subscribed;
@property (nonatomic) NSInteger following;   // -1 until the first state arrives
@property (nonatomic, copy) void (^changed)(void);
@end

@implementation EeveePixieFollowWatch
- (void)dealloc {
    if ([_token respondsToSelector:@selector(cancel)]) [_token cancel];
}
@end

static char kWatchKey;

// The artist the page is for. The artist page's controllers carry no URI, but the header's ⋯ does:
// Components.UI.ContextMenuButton-<artist id>.
static NSURL *artistURI(UIView *header, NSString *unused) {
    NSString *uri = EeveePixieArtistURIForHeader(header);
    return uri ? [NSURL URLWithString:uri] : nil;
}

static void subscribe(EeveePixieFollowWatch *watch, id provider) {
    Class stateClass = NSClassFromString(@"SPTCollectionPlatformState");
    if (![stateClass respondsToSelector:@selector(saved)]) return;
    id saved = [(Class<EeveePixieCollectionState>)stateClass saved];
    __weak EeveePixieFollowWatch *weakWatch = watch;
    NSURL *uri = watch.uri;
    watch.subscribed = YES;
    SGLog(@"redesign artist: follow subscribes for %@ on %@", uri.absoluteString, NSStringFromClass([provider class]));
    watch.token = [(id<EeveePixieCollectionStateProvider>)provider subscribeCollectionStateForURL:uri completion:^(id state, NSError *error) {
        if (error || ![state respondsToSelector:@selector(contains:)]) {
            SGLog(@"redesign artist: follow state for %@ unreadable: %@ %@", uri.absoluteString, [state class], error);
            return;
        }
        BOOL following = [(id<EeveePixieCollectionState>)state contains:saved];
        dispatch_async(dispatch_get_main_queue(), ^{
            EeveePixieFollowWatch *current = weakWatch;
            if (!current || current.following == following) return;
            SGLog(@"redesign kit: follow state %ld for %@", (long)raw, uri.absoluteString);
            current.following = following;
            if (current.changed) current.changed();
        });
    }];
}

static BOOL readArtistFollowing(UIView *page, NSString *moreIdentifier, BOOL *following, void (^changed)(void)) {
    if (!page) return NO;
    EeveePixieFollowWatch *watch = objc_getAssociatedObject(page, &kWatchKey);
    NSURL *uri = artistURI(page, moreIdentifier);
    if (!watch || ![watch.uri isEqual:uri]) {
        if (!uri) {
            static __weak UIView *loggedPage;
            if (loggedPage != page) {
                loggedPage = page;
                SGLog(@"redesign artist: follow has no artist URI, more is %@", moreIdentifier);
            }
            return NO;
        }
        watch = [EeveePixieFollowWatch new];
        watch.uri = uri;
        watch.following = -1;
        objc_setAssociatedObject(page, &kWatchKey, watch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    watch.changed = changed;
    id provider = watch.subscribed ? nil : currentProvider();
    if (provider) subscribe(watch, provider);
    if (watch.following < 0) return NO;
    if (following) *following = watch.following == 1;
    return YES;
}

%end

void EeveePixieInstallArtistFollow(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ %init(EeveePixieArtistFollow); });
}

NSInteger EeveePixieArtistFollowing(UIView *header, void (^changed)(void)) {
    BOOL following = NO;
    return readArtistFollowing(header, nil, &following, changed) ? (following ? 1 : 0) : -1;
}
