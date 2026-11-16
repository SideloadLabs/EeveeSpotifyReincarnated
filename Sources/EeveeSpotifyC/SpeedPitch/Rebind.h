// hooks a C function Spotify's binary imports by repointing the binary's own import slot for it (__got, or
// __la_symbol_ptr in older builds): fishhook's technique, limited to Spotify's binary. only Spotify's own
// calls reach the replacement; the system frameworks keep calling the original. for the few places where no
// Objective-C method sits between Spotify and a system call.
//
// Spotify's binary is the image named Spotify (or named as the bundle's executable): the main executable,
// or a dylib under LiveContainer. call from the tweak's init, before Spotify runs: slots are written without
// a lock.
#import <Foundation/Foundation.h>

// YES when at least one slot for `symbol` (without the leading underscore) was repointed. `original` gets
// what the first slot held, for the replacement to call.
BOOL EeveeRebindImport(const char *symbol, void *replacement, void **original);

// for jailbreaks where Spotify's import page can't be written (seen on Dopamine, iOS 17.5.1): hooks the
// function itself with the jailbreak's MSHookFunction (ElleKit or Substrate). every caller then goes through
// `replacement`, so it must check EeveeCalledFromSpotify and hand other callers to `original`, which must be
// NULL before the call. NO unless EeveeJailbroken().
BOOL EeveeHookFunctionInline(void *function, void *replacement, void **original);

// whether MSHookFunction comes from a jailbreak, not from a substrate bundled inside the IPA.
BOOL EeveeJailbroken(void);

// whether `returnAddress` (a hooked function's __builtin_return_address(0)) is in Spotify's binary.
BOOL EeveeCalledFromSpotify(void *returnAddress);
