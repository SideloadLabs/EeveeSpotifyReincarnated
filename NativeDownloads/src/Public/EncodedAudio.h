#pragma once
#import <Foundation/Foundation.h>

// Snapshot of keys observed from Spotify's own offline-key completion.
// Key bytes are kept only in process memory and never included in reports.
void SAPWithObservedAudioKey(NSData *fileID, void (^block)(NSData *key));
NSUInteger SAPObservedAudioKeyCount(void);
