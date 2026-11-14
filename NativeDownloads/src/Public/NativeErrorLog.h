#pragma once
#import <Foundation/Foundation.h>
void SAPNativeErrorLogSetActive(BOOL active);
NSDictionary *SAPNativeErrorLogReport(void);
#ifdef SAP_TESTING
void SAPNativeErrorLogParseForTesting(NSString *line);
#endif
