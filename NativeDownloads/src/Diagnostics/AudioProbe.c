#include "AudioProbeBackend.h"
#include <dlfcn.h>
#include <math.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include "Diagnostics.h"
#include <stdio.h>
#include <string.h>

// All render-time state has a fixed lifetime. Old contexts stay valid even if
// AudioUnitSetProperty replaces a callback while the previous one is in flight.
#define SAP_MAX_CONTEXTS 128
#define SAP_MAX_FORMATS 512
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio counters must be lock-free");
_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "Audio pointers must be lock-free");

typedef struct {
    bool external;
    AudioUnit unit;
    AudioUnitScope scope;
    AudioUnitElement element;
    AURenderCallbackStruct original;
    char image[256];
    atomic_bool published;
    atomic_bool retired;
    atomic_bool receivedPCM;
    _Atomic(const AudioStreamBasicDescription *) format;
    atomic_uint_fast64_t callbacks, frames, bytes, nonzero, errors, lastTick;
    atomic_uint lastFrames, peak;
} SAPContext;

static SAPBackend api;
static atomic_bool backendReady, exhausted;
static pthread_once_t initializeOnce = PTHREAD_ONCE_INIT;
static pthread_mutex_t setupLock = PTHREAD_MUTEX_INITIALIZER;
static SAPContext contexts[SAP_MAX_CONTEXTS];
static AudioStreamBasicDescription formats[SAP_MAX_FORMATS];
static atomic_uint contextCount, starts;
static unsigned formatCount;
static atomic_uint setCalls, callbackAttempts, lastScope, lastType, lastElement, lastSubtype, objcHooks, lastSampleFormat;
static atomic_int lastSetStatus;
static atomic_uint_fast64_t sampleBufferCalls, playerBufferCalls, compressedBuffers, extractionErrors;
static _Atomic(SAPPCMObserver) observer;
static mach_timebase_info_data_t timebase;

static OSStatus describeUnit(AudioUnit unit, AudioComponentDescription *description) {
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    return component ? AudioComponentGetDescription(component, description) : kAudio_ParamError;
}

static void resolveBackend(void) {
    mach_timebase_info(&timebase);
    void *handle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return;
    api.set = dlsym(handle, "AudioUnitSetProperty");
    api.get = dlsym(handle, "AudioUnitGetProperty");
    api.start = dlsym(handle, "AudioOutputUnitStart");
    api.stop = dlsym(handle, "AudioOutputUnitStop");
    api.dispose = dlsym(handle, "AudioComponentInstanceDispose");
    api.describe = describeUnit;
    bool valid = api.set && api.get && api.start && api.stop && api.dispose
        && api.set != AudioUnitSetProperty && api.get != AudioUnitGetProperty
        && api.start != AudioOutputUnitStart && api.dispose != AudioComponentInstanceDispose;
    atomic_store_explicit(&backendReady, valid, memory_order_release);
}

SAP_EXPORT void SpotifyAudioProbeInitialize(void) {
    pthread_once(&initializeOnce, resolveBackend);
}

static bool ready(void) {
    if (!atomic_load_explicit(&backendReady, memory_order_acquire)) SpotifyAudioProbeInitialize();
    return atomic_load_explicit(&backendReady, memory_order_acquire);
}

#if SAP_JAILBREAK
// Rebind before Vitrine's constructor, matching the IPA's import chain. Preserve
// any previous import hook as our backend rather than bypassing another tweak.
extern bool SAPJBRebindImport(const char *,void *,void **);
bool SAPInstallJailbreakAudioImports(void) {
    if(!ready())return false;
    bool complete=true;
#define SAP_BIND(name,member) do { \
    void *held=NULL; \
    if(!SAPJBRebindImport(#name,(void *)name,&held)||!held||held==(void *)name)complete=false; \
    else api.member=(__typeof__(api.member))held; \
} while(0)
    SAP_BIND(AudioUnitSetProperty,set);
    SAP_BIND(AudioUnitGetProperty,get);
    SAP_BIND(AudioOutputUnitStart,start);
    SAP_BIND(AudioOutputUnitStop,stop);
    SAP_BIND(AudioComponentInstanceDispose,dispose);
#undef SAP_BIND
    return complete;
}
#endif

// Caller holds setupLock. A newly published format is immutable forever.
static void updateFormat(SAPContext *context) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    if (api.get(context->unit, kAudioUnitProperty_StreamFormat, context->scope == kAudioUnitScope_Global ? kAudioUnitScope_Input : context->scope,
                context->element, &format, &size) != noErr || size != sizeof(format)) return;
    const AudioStreamBasicDescription *old = atomic_load_explicit(&context->format, memory_order_acquire);
    if (old && memcmp(old, &format, sizeof(format)) == 0) return;
    if (formatCount >= SAP_MAX_FORMATS) {
        atomic_store(&exhausted, true);
        atomic_store_explicit(&context->format, NULL, memory_order_release);
        return;
    }
    formats[formatCount] = format;
    atomic_store_explicit(&context->format, &formats[formatCount++], memory_order_release);
}

