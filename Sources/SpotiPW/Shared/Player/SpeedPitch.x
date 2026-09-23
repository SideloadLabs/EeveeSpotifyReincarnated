// SpotiPW player speed/pitch integration.
// Source implementation is retained here as an independent feature and is guarded by runtime capability checks.
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "Headers/SPTPlayer.h"
#import "SpeedPitch.h"
#import "SGTimePitch.h"

static float sg_speed = 1, sg_semitones;
static atomic_uint sg_speedBits;
static _Atomic(AudioUnit) sg_source;
static UInt32 sg_sourceBus;
static atomic_uint sg_chunk = 1024;
static _Atomic(SGTimePitch *) sg_pull, sg_inPlace;
static atomic_bool sg_engaged, sg_busy;
static pthread_mutex_t sg_buildLock = PTHREAD_MUTEX_INITIALIZER;
static OSStatus (*sg_setProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus (*sg_startOutput)(AudioUnit);

static float loadFloat(atomic_uint *slot) {
    uint32_t bits = atomic_load(slot); float value; memcpy(&value, &bits, sizeof value); return value;
}
static void storeFloat(atomic_uint *slot, float value) {
    uint32_t bits; memcpy(&bits, &value, sizeof bits); atomic_store(slot, bits);
}
static BOOL tapped(void) { return atomic_load(&sg_source) != NULL; }

static OSStatus pullForUnit(void *context, UInt32 frames, AudioBufferList *data) {
    AudioUnit source = atomic_load(&sg_source);
    if (!source) return noErr;
    AudioTimeStamp time = {0}; time.mFlags = kAudioTimeStampSampleTimeValid;
    AudioUnitRenderActionFlags flags = 0;
    return AudioUnitRender(source, &flags, &time, sg_sourceBus, frames, data);
}
static OSStatus feed(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                     UInt32 frames, AudioBufferList *data) {
    AudioUnit source = atomic_load(&sg_source);
    if (!source) { *flags |= kAudioUnitRenderAction_OutputIsSilence; return noErr; }
    atomic_store(&sg_busy, true);
    OSStatus status = noErr;
    SGTimePitch *unit = atomic_load(&sg_pull);
    if (atomic_load(&sg_engaged) && unit) status = SGTimePitchRender(unit, frames, data);
    if (status != noErr) status = AudioUnitRender(source, flags, timestamp, sg_sourceBus, frames, data);
    atomic_store(&sg_busy, false);
    return status;
}
static BOOL isRemoteIO(AudioUnit unit) {
    AudioComponentDescription d = {0};
    return unit && AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &d) == noErr &&
           d.componentType == kAudioUnitType_Output && d.componentSubType == kAudioUnitSubType_RemoteIO;
}
static OSStatus setProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                            const void *data, UInt32 size) {
    if (property == kAudioUnitProperty_MaximumFramesPerSlice && data && size >= sizeof(UInt32))
        atomic_store(&sg_chunk, *(const UInt32 *)data);
    if (property != kAudioUnitProperty_MakeConnection || scope != kAudioUnitScope_Input || element != 0 ||
        !data || size < sizeof(AudioUnitConnection) || !isRemoteIO(unit))
        return sg_setProperty(unit, property, scope, element, data, size);
    const AudioUnitConnection *connection = data;
    if (!connection->sourceAudioUnit) return sg_setProperty(unit, property, scope, element, data, size);
    sg_sourceBus = connection->sourceOutputNumber;
    atomic_store(&sg_source, connection->sourceAudioUnit);
    AURenderCallbackStruct callback = {feed, NULL};
    OSStatus status = sg_setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    if (status != noErr) { atomic_store(&sg_source, NULL); return sg_setProperty(unit, property, scope, element, data, size); }
    return noErr;
}
static OSStatus startOutput(AudioUnit unit) {
    if (unit && isRemoteIO(unit)) {
        AURenderCallbackStruct callback = {NULL, NULL};
        AudioUnitAddRenderNotify(unit, (AURenderCallback)callback.inputProc, callback.inputProcRefCon);
        dispatch_async(dispatch_get_main_queue(), ^{ if (sg_speed != 1 || sg_semitones != 0) { SGTimePitch *u=atomic_load(&sg_pull); if(u){SGTimePitchSetRate(u,sg_speed); SGTimePitchSetSemitones(u,sg_semitones); atomic_store(&sg_engaged,true);} }});
    }
    return sg_startOutput(unit);
}
double SGPlayerSpeed(void) { return sg_speed; }
BOOL SGPlayerSpeedAllowed(void) { return tapped(); }
void SGSetPlayerSpeed(double speed) { if (!tapped()) return; sg_speed=(float)speed; storeFloat(&sg_speedBits,sg_speed); SGTimePitch *u=atomic_load(&sg_pull); if(u) { SGTimePitchSetRate(u,sg_speed); atomic_store(&sg_engaged,true); } }
float SGPlayerPitch(void) { return sg_semitones; }
void SGSetPlayerPitch(float semitones) { sg_semitones=semitones; SGTimePitch *u=atomic_load(&sg_pull); if(u){SGTimePitchSetSemitones(u,sg_semitones); atomic_store(&sg_engaged,true);} }
BOOL SGPlayerPitchAvailable(void) { return sg_startOutput != NULL || tapped(); }
%hook SPTPlayerState
- (double)playbackSpeed { double speed=%orig; float ours=loadFloat(&sg_speedBits); return ours>0 && ours!=1 ? speed*ours : speed; }
%end
%ctor {
    storeFloat(&sg_speedBits,1);
    if (!SGRebindImport("AudioUnitSetProperty", setProperty, (void **)&sg_setProperty) || !sg_setProperty) sg_setProperty=NULL;
    if (!SGRebindImport("AudioOutputUnitStart", startOutput, (void **)&sg_startOutput) || !sg_startOutput) sg_startOutput=NULL;
    %init;
}
