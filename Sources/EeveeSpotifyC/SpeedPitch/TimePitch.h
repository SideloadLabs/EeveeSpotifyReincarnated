// Apple's time-pitch unit (AUNewTimePitch, the one behind AVAudioUnitTimePitch) with Varispeed beside it,
// wrapped for the render thread. it is fed one of two ways:
// - pull: the unit asks a source for about rate × the frames it returns, so a rate over 1 drains the source
//   faster. this is how speed works, the source being Spotify's mixer.
// - in place: a finished buffer goes through a FIFO at rate 1. pitch only, for when there is no source.
// the stretch delays the sound by 4096 frames (93 ms at 44.1 kHz).
//
// EeveeTimePitchRender and EeveeTimePitchProcess run on the render thread, so they never allocate, lock,
// log or send a message. the rest is for other threads.
#import <AudioToolbox/AudioToolbox.h>
#import <stdbool.h>

enum { kEeveeTimePitchMaxChannels = 2, kEeveeTimePitchMaxFrames = 4096 };

typedef struct EeveeTimePitch EeveeTimePitch;

// fills `data` (one buffer per channel) with the next `frames` frames of input.
typedef OSStatus (*EeveeTimePitchSource)(void *context, UInt32 frames, AudioBufferList *data);

// float, non-interleaved, 1 or 2 channels. pull mode with a source, in place without. NULL on failure.
EeveeTimePitch *EeveeTimePitchCreate(double sampleRate, UInt32 channels, EeveeTimePitchSource source, void *context);
double EeveeTimePitchSampleRate(const EeveeTimePitch *unit);
UInt32 EeveeTimePitchChannels(const EeveeTimePitch *unit);

// any thread, used from the next buffer. rate 1 is normal speed (0.25...4).
void EeveeTimePitchSetRate(EeveeTimePitch *unit, float rate);
void EeveeTimePitchSetSemitones(EeveeTimePitch *unit, float semitones);

// pull mode: speed by resampling (Varispeed) instead of stretching, so pitch rises with speed like a record.
// while following, Varispeed plays rate 1 too, so going back to normal speed doesn't switch units, and the
// semitones only apply at rate 1.
void EeveeTimePitchSetFollows(EeveeTimePitch *unit, bool follows);

// which unit renders only changes in EeveeTimePitchReset, so the render thread never switches to a unit
// still holding old sound. true when the settings since then want the other unit: the caller stops
// rendering, resets and starts again.
bool EeveeTimePitchSwitchPending(const EeveeTimePitch *unit);

// drops the sound held and picks the unit to render. only while nothing renders.
void EeveeTimePitchReset(EeveeTimePitch *unit);

// pull mode: `frames` frames of output into `data`.
OSStatus EeveeTimePitchRender(EeveeTimePitch *unit, UInt32 frames, AudioBufferList *data);

// in place mode: pitch-shifts `frames` samples of each channel, the unit's latency later. false, leaving
// them untouched, when it can't.
bool EeveeTimePitchProcess(EeveeTimePitch *unit, float *const *channels, UInt32 frames);

// diagnostics, any thread.
UInt32 EeveeTimePitchUnderruns(const EeveeTimePitch *unit);   // FIFO pulls it couldn't fully answer
UInt32 EeveeTimePitchFailures(const EeveeTimePitch *unit);
double EeveeTimePitchLatency(const EeveeTimePitch *unit);      // seconds
UInt32 EeveeTimePitchLargestPull(const EeveeTimePitch *unit);  // most input frames asked for at once
uint64_t EeveeTimePitchConsumed(const EeveeTimePitch *unit);   // input frames used
