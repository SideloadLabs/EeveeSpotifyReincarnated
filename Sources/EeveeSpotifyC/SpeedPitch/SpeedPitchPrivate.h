// what the speed & pitch files share. Swift only sees include/EeveeSpeedPitch.h.
#import <Foundation/Foundation.h>

// the debug log (EeveeLog, through the sink EeveeSpeedPitchInstall takes). never on the render thread.
void EeveeSpeedPitchLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#define SPLog EeveeSpeedPitchLog

#pragma mark - SpeedPitchEngine.m: Spotify's audio output

// rebinds Spotify's audio calls. returns whether its output can be reached; `canSpeed` is whether its
// mixer's connection can be taken over too, which speed needs.
BOOL SpeedPitchEngineInstall(BOOL follows, BOOL *canSpeed);
// whether the music's output is fed through the engine (speed works).
BOOL SpeedPitchEngineTapped(void);
// any thread.
float SpeedPitchEngineSpeed(void);
// seconds the music's mixer has handed over with sound, any thread. for a podcast at Spotify's own speed each
// holds that many seconds of the episode.
double SpeedPitchEnginePlayedSeconds(void);
// seconds since the music's mixer last handed any over through the engine, INFINITY before; any thread.
double SpeedPitchEngineSecondsSincePlayed(void);
// drops the sound the unit holds, so playback after a seek or skip starts clean. on whatever thread
// Spotify's player calls its hooks.
void SpeedPitchEngineResetUnit(void);

// main thread from here on.
void SpeedPitchEngineSetSpeed(float speed);
float SpeedPitchEngineSemitones(void);
void SpeedPitchEngineSetSemitones(float semitones);
BOOL SpeedPitchEngineFollows(void);
void SpeedPitchEngineSetFollows(BOOL follows);

#pragma mark - MixerLimit.m: Spotify's core mixer limit

// rebinds Spotify's steady_clock::now, once at launch. returns whether the limit can follow the speed.
BOOL SpeedPitchMixerLimitInstall(void);
// main thread.
void SpeedPitchMixerLimitSetSpeed(float speed);

#pragma mark - SpeedPitchClock.x: Spotify's progress bar

// hooks Spotify's player. returns whether its clock can follow the speed; speed stays off without it.
BOOL SpeedPitchClockInstall(void);
// call on the main thread before the engine's speed changes.
void SpeedPitchClockSpeedWillChange(float from, float to);
