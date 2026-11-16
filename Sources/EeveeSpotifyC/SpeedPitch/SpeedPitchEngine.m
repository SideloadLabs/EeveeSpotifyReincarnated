// Spotify's audio output, taken over to change speed and pitch (README.md has the full picture). Spotify's
// import of AudioUnitSetProperty is rebound, and when Spotify connects a mixer to a RemoteIO unit, feed()
// pulls the mixer instead: straight through at normal speed and pitch, else through the time-pitch unit.
//
// threading: feed() and rendered() run on each RemoteIO unit's render thread and only touch atomics, their
// own Output and the units; they never wait. Spotify connects, starts, stops and disposes on its audio
// thread, and Output records change under sg_outputsLock there and on sg_outputsQueue. a change waits for a
// render in progress to end.
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Rebind.h"
#import "SpeedPitchPrivate.h"
#import "TimePitch.h"

// putting the unit in or taking it out skips or repeats its 93 ms delay, so it stays in this long after speed
// and pitch both come back to normal.
static const double kOffAfter = 1.5;
// an output silent this long hands the unit to a connected one with sound. one started or connected this
// recently counts as having sound.
static const double kSilentFor = 1;
// how often that's checked while two or more outputs run.
static const double kCheckEvery = 0.5;

enum { kMaxOutputs = 8 };

#pragma mark - state

static float sg_speed = 1, sg_semitones;     // main thread
static atomic_uint sg_speedBits = 0x3f800000; // sg_speed (1.0f) for any thread
static atomic_bool sg_follows;               // pitch follows speed

typedef struct {
    atomic_uint_fast64_t rateBits;
    atomic_uint flags, channels, bytes;
} Format;

// one of Spotify's RemoteIO units. Spotify keeps a chain per sample rate, so a local file at another rate gets
// a second one and both can run at once. a slot whose unit is NULL is free; slots are reused, never freed,
// since a render thread may hold one.
typedef struct {
    _Atomic(AudioUnit) unit;
    // the mixer Spotify connected, NULL when none is. `taken` while feed() stands in for that connection,
    // pulling it in chunks no larger than the mixer's largest slice.
    _Atomic(AudioUnit) source;
    UInt32 sourceBus;
    atomic_bool taken;
    atomic_uint chunk;
    Float64 sourceTime;                      // its render thread only
    // Spotify's side (input scope, element 0), which feed() fills, and the hardware's (output scope),
    // which render notifies get.
    Format client, hardware;
    atomic_bool running, busy;
    atomic_uint_fast64_t loudAt;             // host time of its last rendered buffer with sound
    // under sg_outputsLock: when Spotify last started or connected it, as an order and as a host time,
    // and whether its notify and listener are on.
    uint64_t order, eventAt;
    BOOL listened;
} Output;

static Output sg_outputs[kMaxOutputs];
static _Atomic(Output *) sg_music;           // the music's output, which carries the unit (see choose())
static pthread_mutex_t sg_outputsLock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static dispatch_queue_t sg_outputsQueue;
static BOOL sg_reachable;                    // Spotify's AudioOutputUnitStart could be rebound or hooked

// the unit in use and whether the render thread runs it: in the music's chain (pull), else in place (pitch only).
static _Atomic(EeveeTimePitch *) sg_pull, sg_inPlace;
static atomic_bool sg_engaged;
static pthread_mutex_t sg_buildLock = PTHREAD_MUTEX_INITIALIZER;