static uint64_t availableBytes(const AudioBuffer *buffer, const AudioStreamBasicDescription *format, UInt32 frames) {
    uint64_t expected = (uint64_t)format->mBytesPerFrame * frames;
    return expected < buffer->mDataByteSize ? expected : buffer->mDataByteSize;
}

static bool formatSupported(const AudioStreamBasicDescription *format) {
    if (!format || format->mFormatID != kAudioFormatLinearPCM || !format->mBytesPerFrame
        || !format->mChannelsPerFrame || format->mChannelsPerFrame > 32 || format->mSampleRate <= 0
        || (format->mFormatFlags & kAudioFormatFlagIsBigEndian)
        || !(format->mFormatFlags & kAudioFormatFlagIsPacked)) return false;
    bool floating = format->mFormatFlags & kAudioFormatFlagIsFloat;
    bool integer = format->mFormatFlags & kAudioFormatFlagIsSignedInteger;
    unsigned bits = format->mBitsPerChannel;
    if (!((floating && bits == 32) || (integer && (bits == 16 || bits == 32)))) return false;
    unsigned channels = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : format->mChannelsPerFrame;
    return (uint64_t)channels * (bits / 8) == format->mBytesPerFrame;
}

static uint32_t peak(const AudioBufferList *data, const AudioStreamBasicDescription *format, UInt32 frames) {
    double maximum = 0;
    for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &data->mBuffers[b];
        if (!buffer->mData) continue;
        uint64_t count = availableBytes(buffer, format, frames) / (format->mBitsPerChannel / 8);
        // Diagnostic metering is bounded, irrespective of the render block size.
        uint64_t step = count > 64 ? count / 64 : 1;
        unsigned sampled = 0;
        for (uint64_t i = 0; i < count && sampled < 64; i += step, ++sampled) {
            double value;
            if (format->mFormatFlags & kAudioFormatFlagIsFloat) {
                float sample; memcpy(&sample, (const char *)buffer->mData + i * 4, 4);
                value = fabs((double)sample);
            } else if (format->mBitsPerChannel == 16) {
                int16_t sample; memcpy(&sample, (const char *)buffer->mData + i * 2, 2);
                value = fabs((double)sample / 32768.0);
            } else {
                int32_t sample; memcpy(&sample, (const char *)buffer->mData + i * 4, 4);
                value = fabs((double)sample / 2147483648.0);
            }
            if (isfinite(value) && value > maximum) maximum = value;
        }
    }
    return (uint32_t)(fmin(maximum, 1.0) * 1000000.0);
}

static void processPCM(SAPContext *context, const AudioStreamBasicDescription *format,
                       AudioBufferList *data, UInt32 frames, bool writable) {
    bool diagnostic=SAPDiagnosticsEnabled();
    uint64_t now = mach_absolute_time();
    atomic_store_explicit(&context->lastTick, now, memory_order_relaxed);
    if (!data || !format || format->mFormatID != kAudioFormatLinearPCM) return;
    if(frames && data->mNumberBuffers && data->mBuffers[0].mData && data->mBuffers[0].mDataByteSize)
        atomic_store_explicit(&context->receivedPCM,true,memory_order_relaxed);
    SAPPCMObserver callback = atomic_load_explicit(&observer, memory_order_acquire);
    // Keep timestamp/source availability for source selection.
    // Idle playback does not scan samples, count bytes or copy audio.
    if(!diagnostic && !callback)return;
    uint64_t bytes = 0;
    for (UInt32 i = 0; i < data->mNumberBuffers; ++i) {
        if (data->mBuffers[i].mData) bytes += availableBytes(&data->mBuffers[i], format, frames);
    }
    if(diagnostic) {
        atomic_fetch_add_explicit(&context->frames, frames, memory_order_relaxed);
        atomic_store_explicit(&context->lastFrames, frames, memory_order_relaxed);
        atomic_fetch_add_explicit(&context->bytes, bytes, memory_order_relaxed);
    }
    if (diagnostic && formatSupported(format)) {
        uint32_t level = peak(data, format, frames);
        atomic_store_explicit(&context->peak, level, memory_order_relaxed);
        if (level) atomic_fetch_add_explicit(&context->nonzero, 1, memory_order_relaxed);
    }
    if (writable && callback) callback(format, data, frames);
}

