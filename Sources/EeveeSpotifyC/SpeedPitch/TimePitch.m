#import "TimePitch.h"
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

// in place mode's FIFO: a power of two with room for a few of the largest buffers.
enum { kFifoFrames = 16384 };

struct EeveeTimePitch {
    AudioUnit unit;
    AudioUnit vari;                   // pull mode only: Varispeed, NULL in place
    atomic_bool follows;
    _Atomic float rate, semitones;
    atomic_bool resampling;           // which unit renders; changed only by EeveeTimePitchReset
    double sampleRate;
    UInt32 channels;
    EeveeTimePitchSource source;
    void *context;
    float *fifo[kEeveeTimePitchMaxChannels];
    uint64_t written, read;           // render thread only
    Float64 sampleTime;
    struct {
        AudioBufferList list;
        AudioBuffer more[kEeveeTimePitchMaxChannels - 1];
    } output;
    float *outputData[kEeveeTimePitchMaxChannels];
    atomic_uint underruns, failures, largestPull;
    atomic_uint_fast64_t consumed;
};

static OSStatus input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                      UInt32 frames, AudioBufferList *data) {
    EeveeTimePitch *unit = refCon;
    if (frames > atomic_load_explicit(&unit->largestPull, memory_order_relaxed)) {
        atomic_store_explicit(&unit->largestPull, frames, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&unit->consumed, frames, memory_order_relaxed);
    if (unit->source) return unit->source(unit->context, frames, data);

    uint64_t available = unit->written - unit->read;
    UInt32 served = (UInt32)(available < frames ? available : frames);
    if (served < frames) atomic_fetch_add_explicit(&unit->underruns, 1, memory_order_relaxed);
    for (UInt32 c = 0; c < data->mNumberBuffers && c < unit->channels; c++) {
        float *out = data->mBuffers[c].mData;
        if (!out) continue;
        for (UInt32 i = 0; i < served; i++) out[i] = unit->fifo[c][(unit->read + i) & (kFifoFrames - 1)];
        if (served < frames) memset(out + served, 0, (frames - served) * sizeof(float));
        data->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    unit->read += served;
    return noErr;
}

// a new Apple converter of `subType` in `format`, pulling input(); NULL on failure.
static AudioUnit makeUnit(OSType subType, const AudioStreamBasicDescription *format, EeveeTimePitch *owner) {
    AudioComponentDescription description = {kAudioUnitType_FormatConverter, subType, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit unit = NULL;
    if (!component || AudioComponentInstanceNew(component, &unit) != noErr) return NULL;
    UInt32 maxFrames = kEeveeTimePitchMaxFrames;
    AURenderCallbackStruct callback = {input, owner};
    OSStatus status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format, sizeof *format);
    if (!status) status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, format, sizeof *format);
    if (!status) status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof maxFrames);
    if (!status) status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    if (!status) status = AudioUnitInitialize(unit);
    if (!status) return unit;
    AudioComponentInstanceDispose(unit);
    return NULL;
}

EeveeTimePitch *EeveeTimePitchCreate(double sampleRate, UInt32 channels, EeveeTimePitchSource source, void *context) {
    if (sampleRate <= 0 || channels < 1 || channels > kEeveeTimePitchMaxChannels) return NULL;
    EeveeTimePitch *unit = calloc(1, sizeof *unit);
    if (!unit) return NULL;
    unit->sampleRate = sampleRate;
    unit->channels = channels;
    unit->source = source;
    unit->context = context;
    atomic_store(&unit->rate, 1);
    AudioStreamBasicDescription format = {
        .mSampleRate = sampleRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = sizeof(float), .mFramesPerPacket = 1, .mBytesPerFrame = sizeof(float),
        .mChannelsPerFrame = channels, .mBitsPerChannel = 32,
    };
    unit->unit = makeUnit(kAudioUnitSubType_NewTimePitch, &format, unit);
    if (!unit->unit) {
        free(unit);
        return NULL;
    }
    // Varispeed pulls the same source; resampling moves speed and pitch together.
    if (source) unit->vari = makeUnit(kAudioUnitSubType_Varispeed, &format, unit);
    unit->output.list.mNumberBuffers = channels;
    for (UInt32 c = 0; c < channels; c++) {
        if (!source) unit->fifo[c] = calloc(kFifoFrames, sizeof(float));
        unit->outputData[c] = calloc(kEeveeTimePitchMaxFrames, sizeof(float));
    }
    return unit;
}