static double sg_secondsPerTick;
static OSStatus (*sg_setProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

static Output *music(void) {
    return atomic_load(&sg_music);
}

// microseconds of song the music's mixer has handed over with sound; SpeedPitchClock.x counts with it.
static _Atomic uint64_t sg_playedMicros;

// whether the music's output is fed through feed().
static BOOL tapped(void) {
    Output *output = music();
    return output && atomic_load(&output->taken);
}

static double rateOf(Format *format) {
    uint64_t bits = atomic_load_explicit(&format->rateBits, memory_order_relaxed);
    double rate;
    memcpy(&rate, &bits, sizeof rate);
    return rate;
}

static float loadFloat(atomic_uint *slot) {
    uint32_t bits = atomic_load(slot);
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static void storeFloat(atomic_uint *slot, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store(slot, bits);
}

static double seconds(uint64_t ticks) {
    return ticks * sg_secondsPerTick;
}

#pragma mark - the render thread: the chain

static void silence(AudioBufferList *data) {
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) if (data->mBuffers[b].mData) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
}

// the output's mixer's next `frames` frames into `data`, in chunks of at most its largest slice, each with a
// sample time of the output's own, so Spotify's units never see a time twice (an AU renders a time it has
// seen from cache).
static OSStatus pullSource(Output *output, AudioUnit source, const AudioTimeStamp *outputTime, UInt32 frames, AudioBufferList *data) {
    enum { kMaxBuffers = 8 };
    UInt32 chunk = atomic_load_explicit(&output->chunk, memory_order_relaxed);
    if (data->mNumberBuffers > kMaxBuffers) chunk = frames;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) if (!data->mBuffers[b].mData) chunk = frames;
    UInt32 bytesPerFrame[kMaxBuffers];
    for (UInt32 b = 0; b < data->mNumberBuffers && b < kMaxBuffers; b++) bytesPerFrame[b] = data->mBuffers[b].mDataByteSize / frames;

    for (UInt32 done = 0; done < frames;) {
        UInt32 count = MIN(chunk, frames - done);
        struct { AudioBufferList list; AudioBuffer more[kMaxBuffers - 1]; } part;
        AudioBufferList *target = data;
        if (count != frames) {
            part.list.mNumberBuffers = data->mNumberBuffers;
            for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
                part.list.mBuffers[b] = (AudioBuffer){data->mBuffers[b].mNumberChannels, count * bytesPerFrame[b],
                                                      (char *)data->mBuffers[b].mData + done * bytesPerFrame[b]};
            }
            target = &part.list;
        }
        AudioTimeStamp time = outputTime ? *outputTime : (AudioTimeStamp){0};
        time.mSampleTime = output->sourceTime;
        time.mFlags |= kAudioTimeStampSampleTimeValid;
        AudioUnitRenderActionFlags flags = 0;
        OSStatus status = AudioUnitRender(source, &flags, &time, output->sourceBus, count, target);
        output->sourceTime += count;
        if (status != noErr) return status;
        // a buffer marked silent may still hold what was in it before; nothing after this reads the mark.
        if (flags & kAudioUnitRenderAction_OutputIsSilence) {
            silence(target);
        } else if (output == music()) {
            double rate = rateOf(&output->client);
            if (rate > 0) atomic_fetch_add_explicit(&sg_playedMicros, (uint64_t)(count * 1e6 / rate), memory_order_relaxed);
        }
        done += count;
    }
    return noErr;
}

// whether the time-pitch unit pulled the mixer during the render under way. the music's render thread only.
static bool sg_unitPulled;

// the time-pitch unit's input. it renders only on the music's output, and a change of music takes the
// unit out first (disengage), so the music here is the output rendering it.
static OSStatus pullForUnit(void *context, UInt32 frames, AudioBufferList *data) {
    sg_unitPulled = true;
    Output *output = music();
    AudioUnit source = output ? atomic_load(&output->source) : NULL;
    if (!source) {
        silence(data);
        return noErr;
    }
    return pullSource(output, source, NULL, frames, data);
}

static BOOL fitsUnit(const AudioBufferList *data, UInt32 frames, EeveeTimePitch *unit) {
    if (data->mNumberBuffers != EeveeTimePitchChannels(unit) || frames > kEeveeTimePitchMaxFrames) return NO;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (!data->mBuffers[b].mData || data->mBuffers[b].mDataByteSize < frames * sizeof(float)) return NO;
    }
    return YES;
}

// a RemoteIO unit's input, in place of Spotify's connection from its mixer. `refCon` is its Output.
static OSStatus feed(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                     UInt32 frames, AudioBufferList *data) {
    Output *output = refCon;
    atomic_store(&output->busy, true);
    AudioUnit source = atomic_load(&output->source);
    OSStatus status = noErr;
    if (!source) {
        silence(data);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    } else if (output != music()) {
        // another chain plays as Spotify made it.
        status = pullSource(output, source, timestamp, frames, data);
    } else {
        EeveeTimePitch *unit = atomic_load(&sg_pull);
        // a unit made for another rate passes the sound as it is, until the main thread makes one for the new rate.
        BOOL tried = atomic_load(&sg_engaged) && unit && fitsUnit(data, frames, unit) && EeveeTimePitchSampleRate(unit) == rateOf(&output->client);
        sg_unitPulled = false;
        status = tried ? EeveeTimePitchRender(unit, frames, data) : -1;
        if (status != noErr && tried && sg_unitPulled) {
            // the failed render took the mixer's sound already: a second pull would skip a buffer of the song,
            // so this one is silent instead.
            silence(data);
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
            status = noErr;
        } else if (status != noErr) {
            status = pullSource(output, source, timestamp, frames, data);
        }
    }
    atomic_store(&output->busy, false);
    return status;
}

#pragma mark - the render thread: in place, the fallback

static float sg_scratch[kEeveeTimePitchMaxChannels][kEeveeTimePitchMaxFrames];

static inline float readSample(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4) {
        if (isFloat) return ((const float *)data)[index];
        int32_t value = ((const int32_t *)data)[index];
        return fraction ? (float)((double)value / (double)(1u << fraction)) : (float)(value / 2147483648.0);
    }
    return ((const int16_t *)data)[index] / 32768.0f;
}

static inline void writeSample(void *data, UInt32 index, float value, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) {
        ((float *)data)[index] = value;
        return;
    }
    value = fmaxf(-1, fminf(value, 1));
    if (bytes == 4) {
        double scale = fraction ? (double)(1u << fraction) : 2147483647.0;
        ((int32_t *)data)[index] = (int32_t)(value * scale);
    } else {
        ((int16_t *)data)[index] = (int16_t)(value * 32767);
    }
}

