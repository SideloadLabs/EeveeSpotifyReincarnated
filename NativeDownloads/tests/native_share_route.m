#import <Foundation/Foundation.h>
#import "NativeShareRoute.h"
#include <assert.h>
@interface Node:NSObject<SAPShareControllerNode>
@property(nonatomic,strong) Node *parentViewController,*presentingViewController,*presentedViewController;
@end
@implementation Node @end
int main(void){@autoreleasepool {
 Node *root=[Node new],*sheet=[Node new],*menu=[Node new],*child=[Node new],*sibling=[Node new];
 sheet.presentingViewController=root;menu.parentViewController=sheet;child.parentViewController=menu;sibling.parentViewController=root;
 assert(SAPSharePresenterOwnsMenu(menu,menu,nil,NO));
 assert(SAPSharePresenterOwnsMenu(child,menu,nil,NO));
 assert(SAPSharePresenterOwnsMenu(sheet,menu,nil,NO));
 assert(SAPSharePresenterOwnsMenu(root,menu,nil,NO));
 assert(!SAPSharePresenterOwnsMenu(sibling,menu,nil,NO));
 assert(!SAPSharePresenterOwnsMenu(root,nil,root,NO));
 assert(SAPSharePresenterOwnsMenu(root,nil,root,YES));
 assert(!SAPSharePresenterOwnsMenu(sibling,nil,root,YES));
 assert(!SAPSharePresenterOwnsMenu(nil,menu,nil,YES));
 root.presentedViewController=sheet;
 assert(SAPShareAvailablePresenter(root,menu)==menu);
 menu.presentedViewController=child;assert(SAPShareAvailablePresenter(root,menu)==nil);
 menu.presentedViewController=nil;assert(SAPShareAvailablePresenter(menu,menu)==menu);
 assert(SAPShareAvailablePresenter(sibling,menu)==nil);
 Node *cycle=[Node new];cycle.parentViewController=cycle;
 assert(!SAPSharePresenterOwnsMenu(sibling,cycle,nil,NO));cycle.parentViewController=nil;
 puts("PASS native More exact presenter scope, wrapped payload fallback, detached fence, unrelated UI exclusion and bounded ancestry");
}return 0;}
