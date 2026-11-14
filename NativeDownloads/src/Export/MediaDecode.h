#pragma once
#include "ExportCancellation.h"
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

// One bounded hypothesis for Spotify's cached-media layer. The builder only
// describes combinations; it never persists key material or writes it to logs.
typedef struct {
    uint8_t key[32];
    uint8_t keyLength;
    uint8_t iv[16];
    int little_endian;   // 0 = AES-CTR big-endian counter, 1 = little-endian
    uint64_t skip;       // encrypted stream begins at this source offset
    uint64_t counter;    // initial AES counter block; may differ from skip when a plaintext header is present
    const char *keyLabel;  // static key-source label, never key bytes
    const char *ivLabel;   // static IV-source label, never key bytes
} SAPMediaVariant;

// Builds a deduplicated, bounded, prioritised candidate list from the
// process-only 16-byte callback key and/or the native 28-byte key material.
// Returns the number written (never more than capacity).
size_t SAPMediaBuildVariants(const uint8_t fileID[20], uint32_t kind, uint32_t index,
                             const uint8_t *callbackKey16,
                             const uint8_t *nativeBlob28,
                             const uint8_t *keys24, size_t key24Count,
                             const uint8_t *contexts, const uint8_t *contextLengths, size_t contextCount,
                             SAPMediaVariant *out, size_t capacity);

// Decrypts input[skip...] to output and returns 1 on success. The source is
// only read; the destination is truncated first by the caller.
int SAPMediaDecryptFile(FILE *input, FILE *output, const SAPMediaVariant *variant);

// Decrypts at most `limit` bytes and reports whether a complete Vorbis
// identification page (BOS, CRC, header signature) appears. Used to avoid a
// full-file pass for hypotheses that are obviously wrong.
int SAPMediaPreview(FILE *input, const SAPMediaVariant *variant, uint64_t limit);

int SAPMediaDecryptFileCancellable(FILE *input,FILE *output,const SAPMediaVariant *variant,SAPExportContinue keepGoing,void *context);