static OSStatus render(void *refcon, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    SAPContext *context = refcon;
    OSStatus status = context->original.inputProc(context->original.inputProcRefCon, flags, time, bus, frames, data);
    if(SAPDiagnosticsEnabled())atomic_fetch_add_explicit(&context->callbacks, 1, memory_order_relaxed);
    if (status != noErr) {
        if(SAPDiagnosticsEnabled())atomic_fetch_add_explicit(&context->errors, 1, memory_order_relaxed);
        return status;
    }
    processPCM(context, atomic_load_explicit(&context->format, memory_order_acquire), data, frames, true);
    return status;
}

bool SAPWantsMutableBuffers(void) {
    return atomic_load(&observer) != NULL;
}
void SAPNoteObjCHooks(unsigned count) { atomic_store(&objcHooks, count); }
void SAPNoteScheduledBuffer(bool sampleBuffer, uint32_t formatID) {
    if(!SAPDiagnosticsEnabled())return;
    atomic_fetch_add(sampleBuffer ? &sampleBufferCalls : &playerBufferCalls, 1);
    atomic_store(&lastSampleFormat, formatID);
    if (formatID && formatID != kAudioFormatLinearPCM) atomic_fetch_add(&compressedBuffers, 1);
}
void SAPNoteExtractionError(void) { atomic_fetch_add(&extractionErrors, 1); }

void SAPProcessExternal(const void *identity, const char *path,
                        const AudioStreamBasicDescription *format,
                        AudioBufferList *data, UInt32 frames, bool writable) {
    if (!identity || !format || format->mFormatID != kAudioFormatLinearPCM) return;
    SAPContext *context = NULL;
    unsigned count = atomic_load_explicit(&contextCount, memory_order_acquire);
    // Bounded fixed registry; no lock, allocation or file I/O in steady state.
    for (unsigned i = 0; i < count; ++i) {
        SAPContext *c = &contexts[i];
        if (!atomic_load_explicit(&c->published, memory_order_acquire)) continue;
        const AudioStreamBasicDescription *f = atomic_load_explicit(&c->format, memory_order_acquire);
        if (c->external && c->unit == (AudioUnit)identity && !atomic_load(&c->retired)
            && f && !memcmp(f, format, sizeof(*f))) { context = c; break; }
    }
    if (!context) {
        pthread_mutex_lock(&setupLock);
        count = atomic_load(&contextCount);
        for (unsigned i = 0; i < count; ++i) {
            SAPContext *c = &contexts[i];
            const AudioStreamBasicDescription *f = atomic_load(&c->format);
            if (atomic_load(&c->published) && c->external && c->unit == (AudioUnit)identity && !atomic_load(&c->retired)) {
                if (f && !memcmp(f, format, sizeof(*f))) { context = c; break; }
                atomic_store(&c->retired, true);
            }
        }
        if (!context && count < SAP_MAX_CONTEXTS && formatCount < SAP_MAX_FORMATS) {
            context = &contexts[count]; context->external = true; context->unit = (AudioUnit)identity;
            snprintf(context->image, sizeof(context->image), "%s", path);
            formats[formatCount] = *format;
            atomic_store(&context->format, &formats[formatCount++]);
            atomic_store_explicit(&context->published, true, memory_order_release);
            atomic_store_explicit(&contextCount, count + 1, memory_order_release);
        }
        if (!context) atomic_store(&exhausted, true);
        pthread_mutex_unlock(&setupLock);
    }
    if (context) {
        if(SAPDiagnosticsEnabled())atomic_fetch_add(&context->callbacks, 1);
        processPCM(context, format, data, frames, writable);
    }
}

