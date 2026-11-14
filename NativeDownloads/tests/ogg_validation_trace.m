#import "OggValidationTrace.h"
#import "OggInspection.h"
#import "DiagnosticTrace.h"
#include <assert.h>
static BOOL enabled,resetDuring,resetAtEnqueue,cancelDuring,workerCancelled;static uint64_t generation=1;static NSUInteger inspections,events;static NSDictionary *captured;
bool SAPTraceIsActive(void){return enabled;}uint64_t SAPTraceGeneration(void){return generation;}
int SAPInspectOggExport(FILE *f,const SAPOggExportDiagnostics *d,uint64_t expected,SAPOggInspection *out,SAPOggInspectionContinue keep,void *ctx){
 inspections++;assert(keep(ctx));if(cancelDuring){workerCancelled=YES;assert(!keep(ctx));return 0;}if(resetDuring){generation++;assert(!keep(ctx));return 0;}
 out->eos_found=1;out->eos_end_offset=100;out->source_bytes=116;out->eos_duration_ms=10000;out->duration_checked=1;out->duration_matches=1;out->tail_bytes=16;out->tail_scanned=16;out->tail_scan_complete=1;out->tail_zero_bytes=16;out->position_restored=1;return 1;
}
const char *SAPOggTailSignatureName(uint64_t value){return "unknown";}
void SAPTraceEvent(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts){assert(!strcmp(stage,"ogg_validation_detail"));events++;captured=facts;}
void SAPTraceEventAtGeneration(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts,uint64_t epoch){if(resetAtEnqueue)generation++;if(enabled&&epoch==generation)SAPTraceEvent(category,stage,operation,facts);}
static int workerContinues(void *ctx){return !workerCancelled;}
int main(void){@autoreleasepool {
 SAPOggExportDiagnostics d={.status=SAPOggExportTrailingData,.input_bytes=116,.failure_offset=100};
 SAPTraceOggValidation(NULL,&d,10000,@{@"track_uri":@"track"},generation);assert(!inspections&&!events);
 enabled=YES;SAPTraceOggValidation(NULL,&d,10000,@{@"track_uri":@"track"},generation);assert(inspections==1&&events==1);
 assert([captured[@"tail"][@"bytes"]unsignedIntegerValue]==16&&[captured[@"eos"][@"duration_matches_expected"]boolValue]);
 assert([NSJSONSerialization dataWithJSONObject:captured options:0 error:nil]);assert(![captured[@"raw_bytes_in_log"]boolValue]&&![captured[@"inspection_changes_export_acceptance"]boolValue]);
 resetDuring=YES;SAPTraceOggValidation(NULL,&d,10000,@{},generation);assert(inspections==2&&events==1);
 resetDuring=NO;resetAtEnqueue=YES;SAPTraceOggValidation(NULL,&d,10000,@{},generation);assert(inspections==3&&events==1);
 enabled=NO;SAPTraceOggValidation(NULL,&d,10000,@{},generation);assert(inspections==3&&events==1);
 enabled=YES;resetAtEnqueue=NO;cancelDuring=YES;
 SAPTraceOggValidationCancellable(NULL,&d,10000,@{},generation,workerContinues,NULL);assert(inspections==4&&events==1);
 SAPTraceOggValidationCancellable(NULL,&d,10000,@{},generation,workerContinues,NULL);assert(inspections==4&&events==1);
 puts("ogg_validation_trace PASS: off/reset suppress inspection/events, scalar JSON only");
}}
