// repoints Spotify's own import slot for a C function (fishhook's technique, limited to Spotify's binary), so
// only Spotify's calls reach the replacement. call from the tweak's init: slots are written without a lock.
#import <Foundation/Foundation.h>

// YES when a slot for `symbol` (no leading underscore) was repointed; `original` gets what the first held.
BOOL EeveeRebindImport(const char *symbol, void *replacement, void **original);

// where the import page can't be written (Dopamine, iOS 17.5.1): hooks the function itself with the jailbreak's
// MSHookFunction. every caller then comes through, so `replacement` hands non-Spotify callers to `original`,
// which must be NULL before. NO without a jailbreak.
BOOL EeveeHookFunctionInline(void *function, void *replacement, void **original);

// whether a hooked function's __builtin_return_address(0) is in Spotify's binary.
BOOL EeveeCalledFromSpotify(void *returnAddress);
