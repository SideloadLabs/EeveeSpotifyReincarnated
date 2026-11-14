#pragma once
#import <Foundation/Foundation.h>
void SAPInstallOfflineConfig(void);
NSDictionary *SAPOfflineConfigReport(void);
// Pure transform, also exercised with captured-schema fixtures on the host.
NSData *SAPRewriteOfflineConfig(NSData *data, BOOL bootstrap);
BOOL SAPPrepareCachedOfflineConfig(NSUserDefaults *defaults);