double EeveeTimePitchSampleRate(const EeveeTimePitch *unit) {
    return unit->sampleRate;
}

UInt32 EeveeTimePitchChannels(const EeveeTimePitch *unit) {
    return unit->channels;
}

void EeveeTimePitchSetRate(EeveeTimePitch *unit, float rate) {
    AudioUnitSetParameter(unit->unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, rate, 0);
    if (unit->vari) AudioUnitSetParameter(unit->vari, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, rate, 0);
    atomic_store(&unit->rate, rate);
}

void EeveeTimePitchSetFollows(EeveeTimePitch *unit, bool follows) {
    atomic_store(&unit->follows, follows);
}

void EeveeTimePitchSetSemitones(EeveeTimePitch *unit, float semitones) {
    AudioUnitSetParameter(unit->unit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, semitones * 100, 0);
    atomic_store(&unit->semitones, semitones);
}

// Varispeed while following (at 1x too, so going back to normal never switches units); the time-pitch unit
// for a stretch, and for pitch alone at normal speed.
static bool wantsVarispeed(const EeveeTimePitch *unit) {
    return unit->vari && atomic_load(&unit->follows)
           && (atomic_load(&unit->rate) != 1 || atomic_load(&unit->semitones) == 0);
}

bool EeveeTimePitchSwitchPending(const EeveeTimePitch *unit) {
    return wantsVarispeed(unit) != atomic_load(&unit->resampling);
}

void EeveeTimePitchReset(EeveeTimePitch *unit) {
    AudioUnitReset(unit->unit, kAudioUnitScope_Global, 0);
    if (unit->vari) AudioUnitReset(unit->vari, kAudioUnitScope_Global, 0);
    unit->written = unit->read = 0;
    unit->sampleTime = 0;
    atomic_store(&unit->resampling, wantsVarispeed(unit));
}

OSStatus EeveeTimePitchRender(EeveeTimePitch *unit, UInt32 frames, AudioBufferList *data) {
    if (!frames || frames > kEeveeTimePitchMaxFrames) return kAudioUnitErr_TooManyFramesToProcess;
    AudioTimeStamp timestamp = {.mSampleTime = unit->sampleTime, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioUnitRenderActionFlags flags = 0;
    OSStatus status = AudioUnitRender(atomic_load(&unit->resampling) ? unit->vari : unit->unit, &flags, &timestamp, 0, frames, data);
    unit->sampleTime += frames;
    if (status != noErr) atomic_fetch_add_explicit(&unit->failures, 1, memory_order_relaxed);
    return status;
}

bool EeveeTimePitchProcess(EeveeTimePitch *unit, float *const *channels, UInt32 frames) {
    if (unit->source || !frames || frames > kEeveeTimePitchMaxFrames) return false;
    // a FIFO about to overflow (the unit stopped pulling) starts over instead of wrapping onto itself.
    if (unit->written - unit->read + frames > kFifoFrames) {
        unit->written = unit->read = 0;
        atomic_fetch_add_explicit(&unit->failures, 1, memory_order_relaxed);
        return false;
    }
    for (UInt32 c = 0; c < unit->channels; c++) {
        const float *in = channels[c];
        for (UInt32 i = 0; i < frames; i++) unit->fifo[c][(unit->written + i) & (kFifoFrames - 1)] = in[i];
        unit->output.list.mBuffers[c] = (AudioBuffer){1, frames * (UInt32)sizeof(float), unit->outputData[c]};
    }
    unit->written += frames;
    if (EeveeTimePitchRender(unit, frames, &unit->output.list) != noErr) return false;
    for (UInt32 c = 0; c < unit->channels; c++) {
        const float *out = unit->output.list.mBuffers[c].mData;
        if (out) memcpy(channels[c], out, frames * sizeof(float));
    }
    return true;
}

EeveeTimePitchStats EeveeTimePitchReadStats(EeveeTimePitch *unit) {
    return (EeveeTimePitchStats){atomic_load(&unit->underruns), atomic_load(&unit->failures), atomic_load(&unit->largestPull),
                                 atomic_load(&unit->consumed) / unit->sampleRate};
}
