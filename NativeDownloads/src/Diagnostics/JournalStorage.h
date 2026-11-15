#pragma once
#import <Foundation/Foundation.h>

// Shared path policy for diagnostic writers and formatting.
NSURL *SAPJournalDocumentsURL(NSString *name);
// The caller owns serialization on the journal queue. These functions add no
// queue, buffering or retry and preserve immediate writes and rotation limits.
void SAPJournalWriterAppendActionData(NSData *line);
void SAPJournalWriterFlushActions(void);
void SAPJournalWriterClose(BOOL resetCounters);
void SAPJournalWriterWrite(NSString *kind,NSString *detail);
void SAPJournalWriterLog(NSString *kind,NSString *format,...) NS_FORMAT_FUNCTION(2,3);
