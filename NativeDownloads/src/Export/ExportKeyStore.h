#pragma once
#import <Foundation/Foundation.h>
// Bounded process-only media-key store fed by the guarded native observers
// declared in TrackExport.h. Keys are never logged, serialized or exported; the
// Keychain vault only receives verified unsealed keys. Thread-safe.
BOOL SAPExportKeyStoreCopyKey(NSData *fileIdentifier, uint8_t key[16]);
BOOL SAPExportKeyStoreCopyBlob(NSData *fileIdentifier, uint8_t blob[28]);
BOOL SAPExportKeyStoreIsUnsealed(NSData *fileIdentifier);
// Counters only, for the support report.
NSDictionary *SAPExportKeyStoreReport(void);
