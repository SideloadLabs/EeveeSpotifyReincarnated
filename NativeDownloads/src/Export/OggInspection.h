#pragma once
#include "OggExport.h"
// Read-only scalar observations; never retains or emits source bytes.
typedef struct {
    uint64_t offset,header_present,valid_header,complete,bytes,version,flags;
    uint64_t serial,sequence,granule,stored_crc,computed_crc,crc_checked,crc_matches,vorbis_bos;
} SAPOggPageInspection;
typedef struct {
    uint64_t source_bytes,source_size_changed,io_error,cancelled,position_restored;
    uint64_t eos_found,eos_end_offset,eos_duration_ms,duration_checked,duration_matches;
    uint64_t tail_bytes,tail_scanned,tail_scan_complete,tail_zero_bytes,tail_leading_zeros,tail_trailing_zeros;
    uint64_t tail_distinct_bytes,tail_uniform,tail_uniform_byte,tail_pkcs7_shape,tail_x923_shape,tail_entropy_millibits,tail_signature,tail_crc32;
    uint64_t ogg_magic_count,page_candidates_checked,page_probe_limit_reached,valid_tail_pages;
    uint64_t following_bos_found,following_offset,following_status,following_pages,following_duration_ms;
    SAPOggPageInspection eos_page,failure_page,first_tail_page;
} SAPOggInspection;
typedef int (*SAPOggInspectionContinue)(void *context);
int SAPInspectOggExport(FILE *file,const SAPOggExportDiagnostics *validation,uint64_t expected_ms,
    SAPOggInspection *result,SAPOggInspectionContinue keepGoing,void *context);
const char *SAPOggTailSignatureName(uint64_t signature);
