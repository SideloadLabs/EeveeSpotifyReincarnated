#import <AudioToolbox/AudioToolbox.h>
#import <stdbool.h>
enum { kSGTimePitchMaxChannels = 2, kSGTimePitchMaxFrames = 4096 };
typedef struct SGTimePitch SGTimePitch;
typedef OSStatus (*SGTimePitchSource)(void *context, UInt32 frames, AudioBufferList *data);
SGTimePitch *SGTimePitchCreate(double sampleRate, UInt32 channels, SGTimePitchSource source, void *context);
double SGTimePitchSampleRate(const SGTimePitch *unit);
UInt32 SGTimePitchChannels(const SGTimePitch *unit);
void SGTimePitchSetRate(SGTimePitch *unit, float rate);
void SGTimePitchSetSemitones(SGTimePitch *unit, float semitones);
void SGTimePitchReset(SGTimePitch *unit);
OSStatus SGTimePitchRender(SGTimePitch *unit, UInt32 frames, AudioBufferList *data);
bool SGTimePitchProcess(SGTimePitch *unit, float *const *channels, UInt32 frames);
UInt32 SGTimePitchUnderruns(const SGTimePitch *unit);
UInt32 SGTimePitchFailures(const SGTimePitch *unit);
double SGTimePitchLatency(const SGTimePitch *unit);
UInt32 SGTimePitchLargestPull(const SGTimePitch *unit);
uint64_t SGTimePitchConsumed(const SGTimePitch *unit);
