#pragma once
#import <Foundation/Foundation.h>
// Metadata only. Native observers validate/copy/enqueue; SQLite runs solely on
// a serial utility queue. Extra dictionary fields are never persisted.
void SAPExportCacheIndexObserve(NSData *fileID, NSDictionary *candidate);
// Blocking export-worker read. Returns at most 64 newest candidates for fileID.
NSArray<NSDictionary *> *SAPExportCacheIndexCandidates(NSData *fileID);
// Scalar health counters only; no identifiers, paths, keys or credentials.
NSDictionary *SAPExportCacheIndexReport(void);
#ifdef SAP_TESTING
void SAPExportCacheIndexSetPathForTesting(NSString *path);
void SAPExportCacheIndexCloseForTesting(void);
#endif