static void shiftInPlace(EeveeTimePitch *unit, Format *hardware, AudioUnitRenderActionFlags *flags, UInt32 frames, AudioBufferList *data) {
    UInt32 formatFlags = atomic_load_explicit(&hardware->flags, memory_order_relaxed);
    UInt32 bytes = atomic_load_explicit(&hardware->bytes, memory_order_relaxed);
    UInt32 channels = EeveeTimePitchChannels(unit);
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    if (frames > kEeveeTimePitchMaxFrames || (bytes != 2 && bytes != 4)) return;
    if (split ? data->mNumberBuffers != channels : data->mNumberBuffers != 1 || data->mBuffers[0].mNumberChannels != channels) return;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (!data->mBuffers[b].mData || data->mBuffers[b].mDataByteSize < frames * bytes * (split ? 1 : channels)) return;
    }
    // silence still goes through, so the sound the unit holds plays out rather than coming back later.
    BOOL silent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;

    float *lanes[kEeveeTimePitchMaxChannels];
    BOOL direct = split && isFloat && bytes == 4 && !silent;
    for (UInt32 c = 0; c < channels; c++) {
        if (direct) {
            lanes[c] = data->mBuffers[c].mData;
            continue;
        }
        lanes[c] = sg_scratch[c];
        const void *source = data->mBuffers[split ? c : 0].mData;
        for (UInt32 i = 0; i < frames; i++) {
            lanes[c][i] = silent ? 0 : readSample(source, split ? i : i * channels + c, bytes, isFloat, fraction);
        }
    }
    if (!EeveeTimePitchProcess(unit, lanes, frames) || direct) return;
    for (UInt32 c = 0; c < channels; c++) {
        void *target = data->mBuffers[split ? c : 0].mData;
        for (UInt32 i = 0; i < frames; i++) writeSample(target, split ? i : i * channels + c, lanes[c][i], bytes, isFloat, fraction);
    }
    *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
}

// whether a buffer in `format` holds sound: float over -80 dB, so a mixer's noise floor is not taken for
// music, and in any other format anything but zeros.
static BOOL hasSound(Format *format, AudioUnitRenderActionFlags flags, const AudioBufferList *data) {
    if (flags & kAudioUnitRenderAction_OutputIsSilence) return NO;
    BOOL floats = (atomic_load_explicit(&format->flags, memory_order_relaxed) & kAudioFormatFlagIsFloat)
                  && atomic_load_explicit(&format->bytes, memory_order_relaxed) == 4;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        const uint32_t *words = data->mBuffers[b].mData;
        UInt32 count = words ? data->mBuffers[b].mDataByteSize / sizeof *words : 0;
        for (UInt32 i = 0; i < count; i++) {
            if (floats ? fabsf(((const float *)words)[i]) > 1e-4f : words[i] != 0) return YES;
        }
    }
    return NO;
}

// on every started output, `refCon` its Output: notes when it has sound, and shifts the pitch on the music's
// when it is not fed by feed().
static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    Output *output = refCon;
    if (hasSound(&output->hardware, *flags, data)) atomic_store_explicit(&output->loudAt, mach_absolute_time(), memory_order_relaxed);
    if (output != music() || atomic_load(&output->taken) || !atomic_load(&sg_engaged)) return noErr;
    atomic_store(&output->busy, true);
    EeveeTimePitch *unit = atomic_load(&sg_inPlace);
    if (atomic_load(&sg_engaged) && output == music() && unit && EeveeTimePitchSampleRate(unit) == rateOf(&output->hardware)) {
        shiftInPlace(unit, &output->hardware, flags, frames, data);
    }
    atomic_store(&output->busy, false);
    return noErr;
}

#pragma mark - the outputs (sg_outputsLock)

static BOOL isRemoteIO(AudioUnit unit) {
    AudioComponentDescription description = {0};
    if (!unit || AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) != noErr) return NO;
    return description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO;
}

static Output *outputOf(AudioUnit unit) {
    for (int i = 0; unit && i < kMaxOutputs; i++) if (atomic_load(&sg_outputs[i].unit) == unit) return &sg_outputs[i];
    return NULL;
}

static Output *outputFor(AudioUnit unit) {
    Output *output = outputOf(unit);
    for (int i = 0; !output && i < kMaxOutputs; i++) {
        if (atomic_load(&sg_outputs[i].unit)) continue;
        output = &sg_outputs[i];
        atomic_store(&output->source, NULL);
        atomic_store(&output->taken, false);
        atomic_store(&output->running, false);
        atomic_store(&output->chunk, 1024);
        atomic_store(&output->loudAt, 0);
        output->sourceTime = 0;
        output->order = output->eventAt = 0;
        output->listened = NO;
        atomic_store(&output->unit, unit);
    }
    if (!output) {
        static int logged;
        if (logged++ < 3) SPLog(@"audio: more than %d outputs at once, %p is left as Spotify made it", kMaxOutputs, unit);
    }
    return output;
}

