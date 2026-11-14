#pragma once
#import <Foundation/Foundation.h>
void SAPPreviewOfflineDeviceSlots(void (^completion)(NSDictionary *plan,NSString *error));
// Preview includes all records and source states, even when actions are blocked.
// Selection tokens bind a reviewed exact device_id + cache_id pair.
void SAPDisableOfflineDevice(NSString *planID,NSString *selectionToken,
                             void (^completion)(NSDictionary *result,NSString *error));
void SAPReleaseOfflineDeviceSlots(NSString *planID,NSArray<NSString *> *cacheIDs,
                                  void (^completion)(NSDictionary *result,NSString *error));
void SAPEnableOfflineOnCurrentDevice(void (^completion)(NSDictionary *result,NSString *error));
#ifdef SAP_TESTING
void SAPOfflineDevicesTestEnvironment(Class protocolClass,void (^provider)(void (^)(NSDictionary *)));
#endif
