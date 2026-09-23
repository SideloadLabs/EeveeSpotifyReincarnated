#import "Core/SGCore.h"
@interface UIViewController(SPWNavigationBarState)
- (NSInteger)preferredNavigationBarState;
- (BOOL)prefersLiquidGlassNavigationBar;
@end
static BOOL spwWantsNoBar(UIViewController*p){if(![p respondsToSelector:@selector(preferredNavigationBarState)]||p.preferredNavigationBarState!=2)return NO;return !([p respondsToSelector:@selector(prefersLiquidGlassNavigationBar)]&&p.prefersLiquidGlassNavigationBar);}
%hook SPNavigationController
- (void)navigationController:(UINavigationController*)controller willShowViewController:(UIViewController*)page animated:(BOOL)animated{%orig;if(controller.navigationBarHidden||!spwWantsNoBar(page))return;[controller setNavigationBarHidden:YES animated:animated];}
%end
%ctor{%init;}
