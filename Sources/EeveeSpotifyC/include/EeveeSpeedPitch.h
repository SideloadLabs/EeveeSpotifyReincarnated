// speed and pitch done to Spotify's sound (SpeedPitch/README.md).
// main thread only, except the log sink.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// hooks Spotify's audio output and player. call once at launch, before Spotify sets up its audio: a connection
// it made earlier is only taken over when it makes one again. `log` gets the engine's lines, on any thread but
// the render thread. NO when Spotify's output could not be reached at all.
BOOL EeveeSpeedPitchInstall(BOOL pitchFollowsSpeed, void (^log)(NSString *message));

// speed needs Spotify's mixer fed through the engine, which happens once Spotify connects its output.
BOOL EeveeSpeedPitchSpeedAvailable(void);
BOOL EeveeSpeedPitchPitchAvailable(void);

// 1 is normal (0.25...4). while speed is unavailable only 1 is taken, and a speed set before waits for it.
double EeveeSpeedPitchSpeed(void);
void EeveeSpeedPitchSetSpeed(double speed);

// semitones up or down (-24...24). while pitch follows a speed other than 1, the speed sets the pitch instead.
float EeveeSpeedPitchSemitones(void);
void EeveeSpeedPitchSetSemitones(float semitones);

// speed by resampling (faster and higher, like a record) instead of the time stretch.
BOOL EeveeSpeedPitchPitchFollowsSpeed(void);
void EeveeSpeedPitchSetPitchFollowsSpeed(BOOL follows);

NS_ASSUME_NONNULL_END
