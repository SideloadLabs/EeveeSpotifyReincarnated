// EVRecorderInternal.h - shared between AudioRecorder.m, RecorderSupport.m and RecorderButton.m
#pragma once
#import <Foundation/Foundation.h>
#import <stdint.h>
#import "include/EVRecorder.h"

typedef NS_ENUM(int, EVLogLevel) { EVLogError = 0, EVLogWarn = 1, EVLogInfo = 2, EVLogDebug = 3, EVLogTrace = 4 };

#ifdef __cplusplus
extern "C" {
#endif

// ---- logging (never call from the realtime audio thread) ----
void EVLogf(EVLogLevel level, const char *tag, NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);
void EVLogFlush(void);
void EVLogClear(void);
void EVLogSetAppState(int state);                 // 0 active, 1 inactive, 2 background
NSArray<NSString *> *EVLogTail(NSUInteger count);
NSString *EVLogPath(void);

// ---- settings (NSUserDefaults, prefix "EVRec.") ----
BOOL EVSettingBool(NSString *key, BOOL fallback);
void EVSetSettingBool(NSString *key, BOOL value);
NSInteger EVSettingInt(NSString *key, NSInteger fallback);
void EVSetSettingInt(NSString *key, NSInteger value);
NSString *EVSettingString(NSString *key, NSString *fallback);
void EVSetSettingString(NSString *key, NSString *value);

NSURL *EVRecordingsRoot(void);
NSString *EVFormatTime(double seconds);           // m:ss.mmm

// ---- implemented in AudioRecorder.m ----
uint64_t EVCoreFramesCaptured(void);
uint32_t EVCoreSampleRate(void);
NSArray<NSString *> *EVCoreDebugLines(void);
NSString *EVCoreActiveSessionPath(void);

#ifdef __cplusplus
}
#endif

#define EVE(tag, ...) EVLogf(EVLogError, tag, __VA_ARGS__)
#define EVW(tag, ...) EVLogf(EVLogWarn, tag, __VA_ARGS__)
#define EVI(tag, ...) EVLogf(EVLogInfo, tag, __VA_ARGS__)
#define EVD(tag, ...) EVLogf(EVLogDebug, tag, __VA_ARGS__)

// ---- track metadata ----
@interface EVTrackInfo : NSObject
@property (nonatomic, copy) NSString *key, *title, *artist, *album, *albumArtist, *genre, *uri, *isrc;
@property (nonatomic) NSInteger trackNumber, trackCount, discNumber, year;
@property (nonatomic) double duration, elapsed;
@property (nonatomic, strong) id artworkObject;      // MPMediaItemArtwork
@property (nonatomic, strong) NSData *artworkJPEG;
- (NSDictionary *)dictionary;
+ (instancetype)fromDictionary:(NSDictionary *)d;
@end

@interface EVMarker : NSObject
@property (nonatomic) uint64_t frame;
@property (nonatomic, strong) EVTrackInfo *info;
@property (nonatomic) BOOL partialStart;
@end

// ---- implemented in RecorderSupport.m ----
typedef void (^EVTrackChangeBlock)(EVTrackInfo *info, uint64_t frame, BOOL partialStart);
void EVMetaStart(EVTrackChangeBlock block);
void EVMetaStop(void);
NSArray<NSString *> *EVMetaDebugLines(void);

typedef void (^EVFinalizeDone)(NSArray<NSURL *> *files, NSURL *folder, NSArray<NSDictionary *> *tracks, NSString *errorText);
void EVFinalizeSession(NSURL *sessionWav, uint32_t rate, NSArray<EVMarker *> *markers, uint64_t totalFrames, EVFinalizeDone done);
void EVExportFolder(NSURL *folder, NSString *format, EVFinalizeDone done);   // format: "aac", "alac", or "aiff"
void EVResumePendingSessions(void);
