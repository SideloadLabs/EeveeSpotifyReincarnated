// Which of the two looks runs: Spotify's own screens with the mod's tweaks on them (Native/), or the
// redesign (Redesigned/), picked by Redesigned UI in Appearance. What does not draw on Spotify's
// screens (Shared/) runs under both. The switch is read once, the first time anything asks, so the
// hooks, the flags and the pages see one answer for the whole launch and a change waits for the restart.
//
// Every hook file of Native/ starts its %ctor with `if (!SGNativeUI()) return;`, every one of
// Redesigned/ with `if (!SGRedesignedUI()) return;`: the two never run together, which is what lets
// each hook the same Spotify class in its own way.
// Threading: safe from any thread.
#import <Foundation/Foundation.h>

#define SGKeyRedesign @"spotifyglass.redesign"

// The redesign is Liquid Glass, and Liquid Glass is UIGlassEffect, which the system renders and which
// no older OS can be given. Below iOS 26 the glass calls in Core/SGGlass.m and Redesigned/Kit/SGRGlass.m
// fall back to a blur, so the redesign does not refuse to run, it runs untested against an older UIKit
// and hangs its layout (issue #37, iOS 17: a scene-update watchdog). So it is offered only where its
// material exists, and below that the native look is the whole mod. Everything this answers NO to
// leaves the switch, the tour's card and the redesign's settings pages out, whatever is stored.
BOOL SGRedesignAvailable(void);

BOOL SGRedesignedUI(void);
BOOL SGNativeUI(void);
// The stored switch rather than the launch's, for settings pages opened after it was flipped: they
// show what the restart will bring.
BOOL SGRedesignedUIStored(void);
