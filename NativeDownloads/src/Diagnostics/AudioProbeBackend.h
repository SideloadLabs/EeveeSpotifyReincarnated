#pragma once
#include "AudioProbe.h"

// Also used by the host integration tests; never read from the audio thread.
typedef struct {
    OSStatus (*set)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
    OSStatus (*get)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *);
    OSStatus (*start)(AudioUnit);
    OSStatus (*stop)(AudioUnit);
    OSStatus (*dispose)(AudioComponentInstance);
    OSStatus (*describe)(AudioUnit, AudioComponentDescription *);
} SAPBackend;

#ifdef SAP_TESTING
void SAPTestUseBackend(SAPBackend backend);
#endif

// Copies immutable registration metadata for manual source diagnostics.
bool SAPCopyActiveNativeCallback(uint64_t *proc, uint64_t *refcon);
