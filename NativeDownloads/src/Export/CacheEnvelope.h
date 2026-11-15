#pragma once
#include "ExportCancellation.h"
#include <stdint.h>
#include <stdio.h>

typedef struct {
    const char *status;
    uint64_t physical_bytes,payload_bytes,payload_offset;
    unsigned blocks;
    int encrypted,metadata_at_end;
} SAPCacheEnvelopeDetails;

// Extracts only a complete native cache container. The source is read-only.
// Keys and decoded header contents are never returned in diagnostic details.
int SAPExtractCacheEnvelope(FILE *input,FILE *output,const uint8_t *storageKey,
                           const uint8_t descriptor[24],SAPCacheEnvelopeDetails *details);

int SAPExtractCacheEnvelopeCancellable(FILE *input,FILE *output,const uint8_t *storageKey,const uint8_t descriptor[24],SAPCacheEnvelopeDetails *details,SAPExportContinue keepGoing,void *context);
