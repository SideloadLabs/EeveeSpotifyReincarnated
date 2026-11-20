// Apple's time-pitch unit (AUNewTimePitch) with Varispeed beside it, for the render thread. fed one of two ways:
// - pull: the unit asks a source for about rate × the frames it returns, so a rate over 1 drains Spotify's
//   mixer faster. this is how speed works.
// - in place: a finished buffer goes through a FIFO at rate 1. pitch only.
// the stretch delays the sound by 4096 frames (93 ms at 44.1 kHz). Render and Process never allocate, lock or
// log; the rest is for other threads.
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

// any thread, from the next buffer. rate 1 is normal speed.
void EeveeTimePitchSetRate(EeveeTimePitch *unit, float rate);
void EeveeTimePitchSetSemitones(EeveeTimePitch *unit, float semitones);
// pull mode: speed by resampling (Varispeed), so pitch rises with speed like a record. Varispeed plays 1x too
// while following, and the semitones only apply at 1x.
void EeveeTimePitchSetFollows(EeveeTimePitch *unit, bool follows);

// which unit renders only changes in EeveeTimePitchReset, never mid-sound: true when the settings want the
// other, and the caller stops rendering, resets and starts again.
bool EeveeTimePitchSwitchPending(const EeveeTimePitch *unit);
// drops the sound held and picks the unit to render. only while nothing renders.
void EeveeTimePitchReset(EeveeTimePitch *unit);

// pull mode: `frames` frames of output into `data`.
OSStatus EeveeTimePitchRender(EeveeTimePitch *unit, UInt32 frames, AudioBufferList *data);
// in place mode: pitch-shifts each channel's `frames` samples; false, leaving them, when it can't.
bool EeveeTimePitchProcess(EeveeTimePitch *unit, float *const *channels, UInt32 frames);

// for the log: FIFO pulls it couldn't fully answer, failed renders, the most input asked for at once, and the
// seconds of input used.
typedef struct {
    UInt32 underruns, failures, largestPull;
    double consumed;
} EeveeTimePitchStats;
EeveeTimePitchStats EeveeTimePitchReadStats(EeveeTimePitch *unit);
