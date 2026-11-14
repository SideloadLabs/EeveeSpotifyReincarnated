#pragma once
#import <Foundation/Foundation.h>

// Enumerates native local Offline contexts with item policy enabled, then
// validates each unique track using GetItems (DOWNLOADED == 3). No journal,
// session or export-folder fallback. Main-queue callbacks; cancellation is
// idempotent and suppresses all later progress/completion calls.
// nil tracks means enumeration/validation failed. Non-nil tracks plus error
// means the native catalog is loaded but some metadata could not be hydrated;
// those tracks remain present with metadata_complete:NO and metadata_error.
dispatch_block_t SAPFetchOfflineLibrary(void (^progress)(NSUInteger completed, NSUInteger total),
    void (^completion)(NSArray<NSDictionary *> *tracks, NSString *error));

// Main-queue, process-lifetime display snapshot. nil means no completed scan;
// an empty array is a successfully verified empty library. Never proves current
// membership: SAPFetchOfflineLibrary still validates native contexts/items.
NSArray<NSDictionary *> *SAPOfflineLibraryCachedTracks(void);
// Publish verified local deletion results; nil clears the display cache.
// Invalidates cache writes from scans started before this update.
void SAPUpdateOfflineLibraryCachedTracks(NSArray<NSDictionary *> *tracks);

#ifdef SAP_TESTING
// Fixtures only: without a directory nothing is persisted. Reset forgets the
// in-memory snapshot so the next access reloads from disk like a fresh launch.
void SAPOfflineLibraryStoreResetForTesting(NSString *directory);
void SAPOfflineLibraryStoreFlushForTesting(void);
#endif
