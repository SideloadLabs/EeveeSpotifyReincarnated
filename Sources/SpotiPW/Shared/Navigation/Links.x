#import "Core/SGCore.h"
#import "Headers/SPTLinkDispatcherImplementation.h"
#import "Links.h"
#import <objc/message.h>
static __weak SPTLinkDispatcherImplementation *sg_linkDispatcher;
id SGLinkDispatcher(void){return sg_linkDispatcher;}
BOOL SGOpenSpotifyURI(NSURL*uri){SPTLinkDispatcherImplementation*d=sg_linkDispatcher;if(!uri||![d respondsToSelector:@selector(navigateToURI:options:interactionID:)])return NO;[d navigateToURI:uri options:0 interactionID:nil];return YES;}
static id send0(id t,SEL s){if(![t respondsToSelector:s])return nil;return ((id(*)(id,SEL))objc_msgSend)(t,s);}
static id send1(id t,SEL s,id a){if(![t respondsToSelector:s])return nil;return ((id(*)(id,SEL,id))objc_msgSend)(t,s,a);}
SGLinkRoute SGSpotifyURIRoute(NSURL*uri,NSString**via){if(via)*via=nil;if(!uri)return SGLinkRouteNone;id lh=send0(sg_linkDispatcher,@selector(spotifyLinkHandler));id reg=send0(lh,@selector(URISubtypeRegistry));id hs=send0(reg,@selector(handlers));if(![hs conformsToProtocol:@protocol(NSFastEnumeration)])return SGLinkRouteUnknown;SEL can=@selector(URISubtypeHandlerCanHandleURI:);for(id h in hs){if(![h respondsToSelector:can])continue;if(((BOOL(*)(id,SEL,id))objc_msgSend)(h,can,uri)){if(via)*via=NSStringFromClass([h class]);return SGLinkRouteOpens;}}return SGLinkRouteNone;}
NSURL*SGSpotifyURIFromText(NSString*text){NSString*t=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!t.length)return nil;NSURLComponents*p=[NSURLComponents componentsWithString:t];if([p.scheme.lowercaseString hasPrefix:@"http"]&&[p.host.lowercaseString isEqualToString:@"open.spotify.com"]){NSMutableArray*a=[NSMutableArray array];for(NSString*x in [p.path componentsSeparatedByString:@"/"])if(x.length)[a addObject:x];if(a.count&&[a[0] hasPrefix:@"intl-"])[a removeObjectAtIndex:0];if(a.count>=2)return [NSURL URLWithString:[@"spotify:" stringByAppendingString:[a componentsJoinedByString:@":"]]];}return [NSURL URLWithString:t];}
%hook SPTLinkDispatcherImplementation
- (void)setMainUILoaded:(BOOL)loaded{%orig;sg_linkDispatcher=(id)self;}
%end
%ctor{%init;}