// waits for the output's render in progress, if any, to end.
static void waitFor(Output *output) {
    for (int i = 0; i < 400 && atomic_load(&output->busy); i++) usleep(250);
}

// stops the render threads using the unit, and returns once none is.
static void disengage(void) {
    atomic_store(&sg_engaged, false);
    for (int i = 0; i < kMaxOutputs; i++) waitFor(&sg_outputs[i]);
}

static void readScope(AudioUnit unit, AudioUnitScope scope, Format *into, AudioStreamBasicDescription *format) {
    UInt32 size = sizeof *format;
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, format, &size);
    if (status != noErr || format->mFormatID != kAudioFormatLinearPCM || format->mSampleRate <= 0) {
        *format = (AudioStreamBasicDescription){0};
    }
    uint64_t bits;
    memcpy(&bits, &format->mSampleRate, sizeof bits);
    atomic_store(&into->rateBits, bits);
    atomic_store(&into->flags, format->mFormatFlags);
    atomic_store(&into->channels, format->mChannelsPerFrame);
    atomic_store(&into->bytes, format->mBitsPerChannel / 8);
}

static NSString *formatText(const AudioStreamBasicDescription *format) {
    if (format->mFormatID != kAudioFormatLinearPCM) return @"not linear PCM";
    return [NSString stringWithFormat:@"%.0f Hz, %u ch, %u-bit %@%@", format->mSampleRate, (unsigned)format->mChannelsPerFrame,
            (unsigned)format->mBitsPerChannel, (format->mFormatFlags & kAudioFormatFlagIsFloat) ? @"float" : @"integer",
            (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? @" split" : @" interleaved"];
}

// why feed() can't stand in for the connection to the client format `client`, nil when it can.
static NSString *refusal(Output *output, const AudioStreamBasicDescription *client) {
    BOOL canonical = client->mFormatID == kAudioFormatLinearPCM && (client->mFormatFlags & kAudioFormatFlagIsFloat)
                     && (client->mFormatFlags & kAudioFormatFlagIsNonInterleaved) && client->mBitsPerChannel == 32
                     && client->mChannelsPerFrame >= 1 && client->mChannelsPerFrame <= kEeveeTimePitchMaxChannels;
    if (!canonical) return [NSString stringWithFormat:@"Spotify's side is %@, not float split 1 or 2 ch", formatText(client)];
    AudioStreamBasicDescription mixer = {0};
    UInt32 size = sizeof mixer;
    AudioUnit source = atomic_load(&output->source);
    if (AudioUnitGetProperty(source, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, output->sourceBus, &mixer, &size) != noErr) return nil;
    UInt32 layout = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    if (mixer.mSampleRate != client->mSampleRate || (mixer.mFormatFlags & layout) != (client->mFormatFlags & layout)
        || mixer.mChannelsPerFrame != client->mChannelsPerFrame || mixer.mBitsPerChannel != client->mBitsPerChannel) {
        return [NSString stringWithFormat:@"its mixer gives %@ for %@", formatText(&mixer), formatText(client)];
    }
    return nil;
}

// reads both formats and the mixer's slice, and puts in feed() or Spotify's own connection, whichever the
// formats allow. returns why Spotify's connection is kept, nil when feed() feeds the output.
static NSString *settle(Output *output, AudioStreamBasicDescription *client, AudioStreamBasicDescription *hardware) {
    AudioUnit unit = atomic_load(&output->unit);
    readScope(unit, kAudioUnitScope_Input, &output->client, client);
    readScope(unit, kAudioUnitScope_Output, &output->hardware, hardware);
    AudioUnit source = atomic_load(&output->source);
    if (!source) return @"not connected";
    UInt32 slice = 0, size = sizeof slice;
    if (AudioUnitGetProperty(source, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, &size) == noErr && slice >= 256) {
        atomic_store(&output->chunk, slice);
    }
    NSString *why = refusal(output, client);
    BOOL take = !why;
    if (take == atomic_load(&output->taken)) return why;
    OSStatus status;
    if (take) {
        AURenderCallbackStruct callback = {feed, output};
        status = sg_setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    } else {
        // its sound passes as Spotify made it; feed()'s render in progress, if any, ends first.
        AudioUnitConnection connection = {source, output->sourceBus, 0};
        status = sg_setProperty(unit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &connection, sizeof connection);
        waitFor(output);
    }
    if (status == noErr) atomic_store(&output->taken, take);
    SPLog(@"audio: output %p %@ (status %d)%@", unit, take ? @"fed through the engine's callback" : @"given Spotify's own connection back",
          (int)status, why ? [@": " stringByAppendingString:why] : @"");
    return atomic_load(&output->taken) ? nil : why ?: @"the callback could not be set";
}

static void markEvent(Output *output) {
    static uint64_t order;
    output->order = ++order;
    output->eventAt = mach_absolute_time();
}

static NSString *describe(Output *output) {
    if (!output) return @"none";
    return [NSString stringWithFormat:@"%p (%.0f Hz)", atomic_load(&output->unit), rateOf(&output->client)];
}

static void applyToFormat(void);

// the output that should carry the unit, Spotify's newest of the best kind: running and connected with
// sound in the last second, then running and connected, then running and fed by Spotify itself, then
// connected but not started, so speed can be chosen before Spotify starts it.
static Output *choose(void) {
    uint64_t now = mach_absolute_time();
    Output *best = NULL;
    int bestRank = -1;
    for (int i = 0; i < kMaxOutputs; i++) {
        Output *output = &sg_outputs[i];
        if (!atomic_load(&output->unit)) continue;
        BOOL connected = atomic_load(&output->source) != NULL, running = atomic_load(&output->running);
        if (!running && !connected) continue;
        BOOL sounds = seconds(now - MAX(atomic_load(&output->loudAt), output->eventAt)) < kSilentFor;
        int rank = running * 4 + connected * 2 + (running && connected && sounds);
        if (rank > bestRank || (rank == bestRank && output->order > best->order)) {
            best = output;
            bestRank = rank;
        }
    }
    return best;
}

// hands the unit to the output that should have it; it is applied again when it moved, or when `always`
// (a start of the music's output, a format change on it).
static void reselect(BOOL always, NSString *why) {
    Output *previous = music(), *next = choose();
    if (next != previous) {
        disengage();
        // the newest now, so it keeps the unit through a tie with the one it took it from.
        if (next) markEvent(next);
        atomic_store(&sg_music, next);
        SPLog(@"audio: the unit moves from %@ to %@%@", describe(previous), describe(next), why ? [@", " stringByAppendingString:why] : @"");
    }
    if (next != previous || always) applyToFormat();
}

static void checkSilence(void) {
    pthread_mutex_lock(&sg_outputsLock);
    int running = 0;
    for (int i = 0; i < kMaxOutputs; i++) running += atomic_load(&sg_outputs[i].unit) && atomic_load(&sg_outputs[i].running);
    if (running > 1) reselect(NO, [NSString stringWithFormat:@"its output silent for %.0f s while another has sound", kSilentFor]);
    pthread_mutex_unlock(&sg_outputsLock);
}

static void formatChanged(void *refCon, AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element) {
    if (property != kAudioUnitProperty_StreamFormat || element != 0) return;
    if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output) return;
    // off the thread setting it: settling may set the unit's connection, which is not done from inside its own listener.
    Output *output = refCon;
    dispatch_async(sg_outputsQueue, ^{
        pthread_mutex_lock(&sg_outputsLock);
        if (atomic_load(&output->unit) == unit) {
            AudioStreamBasicDescription client, hardware;
            settle(output, &client, &hardware);
            SPLog(@"audio: output %p's format changed: Spotify's side %@, the hardware's %@", unit, formatText(&client), formatText(&hardware));
            reselect(output == music(), nil);
        }
        pthread_mutex_unlock(&sg_outputsLock);
    });
}

