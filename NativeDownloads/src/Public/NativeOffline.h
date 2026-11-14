#pragma once
#import <Foundation/Foundation.h>

void SAPInstallNativeOffline(void);
NSDictionary *SAPKeyRequestModeReport(void);
void SAPSetKeyRequestMode(NSInteger mode, void (^completion)(BOOL changed, NSString *reason));
void SAPReadNativeOfflineQuota(void (^completion)(NSDictionary *));
void SAPPrepareNativeOffline(BOOL (^stillRequested)(void), void (^completion)(BOOL, NSString *));
BOOL SAPSubmitNativeAlbumDownload(NSString *albumURI,NSArray<NSString *> *trackURIs,NSString **reason);
// User-confirmed export refresh only. Return means invocation, not completion.
BOOL SAPResetNativeEntityDownload(NSString *uri,NSString **reason);
NSDictionary *SAPNativeOfflineReport(void);
void SAPSampleNativeOffline(void);
void SAPReadNativeTrackState(NSString *uri);
#ifdef SAP_RUNTIME_TESTING
id SAPNativeOfflineWrapperForTesting(void);
void SAPNativeOfflineSnapshotForTesting(void (^completion)(NSDictionary *));
void SAPNativeOfflineZeroUpdateForTesting(void (^completion)(NSDictionary *));
#endif
