#pragma once
#import <UIKit/UIKit.h>

// Shared with the artist release sheet: one native material and the same rows.
static inline UIVisualEffectView *SAPArtistListMaterial(void) {
    UIVisualEffect *effect;
    if(@available(iOS 26.0,*))effect=[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    else effect=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    return [[UIVisualEffectView alloc]initWithEffect:effect];
}
static inline void SAPApplyArtistListRowBackground(UITableViewCell *cell) {
    UIBackgroundConfiguration *background;
    if(@available(iOS 16.0,*))background=[cell defaultBackgroundConfiguration];
    else background=[UIBackgroundConfiguration listGroupedCellConfiguration];
    background.backgroundColor=[UIColor colorWithWhite:1 alpha:0.1008];
    background.backgroundColorTransformer=nil; background.visualEffect=nil;
    cell.backgroundColor=UIColor.clearColor;cell.backgroundConfiguration=background;
}
