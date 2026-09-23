#import "Core/SGCore.h"
#import "PlayerState.h"
NSString *SGURIString(id uri){if([uri isKindOfClass:NSString.class])return uri;if([uri isKindOfClass:NSURL.class])return ((NSURL*)uri).absoluteString;return nil;}
static NSHashTable *sg_observers; static SPTPlayerState *sg_state; static NSString *sg_key; static BOOL sg_platform;
void SGAddPlayerStateObserver(id o){if(!o)return;if(!sg_observers)sg_observers=[NSHashTable weakObjectsHashTable];[sg_observers addObject:o];}
SPTPlayerState *SGPlayerState(void){return sg_state;}
static NSString *keyOf(SPTPlayerState*s){SPTPlayerOptions*o=[s respondsToSelector:@selector(options)]?s.options:nil;BOOL sh=[o respondsToSelector:@selector(shufflingContext)]&&o.shufflingContext;return [NSString stringWithFormat:@"%@|%@|%d%d%d%d",SGURIString(s.track.URI),SGURIString(s.contextURI),s.isPaused,s.isPlaying,[s respondsToSelector:@selector(isLoading)]&&s.isLoading,sh];}
static void publish(SPTPlayerState*s){sg_state=s;NSString*k=keyOf(s);if([k isEqualToString:sg_key])return;sg_key=k;for(id o in sg_observers.allObjects)[o playerStateDidChange:s];}
static void report(id state,BOOL platform){if(![state isKindOfClass:objc_getClass("SPTPlayerState")])return;dispatch_async(dispatch_get_main_queue(),^{if(platform)sg_platform=YES;else if(sg_platform)return;publish(state);});}
@interface SPWPlayerObserver:NSObject @end
@implementation SPWPlayerObserver
- (void)player:(id)p stateDidChange:(id)s{report(s,NO);}
@end
static SPWPlayerObserver *sg_ownObserver;
%hook _TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation
- (void)player:(id)p stateDidChange:(id)s{%orig;report(s,YES);}
%end
%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)o{%orig;id p=self;static dispatch_once_t once;dispatch_once(&once,^{dispatch_async(dispatch_get_main_queue(),^{sg_ownObserver=[SPWPlayerObserver new];[(id)p addPlayerObserver:sg_ownObserver];id s=[p respondsToSelector:@selector(state)]?[p state]:nil;if(s)report(s,NO);});});}
%end
%ctor{%init;}
