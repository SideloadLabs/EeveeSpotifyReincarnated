// Speed and pitch: two sliders in the more button's menu, done to Spotify's sound, under either look.
#import <UIKit/UIKit.h>
void SGPlayerMenuWatchMoreButton(UIView *button);
double SGPlayerSpeed(void);
BOOL SGPlayerSpeedAllowed(void);
void SGSetPlayerSpeed(double speed);
float SGPlayerPitch(void);
void SGSetPlayerPitch(float semitones);
BOOL SGPlayerPitchAvailable(void);
