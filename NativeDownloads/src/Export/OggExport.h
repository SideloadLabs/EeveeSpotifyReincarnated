#pragma once
#include "ExportCancellation.h"
#include <stdio.h>
#include <stdint.h>
typedef enum {
    SAPOggExportOK = 0,
    SAPOggExportInvalidArguments,
    SAPOggExportSeekFailed,
    SAPOggExportTellFailed,
    SAPOggExportInputTooShort,
    SAPOggExportReadFailed,
    SAPOggExportVorbisBOSNotFound,
    SAPOggExportTrailingData,
    SAPOggExportTruncatedPageHeader,
    SAPOggExportInvalidPageHeader,
    SAPOggExportTruncatedSegmentTable,
    SAPOggExportTruncatedPageBody,
    SAPOggExportCRCMismatch,
    SAPOggExportInvalidIdentificationHeader,
    SAPOggExportInvalidSampleRate,
    SAPOggExportUnexpectedBOS,
    SAPOggExportSerialMismatch,
    SAPOggExportSequenceMismatch,
    SAPOggExportGranuleRegression,
    SAPOggExportContinuationMismatch,
    SAPOggExportInvalidVorbisHeaderOrder,
    SAPOggExportMissingVorbisHeaders,
    SAPOggExportUnfinishedPacket,
    SAPOggExportMissingEOS,
    SAPOggExportInvalidGranule,
    SAPOggExportDurationMismatch,
    SAPOggExportInspectionCancelled
} SAPOggExportStatus;

// Scalar diagnostics only: no file contents or key material.
typedef struct {
    SAPOggExportStatus status;
    uint64_t input_bytes;
    uint64_t stream_offset;
    // Pages passing framing, CRC and packet checks before the failure.
    uint64_t pages_validated;
    // Absolute file byte offset: page start, or EOF for final stream checks.
    uint64_t failure_offset;
    uint32_t sample_rate;
    // Set when the final granule permits a duration calculation.
    uint64_t observed_duration_ms;
    // Distinguishes a discovered stream at offset zero from no stream found.
    int has_stream_offset;
} SAPOggExportDiagnostics;

const char *SAPOggExportStatusName(SAPOggExportStatus status);
uint32_t SAPOggChecksum(const uint8_t *bytes,size_t length,uint32_t initial);
// True when `buffer` contains a complete, CRC-valid Vorbis identification page
// at a BOS position. Used to reject wrong decryption hypotheses cheaply without
// writing a full candidate file.
int SAPOggBufferHasVorbisBOS(const uint8_t *buffer, size_t length, size_t *offset);
// Checks Ogg framing/CRCs and basic Vorbis header order, not codec decodability.
// Returns its byte offset after an optional Spotify prefix (bounded to 256 KiB).
// Length excludes an optional 1-3-byte zero trailer to the next absolute 4-byte
// boundary. All stream and expected-duration checks still apply before acceptance.
int SAPValidateOggExport(FILE *file, uint64_t expected_ms, uint64_t *offset, uint64_t *length);
int SAPValidateOggExportDetailed(FILE *file, uint64_t expected_ms, uint64_t *offset, uint64_t *length, SAPOggExportDiagnostics *diagnostics);
// Diagnostics only: inspect a separately discovered following stream to EOF.
// This never participates in deciding whether the original export is accepted.
typedef int (*SAPOggDiagnosticsContinue)(void *context);
int SAPDiagnoseOggStreamFrom(FILE *file,uint64_t start,SAPOggExportDiagnostics *diagnostics,SAPOggDiagnosticsContinue keepGoing,void *context);

int SAPValidateOggExportDetailedCancellable(FILE *file,uint64_t expected_ms,uint64_t *offset,uint64_t *length,SAPOggExportDiagnostics *diagnostics,SAPExportContinue keepGoing,void *context);
