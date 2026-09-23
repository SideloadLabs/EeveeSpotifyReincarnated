#import "SGTimePitch.h"
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
enum { kFifoFrames = 16384 };
struct SGTimePitch {
    AudioUnit unit; double sampleRate; UInt32 channels; SGTimePitchSource source; void *context;
    float *fifo[kSGTimePitchMaxChannels]; uint64_t written, read; Float64 sampleTime;
    struct { AudioBufferList list; AudioBuffer more[kSGTimePitchMaxChannels - 1]; } output;
    float *outputData[kSGTimePitchMaxChannels];
    atomic_uint underruns, failures, largestPull; atomic_uint_fast64_t consumed; double latency;
};
static OSStatus input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                      UInt32 frames, AudioBufferList *data) {
    SGTimePitch *u=refCon;
    atomic_fetch_add(&u->consumed,frames);
    if(u->source) return u->source(u->context,frames,data);
    uint64_t available=u->written-u->read; UInt32 served=(UInt32)MIN(available,frames);
    if(served<frames) atomic_fetch_add(&u->underruns,1);
    for(UInt32 c=0;c<data->mNumberBuffers && c<u->channels;c++){ float *out=data->mBuffers[c].mData; if(!out)continue; for(UInt32 i=0;i<served;i++)out[i]=u->fifo[c][(u->read+i)&(kFifoFrames-1)]; if(served<frames)memset(out+served,0,(frames-served)*sizeof(float)); }
    u->read+=served; return noErr;
}
SGTimePitch *SGTimePitchCreate(double rate, UInt32 channels, SGTimePitchSource source, void *context) {
    if(rate<=0||channels<1||channels>kSGTimePitchMaxChannels)return NULL;
    AudioComponentDescription d={kAudioUnitType_FormatConverter,kAudioUnitSubType_NewTimePitch,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent c=AudioComponentFindNext(NULL,&d); if(!c)return NULL;
    SGTimePitch *u=calloc(1,sizeof(*u)); if(!u)return NULL; u->sampleRate=rate;u->channels=channels;u->source=source;u->context=context;
    if(AudioComponentInstanceNew(c,&u->unit)!=noErr){free(u);return NULL;}
    AudioStreamBasicDescription f={.mSampleRate=rate,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,.mBytesPerPacket=4,.mFramesPerPacket=1,.mBytesPerFrame=4,.mChannelsPerFrame=channels,.mBitsPerChannel=32};
    UInt32 max=kSGTimePitchMaxFrames; AURenderCallbackStruct cb={input,u}; OSStatus s=AudioUnitSetProperty(u->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&f,sizeof f);
    if(!s)s=AudioUnitSetProperty(u->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&f,sizeof f);
    if(!s)s=AudioUnitSetProperty(u->unit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&max,sizeof max);
    if(!s)s=AudioUnitSetProperty(u->unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof cb);
    if(!s)s=AudioUnitSetParameter(u->unit,kNewTimePitchParam_Rate,kAudioUnitScope_Global,0,1,0);
    if(!s)s=AudioUnitInitialize(u->unit);
    if(s){AudioComponentInstanceDispose(u->unit);free(u);return NULL;}
    UInt32 size=sizeof(u->latency); AudioUnitGetProperty(u->unit,kAudioUnitProperty_Latency,kAudioUnitScope_Global,0,&u->latency,&size);
    u->output.list.mNumberBuffers=channels;
    for(UInt32 i=0;i<channels;i++){if(!source)u->fifo[i]=calloc(kFifoFrames,sizeof(float));u->outputData[i]=calloc(kSGTimePitchMaxFrames,sizeof(float));}
    return u;
}
double SGTimePitchSampleRate(const SGTimePitch*u){return u->sampleRate;}
UInt32 SGTimePitchChannels(const SGTimePitch*u){return u->channels;}
void SGTimePitchSetRate(SGTimePitch*u,float r){if(u)AudioUnitSetParameter(u->unit,kNewTimePitchParam_Rate,kAudioUnitScope_Global,0,r,0);}
void SGTimePitchSetSemitones(SGTimePitch*u,float s){if(u)AudioUnitSetParameter(u->unit,kNewTimePitchParam_Pitch,kAudioUnitScope_Global,0,s*100,0);}
void SGTimePitchReset(SGTimePitch*u){if(!u)return;AudioUnitReset(u->unit,kAudioUnitScope_Global,0);u->written=u->read=0;u->sampleTime=0;}
OSStatus SGTimePitchRender(SGTimePitch*u,UInt32 frames,AudioBufferList*d){if(!u||!frames||frames>kSGTimePitchMaxFrames)return kAudioUnitErr_TooManyFramesToProcess;AudioTimeStamp t={.mSampleTime=u->sampleTime,.mFlags=kAudioTimeStampSampleTimeValid};AudioUnitRenderActionFlags f=0;OSStatus s=AudioUnitRender(u->unit,&f,&t,0,frames,d);u->sampleTime+=frames;if(s)atomic_fetch_add(&u->failures,1);return s;}
bool SGTimePitchProcess(SGTimePitch*u,float*const*channels,UInt32 frames){if(!u||u->source||!frames||frames>kSGTimePitchMaxFrames)return false;if(u->written-u->read+frames>kFifoFrames){u->written=u->read=0;atomic_fetch_add(&u->failures,1);return false;}for(UInt32 c=0;c<u->channels;c++)for(UInt32 i=0;i<frames;i++)u->fifo[c][(u->written+i)&(kFifoFrames-1)]=channels[c][i];u->written+=frames;for(UInt32 c=0;c<u->channels;c++)u->output.list.mBuffers[c]=(AudioBuffer){1,frames*4,u->outputData[c]};if(SGTimePitchRender(u,frames,&u->output.list))return false;for(UInt32 c=0;c<u->channels;c++)memcpy(channels[c],u->output.list.mBuffers[c].mData,frames*4);return true;}
UInt32 SGTimePitchUnderruns(const SGTimePitch*u){return atomic_load((atomic_uint*)&u->underruns);}
UInt32 SGTimePitchFailures(const SGTimePitch*u){return atomic_load((atomic_uint*)&u->failures);}
double SGTimePitchLatency(const SGTimePitch*u){return u->latency;}
UInt32 SGTimePitchLargestPull(const SGTimePitch*u){return atomic_load((atomic_uint*)&u->largestPull);}
uint64_t SGTimePitchConsumed(const SGTimePitch*u){return atomic_load((atomic_uint_fast64_t*)&u->consumed);}
