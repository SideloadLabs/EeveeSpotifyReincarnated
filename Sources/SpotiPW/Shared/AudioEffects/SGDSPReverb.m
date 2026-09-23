#import "SGDSPEffects.h"
#import <AudioToolbox/AudioToolbox.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    float mix, minDelay, maxDelay, decay, decayHigh, density;
} Preset;

// Ambience, small room, medium room, large room, chamber, plate, small hall, large hall, cathedral.
static const Preset kPresets[SGDSPReverbPresetCount] = {
    {12, 0.002f, 0.012f, 0.35f, 0.20f, 400},
    {18, 0.004f, 0.020f, 0.55f, 0.30f, 400},
    {22, 0.006f, 0.032f, 0.90f, 0.50f, 400},
    {24, 0.008f, 0.045f, 1.40f, 0.75f, 400},
    {25, 0.005f, 0.030f, 1.20f, 0.90f, 600},
    {22, 0.001f, 0.010f, 1.80f, 1.60f, 800},
    {25, 0.012f, 0.060f, 1.90f, 1.00f, 400},
    {28, 0.020f, 0.095f, 3.00f, 1.60f, 400},
    {30, 0.030f, 0.150f, 6.50f, 3.00f, 400},
};

struct SGDSPReverb {
    AudioUnit unit;
    Float64 sampleTime;
    float input[2][kSGDSPEffectMaxFrames];
    struct {
        AudioBufferList list;
        AudioBuffer second;
    } output;
};

static OSStatus pull(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
                     AudioBufferList *data) {
    SGDSPReverb *reverb = refCon;
    for (UInt32 c = 0; c < data->mNumberBuffers && c < 2; c++) {
        if (data->mBuffers[c].mData) memcpy(data->mBuffers[c].mData, reverb->input[c], frames * sizeof(float));
        else data->mBuffers[c].mData = reverb->input[c];
        data->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}

SGDSPReverb *SGDSPReverbCreate(double rate, int preset) {
    AudioComponentDescription description = {kAudioUnitType_Effect, kAudioUnitSubType_Reverb2, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    SGDSPReverb *reverb = component ? calloc(1, sizeof *reverb) : NULL;
    if (!reverb) return NULL;
    if (AudioComponentInstanceNew(component, &reverb->unit) != noErr) {
        free(reverb);
        return NULL;
    }
    AudioStreamBasicDescription format = {
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
    };
    UInt32 maxFrames = kSGDSPEffectMaxFrames;
    AURenderCallbackStruct callback = {pull, reverb};
    OSStatus status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format);
    if (!status) status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format);
    if (!status) status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof maxFrames);
    if (!status) status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    if (!status) status = AudioUnitInitialize(reverb->unit);
    if (status) {
        AudioComponentInstanceDispose(reverb->unit);
        free(reverb);
        return NULL;
    }
    reverb->output.list.mNumberBuffers = 2;
    SGDSPReverbSet(reverb, preset);
    // The unit sets itself up on its first render, allocating: that render is a block of silence, here.
    float silence[2][kSGDSPEffectMaxFrames] = {{0}};
    SGDSPReverbRun(reverb, silence[0], silence[1], kSGDSPEffectMaxFrames);
    return reverb;
}

void SGDSPReverbSet(SGDSPReverb *reverb, int preset) {
    const Preset *p = &kPresets[preset < 0 ? 0 : preset >= SGDSPReverbPresetCount ? SGDSPReverbPresetCount - 1 : preset];
    const struct { AudioUnitParameterID id; float value; } values[] = {
        {kReverb2Param_DryWetMix, p->mix}, {kReverb2Param_Gain, 0}, {kReverb2Param_MinDelayTime, p->minDelay},
        {kReverb2Param_MaxDelayTime, p->maxDelay}, {kReverb2Param_DecayTimeAt0Hz, p->decay},
        {kReverb2Param_DecayTimeAtNyquist, p->decayHigh}, {kReverb2Param_RandomizeReflections, p->density},
    };
    for (size_t i = 0; i < sizeof values / sizeof *values; i++) {
        AudioUnitSetParameter(reverb->unit, values[i].id, kAudioUnitScope_Global, 0, values[i].value, 0);
    }
}

void SGDSPReverbRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPReverb *reverb = state;
    memcpy(reverb->input[0], left, frames * sizeof(float));
    memcpy(reverb->input[1], right, frames * sizeof(float));
    reverb->output.list.mBuffers[0] = (AudioBuffer){1, frames * (UInt32)sizeof(float), left};
    reverb->output.list.mBuffers[1] = (AudioBuffer){1, frames * (UInt32)sizeof(float), right};
    AudioTimeStamp timestamp = {.mSampleTime = reverb->sampleTime, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioUnitRenderActionFlags flags = 0;
    // A failed render leaves the sound dry rather than whatever the buffers hold.
    if (AudioUnitRender(reverb->unit, &flags, &timestamp, 0, frames, &reverb->output.list) != noErr) {
        memcpy(left, reverb->input[0], frames * sizeof(float));
        memcpy(right, reverb->input[1], frames * sizeof(float));
    } else {
        if (reverb->output.list.mBuffers[0].mData != left) memcpy(left, reverb->output.list.mBuffers[0].mData, frames * sizeof(float));
        if (reverb->output.list.mBuffers[1].mData != right) memcpy(right, reverb->output.list.mBuffers[1].mData, frames * sizeof(float));
    }
    reverb->sampleTime += frames;
}

void SGDSPReverbFree(void *state) {
    SGDSPReverb *reverb = state;
    if (!reverb) return;
    AudioUnitUninitialize(reverb->unit);
    AudioComponentInstanceDispose(reverb->unit);
    free(reverb);
}