#pragma mark - Spotify's audio thread

// a format or slice Spotify sets on a mixer feeding an output: settled again, the output's own listener
// covering its side.
static void sourceChanged(AudioUnit unit) {
    pthread_mutex_lock(&sg_outputsLock);
    for (int i = 0; i < kMaxOutputs; i++) {
        Output *output = &sg_outputs[i];
        AudioUnit outputUnit = atomic_load(&output->unit);
        if (!outputUnit || atomic_load(&output->source) != unit) continue;
        dispatch_async(sg_outputsQueue, ^{
            pthread_mutex_lock(&sg_outputsLock);
            AudioStreamBasicDescription client, hardware;
            if (atomic_load(&output->unit) == outputUnit && atomic_load(&output->source) == unit) {
                settle(output, &client, &hardware);
                if (output == music()) applyToFormat();
            }
            pthread_mutex_unlock(&sg_outputsLock);
        });
    }
    pthread_mutex_unlock(&sg_outputsLock);
}

static OSStatus setProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                            const void *data, UInt32 size) {
    if (property != kAudioUnitProperty_MakeConnection || scope != kAudioUnitScope_Input || element != 0 || !data
        || size < sizeof(AudioUnitConnection) || !isRemoteIO(unit)) {
        OSStatus status = sg_setProperty(unit, property, scope, element, data, size);
        if (status == noErr && (property == kAudioUnitProperty_StreamFormat || property == kAudioUnitProperty_MaximumFramesPerSlice)) sourceChanged(unit);
        return status;
    }
    const AudioUnitConnection *connection = data;
    pthread_mutex_lock(&sg_outputsLock);
    Output *output = outputFor(unit);
    if (!output) {
        pthread_mutex_unlock(&sg_outputsLock);
        return sg_setProperty(unit, property, scope, element, data, size);
    }
    if (!connection->sourceAudioUnit) {
        BOOL wasTaken = atomic_exchange(&output->taken, false);
        atomic_store(&output->source, NULL);
        waitFor(output);
        if (wasTaken) {
            AURenderCallbackStruct none = {0};
            sg_setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, sizeof none);
        }
        SPLog(@"audio: Spotify disconnected output %p", unit);
        OSStatus status = sg_setProperty(unit, property, scope, element, data, size);
        reselect(NO, @"its output disconnected");
        pthread_mutex_unlock(&sg_outputsLock);
        return status;
    }
    // a new mixer: the old one's render, if any, ends first, and the new one's time starts at 0.
    atomic_store(&output->taken, false);
    atomic_store(&output->source, NULL);
    waitFor(output);
    output->sourceBus = connection->sourceOutputNumber;
    output->sourceTime = 0;
    atomic_store(&output->source, connection->sourceAudioUnit);
    markEvent(output);
    AudioStreamBasicDescription client, hardware;
    // Spotify's own connection is only made when feed() can't stand in for it.
    NSString *why = settle(output, &client, &hardware);
    OSStatus status = why ? sg_setProperty(unit, property, scope, element, data, size) : noErr;
    SPLog(@"audio: Spotify connects mixer %p (bus %u) to output %p, %@%@", connection->sourceAudioUnit, (unsigned)connection->sourceOutputNumber,
          unit, formatText(&client), why ? [@"; its own connection kept: " stringByAppendingString:why] : @"; fed through the engine's callback");
    reselect(NO, @"Spotify connected it last");
    pthread_mutex_unlock(&sg_outputsLock);
    return status;
}

