#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef enum {
    SAPM4AExportOK = 0,
    SAPM4AExportInvalidArguments = 1,
    SAPM4AExportCancelled = 2,
    SAPM4AExportInvalidInput = 3,
    SAPM4AExportDecodeFailed = 4,
    SAPM4AExportEncodeFailed = 5,
    SAPM4AExportWriteFailed = 6,
    SAPM4AExportOutputExists = 7
} SAPM4AExportStatus;
typedef struct {
    const char *title;
    const char *artist;
    const char *album;
    const char *track;
    const char *year;
    const unsigned char *jpeg_cover;
    size_t jpeg_cover_length;
} SAPM4AExportMetadata;
typedef int (*SAPM4AExportCancellation)(void *context);
typedef void (*SAPM4AExportProgress)(double fraction, void *context);
// Blocking worker API; callbacks are synchronous on the caller's thread.
// Streams bounded mono/stereo Vorbis PCM to native AAC-LC in a genuine M4A.
// Targets 320 kbps, constrained to the native encoder's supported bitrate.
// Keeps sample rate/channels where native AAC supports them; otherwise resamples.
// Input remains immutable. Atomically publishes only a complete file, without
// overwriting any existing output. Failure/cancellation removes temporary files.
SAPM4AExportStatus SAPExportOggToM4A(const char *input_path, const char *output_path,
    const SAPM4AExportMetadata *metadata, SAPM4AExportCancellation cancelled,
    SAPM4AExportProgress progress, void *context);
#ifdef __cplusplus
}
#endif
