// Mod Settings > Audio effects: the effects' switch with what the engine is doing under it, then a card per
// effect, each opening out into its controls while its switch is on. Everything on it goes through
// AudioEffects.h's setters, so it applies as it changes, a slider while it is dragged.
//
//     AudioEffectsPage.m          the page: the switch, the status, the effects' cards, their sliders and choices
//     SGDSPCurveView.m            the equalizer's and the compander's curve, with a handle to drag per band
//     AudioEffectsLibraryPage.m   a file effect's library (the convolver's, ViPER DDC's, Liveprog's) and the GraphicEQ editor
//
// Main thread only.
#import <UIKit/UIKit.h>
#import "AudioEffects.h"

UIViewController *SGDSPSettingsPage(void);
// What the Mod Settings row reads out: Off, On, or how many effects are on.
NSString *SGDSPSummary(void);

// The pages the effects' rows push (AudioEffectsLibraryPage.m).
UIViewController *SGDSPLibraryPage(SGDSPFileKind kind);
UIViewController *SGDSPGraphicEqPage(void);
// The choice of a file effect's library, "None" when there is none.
NSString *SGDSPChosenFile(SGDSPFileKind kind);
