#pragma once
#import <Foundation/Foundation.h>
#include "OggExport.h"
// No source inspection, allocation or event when tracing is off or reset.
void SAPTraceOggValidation(FILE *file,const SAPOggExportDiagnostics *validation,
    uint64_t expected,NSDictionary *context,uint64_t generation);

void SAPTraceOggValidationCancellable(FILE *file,const SAPOggExportDiagnostics *validation,uint64_t expected,NSDictionary *context,uint64_t generation,SAPExportContinue keepGoing,void *workerContext);