static OSStatus (*sg_startOutput)(AudioUnit unit);

// the silence check, a couple of times a second while two outputs run, as it does nothing with fewer. under
// sg_outputsLock, after any output starts, stops or goes.
static void updateChecking(void) {
    static dispatch_source_t timer;   // kept for good: a source must not be released while suspended
    static BOOL checking;
    if (!timer) {
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sg_outputsQueue);
        dispatch_source_set_event_handler(timer, ^{
            checkSilence();
        });
    }
    int running = 0;
    for (int i = 0; i < kMaxOutputs; i++) running += atomic_load(&sg_outputs[i].unit) && atomic_load(&sg_outputs[i].running);
    if ((running > 1) == checking) return;
    checking = running > 1;
    if (!checking) {
        dispatch_suspend(timer);
        return;
    }
    uint64_t every = (uint64_t)(kCheckEvery * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)every), every, NSEC_PER_SEC / 10);
    dispatch_resume(timer);
}

static OSStatus startOutput(AudioUnit unit) {
    if (!isRemoteIO(unit)) return sg_startOutput(unit);
    pthread_mutex_lock(&sg_outputsLock);
    Output *output = outputFor(unit);
    if (output) {
        AudioStreamBasicDescription client, hardware;
        NSString *why = settle(output, &client, &hardware);
        markEvent(output);
        atomic_store(&output->running, true);
        updateChecking();
        if (!output->listened) {
            output->listened = YES;
            AudioUnitAddRenderNotify(unit, rendered, output);
            AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, formatChanged, output);
        }
        // every start of the music's output applies again, so what the unit held from before the pause starts over.
        reselect(music() == output, @"Spotify started it last");
        AudioUnit source = atomic_load(&output->source);
        SPLog(@"audio: output %p started: Spotify's side %@, the hardware's %@, %@; the unit is on %@", unit, formatText(&client),
              formatText(&hardware), !source ? @"fed by Spotify itself" : why ? [NSString stringWithFormat:@"mixer %p through Spotify's connection (%@)", source, why]
              : [NSString stringWithFormat:@"mixer %p through the engine's callback", source], music() == output ? @"this one" : describe(music()));
    }
    pthread_mutex_unlock(&sg_outputsLock);
    return sg_startOutput(unit);
}

static OSStatus (*sg_stopOutput)(AudioUnit unit);

static OSStatus stopOutput(AudioUnit unit) {
    OSStatus status = sg_stopOutput(unit);
    pthread_mutex_lock(&sg_outputsLock);
    Output *output = outputOf(unit);
    if (output && atomic_exchange(&output->running, false)) {
        updateChecking();
        reselect(NO, @"its output stopped");
        SPLog(@"audio: output %p stopped (Spotify's side %.0f Hz); the unit is on %@", unit, rateOf(&output->client), describe(music()));
    }
    pthread_mutex_unlock(&sg_outputsLock);
    return status;
}

static OSStatus (*sg_dispose)(AudioComponentInstance unit);

// every output fed by the unit loses it, and the unit's own output is forgotten, before it goes; renders in
// progress end first.
static OSStatus disposeUnit(AudioComponentInstance unit) {
    pthread_mutex_lock(&sg_outputsLock);
    BOOL changed = NO;
    for (int i = 0; i < kMaxOutputs; i++) {
        Output *output = &sg_outputs[i];
        AudioUnit outputUnit = atomic_load(&output->unit);
        if (!outputUnit) continue;
        if (outputUnit == unit) {
            if (output == music()) disengage();
            atomic_store(&output->running, false);
            atomic_store(&output->source, NULL);
            waitFor(output);
            atomic_store(&output->unit, NULL);
            SPLog(@"audio: output %p disposed (Spotify's side %.0f Hz)", unit, rateOf(&output->client));
            changed = YES;
        } else if (atomic_load(&output->source) == unit) {
            atomic_store(&output->source, NULL);
            waitFor(output);
            SPLog(@"audio: mixer %p disposed, output %p plays silence until Spotify connects another", unit, outputUnit);
            changed = YES;
        }
    }
    if (changed) {
        updateChecking();
        reselect(NO, @"a unit disposed");
    }
    // under the lock, so its slot is not used again while its last render may still be running.
    OSStatus status = sg_dispose(unit);
    pthread_mutex_unlock(&sg_outputsLock);
    return status;
}

