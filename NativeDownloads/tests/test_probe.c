#include "Diagnostics.h"
#include "AudioProbeBackend.h"
#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static AURenderCallbackStruct installed;
static AudioStreamBasicDescription format;
static AudioUnit unit = (AudioUnit)(uintptr_t)0x12345678;
static OSStatus renderResult;
static unsigned originalCalls, observerCalls;

static OSStatus set(AudioUnit u, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, const void *data, UInt32 size) {
    if (property == kAudioUnitProperty_SetRenderCallback) installed = *(const AURenderCallbackStruct *)data;
    if (property == kAudioUnitProperty_StreamFormat) format = *(const AudioStreamBasicDescription *)data;
    return noErr;
}
static OSStatus get(AudioUnit u, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, void *data, UInt32 *size) {
    if (property == kAudioUnitProperty_SetRenderCallback) { *(AURenderCallbackStruct *)data = installed; *size = sizeof(installed); return noErr; }
    if (property == kAudioUnitProperty_StreamFormat) { *(AudioStreamBasicDescription *)data = format; *size = sizeof(format); return noErr; }
    return kAudioUnitErr_InvalidProperty;
}
static OSStatus start(AudioUnit u) { return noErr; }
static OSStatus stop(AudioUnit u) { return noErr; }
static OSStatus dispose(AudioComponentInstance u) { return noErr; }
static OSStatus describe(AudioUnit u, AudioComponentDescription *d) { d->componentType = kAudioUnitType_Output; return noErr; }

static OSStatus original(void *refcon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    assert(refcon == (void *)(uintptr_t)77);
    originalCalls++;
    if (renderResult) return renderResult;
    float *samples = data->mBuffers[0].mData;
    for (unsigned i = 0; i < frames * 2; ++i) samples[i] = 0.5f;
    return noErr;
}
static void scale(const AudioStreamBasicDescription *f, AudioBufferList *buffers, UInt32 frames) {
    assert(f->mSampleRate == 48000);
    observerCalls++;
    float *samples = buffers->mBuffers[0].mData;
    for (unsigned i = 0; i < frames * 2; ++i) samples[i] *= 0.5f;
}
static void invoke(float *samples, UInt32 frames) {
    AudioBufferList data = {.mNumberBuffers = 1, .mBuffers = {{2, frames * 2 * sizeof(float), samples}}};
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time = {0};
    assert(installed.inputProc(installed.inputProcRefCon, &flags, &time, 0, frames, &data) == renderResult);
}

int main(void) {
    // The removed manual-mute API must no longer be callable by clients.
    assert(dlsym(RTLD_DEFAULT, "SpotifyAudioProbeMuteForSeconds") == NULL);
    SAPDiagnosticsSetEnabled(true);

    SAPTestUseBackend((SAPBackend){set, get, start, stop, dispose, describe});
    format = (AudioStreamBasicDescription){48000, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
    AURenderCallbackStruct callback = {original, (void *)(uintptr_t)77};
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) == noErr);
    assert(installed.inputProc != original);
    AURenderCallbackStruct queried = {0}; UInt32 size = sizeof(queried);
    assert(AudioUnitGetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &queried, &size) == noErr);
    assert(queried.inputProc == original && queried.inputProcRefCon == callback.inputProcRefCon);
    assert(AudioOutputUnitStart(unit) == noErr);
    float samples[256];
    invoke(samples, 128);
    for (unsigned i = 0; i < 256; ++i) assert(samples[i] == 0.5f);
    SAPSnapshot snapshot; SpotifyAudioProbeReadSnapshot(&snapshot);
    assert(snapshot.pcmConfirmed && snapshot.callbacks == 1 && snapshot.frames == 128 && snapshot.pcmBytes == 1024);
    assert(snapshot.nonzeroCallbacks == 1 && snapshot.sampleRate == 48000 && snapshot.channels == 2);
    SpotifyAudioProbeSetObserver(scale);
    invoke(samples, 128);
    assert(observerCalls == 1 && samples[0] == 0.25f);
    renderResult = -777;
    invoke(samples, 128);
    assert(observerCalls == 1);
    SpotifyAudioProbeReadSnapshot(&snapshot);
    assert(snapshot.callbackErrors == 1 && originalCalls == 3);
    renderResult = 0;
    SpotifyAudioProbeSetObserver(NULL);
    AURenderCallbackStruct previous = installed;
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) == noErr);
    assert(previous.inputProcRefCon != installed.inputProcRefCon);
    // A replaced context remains safe while an old render finishes.
    AudioBufferList data = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(samples), samples}}};
    AudioUnitRenderActionFlags flags = 0; AudioTimeStamp timestamp = {0};
    assert(previous.inputProc(previous.inputProcRefCon, &flags, &timestamp, 0, 128, &data) == noErr);
    assert(AudioOutputUnitStop(unit) == noErr && AudioComponentInstanceDispose(unit) == noErr);

    // Some output units accept render registration on Global scope. The
    // stream ASBD must still be queried on Input scope, bus zero.
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback)) == noErr);
    assert(installed.inputProc != original);
    invoke(samples, 128);
    SpotifyAudioProbeReadSnapshot(&snapshot);
    assert(snapshot.lastCallbackScope == kAudioUnitScope_Global && snapshot.callbackAttempts == 3);
    assert(snapshot.setPropertyCalls == 3 && snapshot.pcmConfirmed);

    // The PCM observer remains available with diagnostics off,
    // while sample metering and per-buffer counters remain stopped.
    SAPDiagnosticsSetEnabled(false);
    SpotifyAudioProbeReadSnapshot(&snapshot);uint64_t beforeCallbacks=snapshot.callbacks,beforeBytes=snapshot.pcmBytes;
    invoke(samples,128);
    SpotifyAudioProbeReadSnapshot(&snapshot);
    assert(snapshot.pcmConfirmed && snapshot.callbacks==beforeCallbacks && snapshot.pcmBytes==beforeBytes);
    for(unsigned i=0;i<256;i++)assert(samples[i]==0.5f);
    SpotifyAudioProbeSetObserver(scale);
    invoke(samples,128);
    assert(observerCalls == 2);
    for(unsigned i=0;i<256;i++)assert(samples[i]==0.25f);
    SpotifyAudioProbeSetObserver(NULL);
    SpotifyAudioProbeReadSnapshot(&snapshot);assert(snapshot.callbacks==beforeCallbacks && snapshot.pcmBytes==beforeBytes);
    SAPDiagnosticsSetEnabled(true);invoke(samples,128);SpotifyAudioProbeReadSnapshot(&snapshot);
    assert(snapshot.callbacks==beforeCallbacks+1 && snapshot.pcmBytes==beforeBytes+1024);
    puts("PASS: diagnostics OFF preserves playback and observer; counters stop and resume");
    puts("PASS: callback forwarding, original getter, untouched passthrough, PCM detection, mutable observer, errors and replacement lifetime");
}
