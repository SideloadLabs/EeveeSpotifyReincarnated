#pragma once
#import <Foundation/Foundation.h>
void SAPRefreshDownloadCompatibility(void (^completion)(NSDictionary *));
NSDictionary *SAPDownloadCompatibilityReport(void);
// A fresh complete read permits an experiment, never guarantees downloading.
NSString *SAPModeChangeBlockReason(NSDictionary *report);
NSString *SAPDownloadCompatibilityText(NSDictionary *report);