// These five exports replace only Spotify's selected import bindings. Calls
// from the probe to AudioToolbox use the resolved system addresses above.
SAP_EXPORT OSStatus AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                                        AudioUnitElement element, const void *data, UInt32 size) {
    if (!ready()) return kAudioUnitErr_Uninitialized;
    atomic_fetch_add(&setCalls, 1);
    if (property == kAudioUnitProperty_SetRenderCallback && data && size == sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *incoming = data;
        AudioComponentDescription description = {0};
        atomic_fetch_add(&callbackAttempts, 1);
        atomic_store(&lastScope, scope);
        atomic_store(&lastElement, element);
        OSStatus described = api.describe(unit, &description);
        atomic_store(&lastType, description.componentType);
        atomic_store(&lastSubtype, description.componentSubType);
        // Spotify 9.1.88 registers the PCM producer on an AU format converter
        // (aufc), upstream of the output unit. Restricting this to auou silently
        // rejected that callback even though all import hooks were running.
        bool supportedUnit = description.componentType == kAudioUnitType_FormatConverter
            || (description.componentType == kAudioUnitType_Output && element == 0);
        if (incoming->inputProc && incoming->inputProc != render && (scope == kAudioUnitScope_Input || scope == kAudioUnitScope_Global) 
            && described == noErr && supportedUnit) {
            pthread_mutex_lock(&setupLock);
            unsigned index = atomic_load(&contextCount);
            if (index < SAP_MAX_CONTEXTS) {
                SAPContext *context = &contexts[index];
                context->unit = unit; context->scope = scope; context->element = element;
                context->original = *incoming;
                Dl_info info = {0};
                if (dladdr((const void *)incoming->inputProc, &info) && info.dli_fname)
                    snprintf(context->image, sizeof(context->image), "%s", info.dli_fname);
                updateFormat(context);
                atomic_store_explicit(&contextCount, index + 1, memory_order_release);
                AURenderCallbackStruct replacement = {render, context};
                OSStatus result = api.set(unit, property, scope, element, &replacement, sizeof(replacement));
                atomic_store(&lastSetStatus, result);
                if (result == noErr) {
                    for (unsigned i = 0; i < index; ++i)
                        if (contexts[i].unit == unit && contexts[i].scope == scope && contexts[i].element == element)
                            atomic_store(&contexts[i].retired, true);
                    atomic_store_explicit(&context->published, true, memory_order_release);
                }
                pthread_mutex_unlock(&setupLock);
                return result;
            }
            atomic_store(&exhausted, true);
            pthread_mutex_unlock(&setupLock);
        }
    }
    OSStatus status = api.set(unit, property, scope, element, data, size);
    atomic_store(&lastSetStatus, status);
    if (status == noErr && (property == kAudioUnitProperty_StreamFormat || property == kAudioUnitProperty_SetRenderCallback)) {
        pthread_mutex_lock(&setupLock);
        for (unsigned i = 0; i < atomic_load(&contextCount); ++i) {
            if (contexts[i].unit != unit) continue;
            if (property == kAudioUnitProperty_StreamFormat) updateFormat(&contexts[i]);
            else if (contexts[i].scope == scope && contexts[i].element == element) atomic_store(&contexts[i].retired, true);
        }
        pthread_mutex_unlock(&setupLock);
    }
    return status;
}

SAP_EXPORT OSStatus AudioUnitGetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                                        AudioUnitElement element, void *data, UInt32 *size) {
    if (!ready()) return kAudioUnitErr_Uninitialized;
    OSStatus status = api.get(unit, property, scope, element, data, size);
    if (status == noErr && property == kAudioUnitProperty_SetRenderCallback && data && size && *size >= sizeof(AURenderCallbackStruct)) {
        AURenderCallbackStruct *callback = data;
        if (callback->inputProc == render) {
            SAPContext *context = callback->inputProcRefCon;
            // The private refcon is exposed only by our own installed callback.
            if (context >= contexts && context < contexts + SAP_MAX_CONTEXTS) *callback = context->original;
        }
    }
    return status;
}

SAP_EXPORT OSStatus AudioOutputUnitStart(AudioUnit unit) {
    if (!ready()) return kAudioUnitErr_Uninitialized;
    pthread_mutex_lock(&setupLock);
    for (unsigned i = 0; i < atomic_load(&contextCount); ++i)
        if (contexts[i].unit == unit && !atomic_load(&contexts[i].retired)) updateFormat(&contexts[i]);
    pthread_mutex_unlock(&setupLock);
    OSStatus status = api.start(unit);
    if (status == noErr) atomic_fetch_add(&starts, 1);
    return status;
}

SAP_EXPORT OSStatus AudioOutputUnitStop(AudioUnit unit) {
    return ready() ? api.stop(unit) : kAudioUnitErr_Uninitialized;
}

SAP_EXPORT OSStatus AudioComponentInstanceDispose(AudioComponentInstance unit) {
    if (!ready()) return kAudioUnitErr_Uninitialized;
    OSStatus status = api.dispose(unit);
    if (status == noErr) {
        pthread_mutex_lock(&setupLock);
        for (unsigned i = 0; i < atomic_load(&contextCount); ++i)
            if (contexts[i].unit == unit) atomic_store(&contexts[i].retired, true);
        pthread_mutex_unlock(&setupLock);
    }
    return status;
}

