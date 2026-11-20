// what the speed & pitch files share. Swift only sees include/EeveeSpeedPitch.h.
#import <Foundation/Foundation.h>

// the debug log, through the sink EeveeSpeedPitchInstall takes. never on the render thread.
void EeveeSpeedPitchLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#define SPLog EeveeSpeedPitchLog

#pragma mark - SpeedPitchEngine.m

// whether Spotify's output can be reached; `canSpeed` whether its mixer's connection can be taken too.
BOOL SpeedPitchEngineInstall(BOOL follows, BOOL *canSpeed);
// whether the music's output is fed through the engine, so speed works.
BOOL SpeedPitchEngineTapped(void);
// any thread.
float SpeedPitchEngineSpeed(void);
// seconds of song the mixer has handed over with sound (a podcast's at Spotify's own speed), and seconds since
// it last did (INFINITY before). any thread.
double SpeedPitchEnginePlayedSeconds(void);
double SpeedPitchEngineSecondsSincePlayed(void);
// drops the sound the unit holds, so a seek or skip starts clean. any thread: off the main one it hops there.
void SpeedPitchEngineResetUnit(void);

// main thread from here on.
void SpeedPitchEngineSetSpeed(float speed);
float SpeedPitchEngineSemitones(void);
void SpeedPitchEngineSetSemitones(float semitones);
BOOL SpeedPitchEngineFollows(void);
void SpeedPitchEngineSetFollows(BOOL follows);

#pragma mark - MixerLimit.m

// once at launch: whether the core's limit can follow the speed.
BOOL SpeedPitchMixerLimitInstall(void);
void SpeedPitchMixerLimitSetSpeed(float speed);   // main thread

#pragma mark - SpeedPitchClock.x

// whether Spotify's clock can follow the speed; speed stays off without it.
BOOL SpeedPitchClockInstall(void);
// main thread, before the engine's speed changes.
void SpeedPitchClockSpeedWillChange(float from, float to);
