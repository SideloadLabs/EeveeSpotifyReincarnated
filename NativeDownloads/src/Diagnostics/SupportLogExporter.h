#pragma once
#import <Foundation/Foundation.h>

// Native and UIKit values are captured by the caller before entering this queue.
dispatch_queue_t SAPReportQueue(void);
NSDictionary *SAPCompleteDiagnosticSnapshotWithJournal(NSDictionary *native,NSDictionary *journal);
NSDictionary *SAPCompleteDiagnosticSnapshot(NSDictionary *native);
// Call on main with an immutable native snapshot; completion returns on main.
void SAPExportSupportLog(NSDictionary *native,void (^completion)(NSURL *,NSError *));
