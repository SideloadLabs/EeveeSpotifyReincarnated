#pragma once
#import <Foundation/Foundation.h>

// Call only after the app's confirmation. Removes native policies and saved
// flags only for this exact selection. Never deletes Spotify files directly.
// Returns before any main-queue callback. Cancellation stops new work and
// completes once with verified partial results plus an explicit error.
// Each result: uri, name, offline_removed, library_removed, detail. A true flag
// requires a fresh exact native readback; command acknowledgement is insufficient.
// Completion error (with an empty result list) when a selected track belongs to an album or playlist that
// is still downloading. Nothing is sent to Spotify in that case: the held tracks could not be removed
// until the download ends. Callers show a short "wait for the download" message.
extern NSString *const SAPOfflineLibraryDeleteBusyError;
NSProgress *SAPDeleteOfflineLibrarySelection(NSArray<NSDictionary *> *rows,
    void (^event)(NSDictionary *event),
    void (^completion)(NSArray<NSDictionary *> *results,NSString *error));
