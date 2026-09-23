// A switch that glows: a capsule whose rim is a slowly circling rainbow with a soft glow of the same
// colours, full when on and softer when off, to invite the tap. A white knob slides on a spring.
// For the one switch of a page that changes the whole app (Redesigned UI in Appearance); every other
// switch stays a UISwitch.
//
// It answers isOn and sends UIControlEventValueChanged the way a UISwitch does, so a page treats both
// alike. The rim stops circling under Reduce Motion, and the glow is left out under Reduce Transparency.
// Threading: main thread only.
#import <UIKit/UIKit.h>

@interface SGGlowSwitch : UIControl
@property (nonatomic, getter=isOn) BOOL on;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end
