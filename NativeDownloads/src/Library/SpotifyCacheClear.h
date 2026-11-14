#pragma once
#import <Foundation/Foundation.h>

// Spotify's own "Clear cache" (Settings > Storage): one Storage.DeleteUnlockedItems
// request with the empty DeleteUnlockedItemsParams, exactly the call Spotify sends
// from its Settings button (observed in a device trace). Spotify keeps every locked
// item, i.e. current downloads, and drops only unlocked cache files such as tracks
// whose download was just removed. This is NOT "Remove downloads": no Offline
// RemoveAllDownloads, no per-file DeleteItem and no direct filesystem access.
//
// Callback is delivered on the main queue, once. result keys when sizes were readable:
// size_before, size_after, locked_before, locked_after, freed_bytes (all NSNumber).
// error is nil on success. A second call while one is running fails immediately.
void SAPClearSpotifyCache(void (^completion)(NSDictionary *result,NSString *error));
