#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#define SAP_EXPORT __attribute__((visibility("default")))

// Called AFTER Spotify fills the buffer and BEFORE the output unit consumes it.
// The callback runs on the audio thread: no allocation, locks, UI or file I/O.
// Buffers are borrowed for this call only; an observer may modify them in place.
typedef void (*SAPPCMObserver)(const AudioStreamBasicDescription *format,
                               AudioBufferList *buffers, UInt32 frames);
SAP_EXPORT void SpotifyAudioProbeSetObserver(SAPPCMObserver observer);

typedef struct {
    bool backendReady;
    bool poolExhausted;
    bool pcmConfirmed;
    bool retired;
    uint32_t setPropertyCalls, callbackAttempts, lastCallbackScope, lastComponentType;
    uint32_t lastCallbackElement, lastComponentSubtype;
    int32_t lastSetStatus;
    uint32_t objcHooks;
    uint64_t sampleBufferCalls, playerBufferCalls, compressedBuffers, extractionErrors;
    uint32_t lastSampleFormat;
    uint32_t registrations;
    uint32_t outputStarts;
    uint64_t callbacks;
    uint64_t frames;
    uint64_t pcmBytes;
    uint64_t nonzeroCallbacks;
    uint64_t callbackErrors;
    uint64_t procAddress;
    uint64_t unitAddress;
    double sampleRate;
    double lastCallbackAgeSeconds;
    uint32_t channels;
    uint32_t formatID;
    uint32_t formatFlags;
    uint32_t bitsPerChannel;
    uint32_t lastFrames;
    uint32_t peakMillionths;
    char callbackImage[256];
} SAPSnapshot;

SAP_EXPORT void SpotifyAudioProbeReadSnapshot(SAPSnapshot *snapshot);
SAP_EXPORT void SpotifyAudioProbeInitialize(void);

// Producer-side paths (AVFoundation scheduling, not the hardware render thread).
void SAPProcessExternal(const void *identity, const char *path,
                        const AudioStreamBasicDescription *format,
                        AudioBufferList *buffers, UInt32 frames, bool writable);
bool SAPWantsMutableBuffers(void);
void SAPNoteObjCHooks(unsigned count);
void SAPNoteScheduledBuffer(bool sampleBuffer, uint32_t formatID);
void SAPNoteExtractionError(void);
void SAPInstallAVHooks(void);