#pragma mark - engaging the unit

// the unit for the music's format and the way in use, made when there is none or the format changed. a
// replaced one is never freed: the render thread may still hold it, and a format change is rare.
static EeveeTimePitch *unitForFormat(void) {
    Output *output = music();
    if (!output) return NULL;
    BOOL pull = atomic_load(&output->taken);
    Format *format = pull ? &output->client : &output->hardware;
    double rate = rateOf(format);
    UInt32 channels = atomic_load(&format->channels);
    if (rate <= 0 || channels < 1 || channels > kEeveeTimePitchMaxChannels) return NULL;
    _Atomic(EeveeTimePitch *) *slot = pull ? &sg_pull : &sg_inPlace;
    pthread_mutex_lock(&sg_buildLock);
    EeveeTimePitch *unit = atomic_load(slot);
    if (!unit || EeveeTimePitchSampleRate(unit) != rate || EeveeTimePitchChannels(unit) != channels) {
        BOOL wasEngaged = atomic_load(&sg_engaged);
        disengage();
        unit = EeveeTimePitchCreate(rate, channels, pull ? pullForUnit : NULL, NULL);
        if (unit) {
            EeveeTimePitchSetFollows(unit, atomic_load(&sg_follows));
            EeveeTimePitchSetRate(unit, pull ? sg_speed : 1);
            EeveeTimePitchSetSemitones(unit, sg_semitones);
            EeveeTimePitchReset(unit);
        }
        atomic_store(slot, unit);
        SPLog(@"%@ %@ for %.0f Hz, %u channels", unit ? @"a unit" : @"no unit", pull ? @"in the chain" : @"in place", rate, (unsigned)channels);
        if (unit && wasEngaged) atomic_store(&sg_engaged, true);
    }
    pthread_mutex_unlock(&sg_buildLock);
    return unit;
}

static void report(void) {
    EeveeTimePitch *unit = atomic_load(tapped() ? &sg_pull : &sg_inPlace);
    if (!unit) return;
    SPLog(@"%.2fx, %+.0f st, %u underruns, %u failures, largest pull %u, %.1f s of input", sg_speed, sg_semitones,
          EeveeTimePitchUnderruns(unit), EeveeTimePitchFailures(unit), EeveeTimePitchLargestPull(unit),
          EeveeTimePitchConsumed(unit) / EeveeTimePitchSampleRate(unit));
}

// hands the render thread to the unit's other half, reset, when the speed, the pitch or pitch follows speed
// now call for it. that costs the unit's delay once (93 ms going to the stretch), the same as putting it in.
static void switchIfAsked(EeveeTimePitch *unit) {
    if (!atomic_load(&sg_engaged) || !EeveeTimePitchSwitchPending(unit)) return;
    disengage();
    EeveeTimePitchReset(unit);
    atomic_store(&sg_engaged, true);
}

// puts the unit in or takes it out for the current speed and pitch.
static void apply(void) {
    BOOL normal = sg_speed == 1 && sg_semitones == 0;
    static NSUInteger change;
    NSUInteger thisChange = ++change;
    if (normal) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOffAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (thisChange != change || sg_speed != 1 || sg_semitones != 0 || !atomic_load(&sg_engaged)) return;
            report();
            disengage();
        });
    }
    EeveeTimePitch *unit = unitForFormat();
    if (!unit) {
        static int logged;
        if (!normal && logged++ < 3) SPLog(@"Spotify's output has not started, or is in a format the unit does not take; nothing to change yet");
        return;
    }
    EeveeTimePitchSetRate(unit, tapped() ? sg_speed : 1);
    EeveeTimePitchSetSemitones(unit, sg_semitones);
    if (!normal && !atomic_load(&sg_engaged)) {
        disengage();
        EeveeTimePitchReset(unit);
        atomic_store(&sg_engaged, true);
    }
    switchIfAsked(unit);
}

// a speed or pitch chosen before the output started, or kept across a new format or another output, applies
// now: apply() makes the unit again when the rate or the channels changed, and puts it back in, reset, after
// a change of output took it out.
static void applyToFormat(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_speed != 1 || sg_semitones != 0) apply();
    });
}

#pragma mark - reaching Spotify's output

// the jailbreak's way in (EeveeHookFunctionInline), where Spotify's import page cannot be written: the functions
// themselves are hooked, every caller comes through, and only Spotify's own calls go to the replacements above.
#define FROM_SPOTIFY EeveeCalledFromSpotify(__builtin_return_address(0))

