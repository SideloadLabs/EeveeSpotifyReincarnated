// EVRecorder.h - public API of the Eevee audio recorder.
// Import this from include/Tweak.h so Swift can call it.
#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Posted on the main thread when recording starts, stops or fails.
extern NSString *const EeveeRecorderStateDidChangeNotification;
// Posted on the main thread when the per-track files are written.
// userInfo: files (NSArray<NSURL*>), folder (NSURL), tracks (NSArray<NSDictionary*>), error (NSString, optional)
extern NSString *const EeveeRecorderDidFinishNotification;

// Existing API (unchanged signatures)
BOOL EeveeAudioRecorderStart(void);
void EeveeAudioRecorderStop(void);
BOOL EeveeAudioRecorderIsRecording(void);
NSString *EeveeAudioRecorderCurrentPath(void);

// New API
NSString *EeveeAudioRecorderLastError(void);          // why the last Start failed, nil if none
NSString *EeveeRecorderStatusLine(void);              // short text for a settings row
void EeveeRecorderSetExtraMetadata(NSDictionary *md); // title, artist, album, albumArtist, genre, trackNumber, discNumber, year, uri, isrc
NSString *EeveeRecorderDebugReport(void);             // main thread only
void EeveeRecorderPresentDebugPanel(void);            // main thread only

#ifdef __cplusplus
}
#endif
