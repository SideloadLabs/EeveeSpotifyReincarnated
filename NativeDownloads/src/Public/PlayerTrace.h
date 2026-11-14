#pragma once
#import <Foundation/Foundation.h>

// Passive, bounded tracing of ContextPlayer requests and player state changes.
// No command is sent or modified. The sink receives sanitized dictionaries on
// this module's serial queue; it must not block that queue.
void SAPPlayerTraceSetSink(void (^sink)(NSDictionary *event));
void SAPPlayerTraceSetActive(BOOL active);
// Disable tracing, invalidate pending observations and clear stored events.
// The sink configuration is retained for the next explicit activation.
void SAPPlayerTraceReset(void);
void SAPObservePlayerRequest(id service, id method, id payload);
// Reads the native state immediately on the caller's thread; only sanitized
// immutable values are retained for asynchronous deduplication and logging.
void SAPObservePlayerState(id state);
NSDictionary *SAPPlayerTraceReport(void);
#ifdef SAP_TESTING
void SAPPlayerTraceDrainForTesting(void);
#endif