SAP_EXPORT void SpotifyAudioProbeSetObserver(SAPPCMObserver callback) {
    atomic_store_explicit(&observer, callback, memory_order_release);
}

SAP_EXPORT void SpotifyAudioProbeReadSnapshot(SAPSnapshot *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->backendReady = atomic_load(&backendReady);
    out->poolExhausted = atomic_load(&exhausted);
    out->outputStarts = atomic_load(&starts);
    out->setPropertyCalls = atomic_load(&setCalls);
    out->callbackAttempts = atomic_load(&callbackAttempts);
    out->lastCallbackScope = atomic_load(&lastScope);
    out->lastComponentType = atomic_load(&lastType);
    out->lastCallbackElement = atomic_load(&lastElement);
    out->lastComponentSubtype = atomic_load(&lastSubtype);
    out->lastSetStatus = atomic_load(&lastSetStatus);
    out->objcHooks = atomic_load(&objcHooks);
    out->sampleBufferCalls = atomic_load(&sampleBufferCalls);
    out->playerBufferCalls = atomic_load(&playerBufferCalls);
    out->compressedBuffers = atomic_load(&compressedBuffers);
    out->extractionErrors = atomic_load(&extractionErrors);
    out->lastSampleFormat = atomic_load(&lastSampleFormat);
    unsigned count = atomic_load_explicit(&contextCount, memory_order_acquire);
    SAPContext *selected = NULL;
    for (unsigned i = 0; i < count; ++i) {
        SAPContext *context = &contexts[i];
        if (!atomic_load_explicit(&context->published, memory_order_acquire)) continue;
        out->registrations++;
        out->callbacks += atomic_load(&context->callbacks);
        out->frames += atomic_load(&context->frames);
        out->pcmBytes += atomic_load(&context->bytes);
        out->nonzeroCallbacks += atomic_load(&context->nonzero);
        out->callbackErrors += atomic_load(&context->errors);
        if (!selected || (atomic_load(&selected->retired) && !atomic_load(&context->retired))
            || (atomic_load(&selected->retired) == atomic_load(&context->retired)
                && atomic_load(&context->lastTick) >= atomic_load(&selected->lastTick))) selected = context;
    }
    if (!selected) return;
    const AudioStreamBasicDescription *format = atomic_load_explicit(&selected->format, memory_order_acquire);
    out->procAddress = (uintptr_t)selected->original.inputProc;
    out->unitAddress = (uintptr_t)selected->unit;
    out->retired = atomic_load(&selected->retired);
    out->lastFrames = atomic_load(&selected->lastFrames);
    out->peakMillionths = atomic_load(&selected->peak);
    uint64_t tick = atomic_load(&selected->lastTick);
    out->lastCallbackAgeSeconds = tick && timebase.denom ? (double)(mach_absolute_time() - tick) * timebase.numer / timebase.denom / 1e9 : -1;
    snprintf(out->callbackImage, sizeof(out->callbackImage), "%s", selected->image);
    if (format) {
        out->sampleRate = format->mSampleRate;
        out->channels = format->mChannelsPerFrame;
        out->formatID = format->mFormatID;
        out->formatFlags = format->mFormatFlags;
        out->bitsPerChannel = format->mBitsPerChannel;
    }
    out->pcmConfirmed = atomic_load(&selected->receivedPCM) && format && format->mFormatID == kAudioFormatLinearPCM;
}

#ifdef SAP_TESTING
void SAPTestUseBackend(SAPBackend backend) {
    api = backend;
    mach_timebase_info(&timebase);
    atomic_store(&backendReady, true);
}
#endif

bool SAPCopyActiveNativeCallback(uint64_t *proc, uint64_t *refcon) {
    if (!proc || !refcon) return false;
    SAPContext *selected = NULL;
    pthread_mutex_lock(&setupLock);
    unsigned count = atomic_load_explicit(&contextCount, memory_order_acquire);
    for (unsigned i = 0; i < count; ++i) {
        SAPContext *c = &contexts[i];
        if (!c->external && atomic_load_explicit(&c->published, memory_order_acquire) && !atomic_load(&c->retired)
            && (!selected || atomic_load(&c->lastTick) >= atomic_load(&selected->lastTick))) selected = c;
    }
    if (selected) {
        *proc = (uintptr_t)selected->original.inputProc;
        *refcon = (uintptr_t)selected->original.inputProcRefCon;
    }
    pthread_mutex_unlock(&setupLock);
    return selected != NULL;
}
