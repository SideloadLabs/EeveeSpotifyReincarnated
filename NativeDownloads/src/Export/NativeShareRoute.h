#pragma once
#import <Foundation/Foundation.h>
@protocol SAPShareControllerNode <NSObject>
- (id)parentViewController;
- (id)presentingViewController;
- (id)presentedViewController;
@end
// Match the actual presenting controller, never a common window or root shared
// by unrelated screens. The detached owner is valid only inside a handoff fence.
static inline BOOL SAPSharePresenterOwnsMenu(id<SAPShareControllerNode> presenter,id<SAPShareControllerNode> menu,id detachedOwner,BOOL fenceCurrent) {
    if(!presenter)return NO;
    if(fenceCurrent && detachedOwner==presenter)return YES;
    if(!menu)return NO;
    id<SAPShareControllerNode> node=menu;
    for(unsigned depth=0;node && depth<16;depth++){
        if(node==presenter || [node presentingViewController]==presenter)return YES;
        id<SAPShareControllerNode> parent=[node parentViewController];if(parent==node)break;node=parent;
    }
    node=presenter;
    for(unsigned depth=0;node && depth<16;depth++){
        if(node==menu)return YES;
        id<SAPShareControllerNode> parent=[node parentViewController];if(parent==node)break;node=parent;
    }
    return NO;
}

// A presenting ancestor may already contain the Spotify menu. In that case
// present from the visible menu itself rather than suppressing the handoff.
static inline id SAPShareAvailablePresenter(id<SAPShareControllerNode> presenter,id<SAPShareControllerNode> menu){
 if(!SAPSharePresenterOwnsMenu(presenter,menu,nil,NO))return nil;
 if([presenter presentedViewController])return [menu presentedViewController]?nil:menu;
 return presenter;
}
