#pragma once
#import <Foundation/Foundation.h>

NSDictionary *SAPCurrentExportTrack(void);
void SAPMakeEntityAvailableOffline(NSString *uri,NSArray<NSString *> *tracks,
                                  void (^completion)(BOOL,NSString *));
void SAPResetEntityOffline(NSString *uri,void (^completion)(BOOL,NSString *));
