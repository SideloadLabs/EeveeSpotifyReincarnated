#pragma once
// Cooperative worker boundary. Nonzero permits the next bounded unit of I/O.
// NULL preserves the original non-cancellable API contract.
typedef int (*SAPExportContinue)(void *context);
static inline int SAPExportMayContinue(SAPExportContinue callback,void *context) {
    return !callback || callback(context);
}
