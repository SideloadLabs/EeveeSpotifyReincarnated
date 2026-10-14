// EVPlayback.h - control Spotify's own playback controller (no UI buttons, no Frida).
// All calls are safe from any thread: they run on the main thread. Return value = "was dispatched".
#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL EeveePlaybackAvailable(void);        // controller captured?
BOOL EeveePlaybackPlay(void);
BOOL EeveePlaybackPause(void);
BOOL EeveePlaybackTogglePause(void);
BOOL EeveePlaybackNext(void);
BOOL EeveePlaybackPrevious(void);
BOOL EeveePlaybackToggleShuffle(void);
BOOL EeveePlaybackToggleRepeat(void);     // cycles Spotify's repeat modes
NSString *EeveePlaybackStatus(void);      // "paused=0 shuffling=1 repeatMode=2 | captured via init"

#ifdef __cplusplus
}
#endif
