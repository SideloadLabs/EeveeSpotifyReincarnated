#import "OggValidationTrace.h"
#import "OggInspection.h"
#import "DiagnosticTrace.h"
typedef struct {uint64_t generation;SAPExportContinue keepGoing;void *workerContext;} SAPOggTraceInspectionContext;
static int keepInspecting(void *context){SAPOggTraceInspectionContext *state=context;return SAPTraceIsActive() && SAPTraceGeneration()==state->generation && SAPExportMayContinue(state->keepGoing,state->workerContext);}
static NSDictionary *pageInfo(SAPOggPageInspection p) {
    return @{@"offset":@(p.offset),@"header_present":@(p.header_present),@"header_valid":@(p.valid_header),@"complete":@(p.complete),@"declared_bytes":@(p.bytes),@"version":@(p.version),@"flags":@(p.flags),@"serial":@(p.serial),@"sequence":@(p.sequence),@"granule":@(p.granule),@"stored_crc":@(p.stored_crc),@"computed_crc":@(p.computed_crc),@"crc_checked":@(p.crc_checked),@"crc_matches":@(p.crc_matches),@"vorbis_bos":@(p.vorbis_bos)};
}
void SAPTraceOggValidationCancellable(FILE *file,const SAPOggExportDiagnostics *d,uint64_t expected,NSDictionary *context,uint64_t generation,SAPExportContinue keepGoing,void *workerContext) {
    SAPOggTraceInspectionContext state={generation,keepGoing,workerContext};
    if(!d || !keepInspecting(&state))return;
    SAPOggInspection info={0};BOOL complete=SAPInspectOggExport(file,d,expected,&info,keepInspecting,&state);
    if(!keepInspecting(&state))return;
    NSMutableDictionary *facts=[context mutableCopy]?:NSMutableDictionary.dictionary;
    facts[@"validation"]=@{@"status":@(SAPOggExportStatusName(d->status)),@"input_bytes":@(d->input_bytes),@"stream_offset":d->has_stream_offset?@(d->stream_offset):NSNull.null,@"failure_offset":@(d->failure_offset),@"pages_validated":@(d->pages_validated),@"sample_rate":@(d->sample_rate),@"expected_duration_ms":@(expected),@"original_observed_duration_ms":@(d->observed_duration_ms)};
    facts[@"inspection"]=@{@"complete":@(complete),@"io_error":@(info.io_error),@"cancelled":@(info.cancelled),@"position_restored":@(info.position_restored),@"observed_input_bytes":@(info.source_bytes),@"source_size_changed":@(info.source_size_changed)};
    facts[@"failure_page"]=pageInfo(info.failure_page);
    facts[@"eos"]=@{@"found":@(info.eos_found),@"end_offset":@(info.eos_end_offset),@"audio_bytes":@(info.eos_found && info.eos_end_offset>=d->stream_offset?info.eos_end_offset-d->stream_offset:0),@"duration_ms":@(info.eos_duration_ms),@"duration_checked":@(info.duration_checked),@"duration_matches_expected":info.duration_checked?@(info.duration_matches):NSNull.null,@"page":pageInfo(info.eos_page)};
    facts[@"tail"]=@{@"bytes":@(info.tail_bytes),@"scanned_bytes":@(info.tail_scanned),@"byte_scan_complete":@(info.tail_scan_complete),@"zero_bytes":@(info.tail_zero_bytes),@"all_zero":@(info.tail_bytes && info.tail_zero_bytes==info.tail_bytes),@"leading_zero_bytes":@(info.tail_leading_zeros),@"trailing_zero_bytes":@(info.tail_trailing_zeros),@"distinct_byte_values":@(info.tail_distinct_bytes),@"uniform":@(info.tail_uniform),@"uniform_byte":info.tail_uniform?@(info.tail_uniform_byte):NSNull.null,@"pkcs7_shape":@(info.tail_pkcs7_shape),@"ansi_x923_shape":@(info.tail_x923_shape),@"entropy_bits_per_byte":@((double)info.tail_entropy_millibits/1000),@"signature":@(SAPOggTailSignatureName(info.tail_signature)),@"ogg_crc32_fingerprint":@(info.tail_crc32),@"eos_offset_mod16":@(info.eos_end_offset%16),@"size_mod16":@(info.source_bytes%16),@"bytes_mod16":@(info.tail_bytes%16)};
    facts[@"following_ogg"]=@{@"magic_count":@(info.ogg_magic_count),@"candidates_probed":@(info.page_candidates_checked),@"probe_limit":@64,@"probe_limit_reached":@(info.page_probe_limit_reached),@"crc_valid_pages_in_probe":@(info.valid_tail_pages),@"first_valid_page":pageInfo(info.first_tail_page),@"vorbis_bos_found":@(info.following_bos_found),@"stream_offset":info.following_bos_found?@(info.following_offset):NSNull.null,@"validation_status":info.following_bos_found?@(SAPOggExportStatusName((SAPOggExportStatus)info.following_status)):NSNull.null,@"pages_validated":@(info.following_pages),@"duration_ms":@(info.following_duration_ms)};
    facts[@"offset_basis"]=@"absolute bytes in this decrypted candidate";
    facts[@"classification"]=@"observed signatures and padding shapes; no trailer interpretation assumed";
    facts[@"accepted_zero_alignment_bytes"]=@(d->status==SAPOggExportOK&&info.tail_bytes<=3&&info.tail_zero_bytes==info.tail_bytes&&info.source_bytes%4==0?info.tail_bytes:0);
    facts[@"validation_policy"]=@"complete Ogg stream; only zero alignment to the next absolute 4-byte boundary may follow EOS";
    facts[@"raw_bytes_in_log"]=@NO;facts[@"key_in_log"]=@NO;facts[@"inspection_changes_export_acceptance"]=@NO;
    SAPTraceEventAtGeneration("export","ogg_validation_detail",0,facts,generation);
}

void SAPTraceOggValidation(FILE *file,const SAPOggExportDiagnostics *d,uint64_t expected,NSDictionary *context,uint64_t generation) {SAPTraceOggValidationCancellable(file,d,expected,context,generation,NULL,NULL);}
