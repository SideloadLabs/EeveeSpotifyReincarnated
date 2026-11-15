#pragma once
#import <Foundation/Foundation.h>
// Functional observer is registered by the audio exporter at startup. Optional
// diagnostics keep their own gate and never serialize the observed key bytes.
typedef void (*SAPOfflineKeySuccessObserver)(const uint64_t *,uintptr_t);
void SAPSetOfflineKeySuccessObserver(SAPOfflineKeySuccessObserver observer);
NSDictionary *SAPNativeKeyTraceReport(void);
void SAPNativeKeyTraceResetSegment(void);
void SAPNativeKeyTraceObserveMetadata(NSString *service,NSString *method,NSString *requestURI,NSData *response);
#ifdef SAP_TESTING
void SAPTraceNativeBoundaryForTesting(unsigned kind,const uint64_t *registers);
#endif