static OSStatus inlineSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                                  const void *data, UInt32 size) {
    return FROM_SPOTIFY ? setProperty(unit, property, scope, element, data, size) : sg_setProperty(unit, property, scope, element, data, size);
}

static OSStatus inlineStartOutput(AudioUnit unit) {
    return FROM_SPOTIFY ? startOutput(unit) : sg_startOutput(unit);
}

static OSStatus inlineStopOutput(AudioUnit unit) {
    return FROM_SPOTIFY ? stopOutput(unit) : sg_stopOutput(unit);
}

static OSStatus inlineDisposeUnit(AudioComponentInstance unit) {
    return FROM_SPOTIFY ? disposeUnit(unit) : sg_dispose(unit);
}

// start, stop and dispose all or none: a start seen without its stop or its dispose would leave an output the
// engine thinks is running. a hook cannot be undone, so stop and dispose go first, then start, and only then
// the speed hook, which would otherwise take Spotify's output with no start seen.
static BOOL hookInline(void) {
    if (!EeveeHookFunctionInline((void *)AudioOutputUnitStop, (void *)inlineStopOutput, (void **)&sg_stopOutput)) return NO;
    if (!EeveeHookFunctionInline((void *)AudioComponentInstanceDispose, (void *)inlineDisposeUnit, (void **)&sg_dispose)) return NO;
    if (!EeveeHookFunctionInline((void *)AudioOutputUnitStart, (void *)inlineStartOutput, (void **)&sg_startOutput)) return NO;
    if (!sg_setProperty) EeveeHookFunctionInline((void *)AudioUnitSetProperty, (void *)inlineSetProperty, (void **)&sg_setProperty);
    SPLog(@"audio: Spotify's output reached through the jailbreak's hooks (speed %@)", sg_setProperty ? @"too" : @"not");
    return YES;
}

static void rebind(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sg_secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    sg_outputsQueue = dispatch_queue_create("EeveeSpotify.speedpitch.outputs", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    if (!EeveeRebindImport("AudioUnitSetProperty", setProperty, (void **)&sg_setProperty) || !sg_setProperty) sg_setProperty = NULL;
    sg_reachable = EeveeRebindImport("AudioOutputUnitStart", startOutput, (void **)&sg_startOutput) && sg_startOutput;
    if (!sg_reachable) {
        sg_startOutput = NULL;
        sg_reachable = hookInline();
        if (!sg_reachable) SPLog(@"audio: Spotify's AudioOutputUnitStart could be neither rebound nor hooked, its output cannot be reached");
    } else {
        if (!EeveeRebindImport("AudioOutputUnitStop", stopOutput, (void **)&sg_stopOutput) || !sg_stopOutput) sg_stopOutput = AudioOutputUnitStop;
        if (!EeveeRebindImport("AudioComponentInstanceDispose", disposeUnit, (void **)&sg_dispose) || !sg_dispose) {
            sg_dispose = AudioComponentInstanceDispose;
            SPLog(@"audio: Spotify does not import AudioComponentInstanceDispose, a disposed output is not seen");
        }
    }
    if (!sg_setProperty) SPLog(@"Spotify's AudioUnitSetProperty could be neither rebound nor hooked, pitch only");
}

#pragma mark - SpeedPitchPrivate.h

BOOL SpeedPitchEngineInstall(BOOL follows, BOOL *canSpeed) {
    atomic_store(&sg_follows, follows);
    rebind();
    *canSpeed = sg_setProperty != NULL;
    return sg_reachable;
}

BOOL SpeedPitchEngineTapped(void) {
    return tapped();
}

float SpeedPitchEngineSpeed(void) {
    return loadFloat(&sg_speedBits);
}

double SpeedPitchEnginePlayedSeconds(void) {
    return atomic_load_explicit(&sg_playedMicros, memory_order_relaxed) / 1e6;
}

void SpeedPitchEngineResetUnit(void) {
    EeveeTimePitch *unit = atomic_load(tapped() ? &sg_pull : &sg_inPlace);
    if (!unit) return;
    disengage();
    EeveeTimePitchReset(unit);
    if (sg_speed != 1 || sg_semitones != 0) atomic_store(&sg_engaged, true);
}

void SpeedPitchEngineSetSpeed(float speed) {
    sg_speed = speed;
    storeFloat(&sg_speedBits, speed);
    apply();
}

float SpeedPitchEngineSemitones(void) {
    return sg_semitones;
}

void SpeedPitchEngineSetSemitones(float semitones) {
    sg_semitones = semitones;
    apply();
}

BOOL SpeedPitchEngineFollows(void) {
    return atomic_load(&sg_follows);
}

void SpeedPitchEngineSetFollows(BOOL follows) {
    atomic_store(&sg_follows, follows);
    EeveeTimePitch *unit = atomic_load(&sg_pull);
    if (unit) EeveeTimePitchSetFollows(unit, follows);
    apply();
}
