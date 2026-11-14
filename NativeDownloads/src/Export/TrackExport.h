#pragma once
#import <Foundation/Foundation.h>
#import "ExportRegisterFrame.h"
// Observe the native 16-byte unsealing result, with exact caller/file guards.
// Process cache plus device-only Keychain; full audio validation still decides validity.
void SAPExportObserveUnsealedMediaKey(const SAPExportRegisterFrame *frame, uintptr_t spotifyImage);
// Called only at the UUID-guarded original offline-success boundary.
void SAPExportObserveOfflineSuccess(const uint64_t *registers, uintptr_t spotifyImage);
void SAPExportObserveStreamSuccess(const uint64_t *registers, uintptr_t spotifyImage);
// Called at the guarded native cached-key setter entry. Copies the opaque
// 28-byte media-key record into bounded process memory; never calls native code.
void SAPExportObserveMediaKeyBlob(const uint64_t *registers, uintptr_t spotifyImage);
void SAPExportCurrentAudio(BOOL album, void (^completion)(NSArray<NSURL *> *files, NSString *error));
void SAPExportCurrentAudioWithProgress(BOOL album,void (^progress)(NSString *),
                                       void (^completion)(NSArray<NSURL *> *,NSString *));
// Called only after an actual cache export failed and matching keys are absent.
// Approval allows one native remove/download attempt; a new key is not guaranteed.
void SAPExportCurrentAudioWithKeyRefresh(BOOL album,void (^progress)(NSString *),
                                         void (^confirmRefresh)(NSUInteger,void (^)(BOOL)),
                                         void (^completion)(NSArray<NSURL *> *,NSString *));
void SAPCancelAudioExport(void);
NSDictionary *SAPTrackExportReport(void);

NSString *SAPAudioExportFormat(void);
void SAPExportAudioURI(NSString *uri,void (^progress)(NSString *),void (^completion)(NSArray<NSURL *> *,NSString *));
void SAPClearAudioExports(void (^completion)(BOOL,NSString *));

// Manager pipeline: prefer reusable files in format; otherwise return tagged Ogg
// for independent M4A conversion. Does not change the saved format preference.
void SAPExportAudioURIForBatch(NSString *uri,NSString *format,void (^progress)(NSString *),void (^completion)(NSArray<NSURL *> *,NSString *));
