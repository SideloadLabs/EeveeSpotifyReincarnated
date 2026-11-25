#pragma once
#import <Foundation/Foundation.h>
void SAPNativeErrorLogSetActive(BOOL active);
// Eevee's lyrics queue: post EeveeOfflineAudioTrackDownloaded for each finished track.
__attribute__((visibility("default"))) void SAPNativeDownloadCompletionSetActive(BOOL active);
NSDictionary *SAPNativeErrorLogReport(void);
#ifdef SAP_TESTING
void SAPNativeErrorLogParseForTesting(NSString *line);
#endif
