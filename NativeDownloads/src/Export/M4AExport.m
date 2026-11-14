#import "M4AExport.h"
#import "OggExport.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include <alloca.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#define STB_VORBIS_STATIC
#define STB_VORBIS_NO_PUSHDATA_API
#define STB_VORBIS_NO_INTEGER_CONVERSION
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-compare"
#pragma clang diagnostic ignored "-Wunused-function"
#include "../../vendor/stb_vorbis.c"
#pragma clang diagnostic pop

#define SAP_PCM_FRAMES 4096
#define SAP_MAX_COVER_BYTES (8 * 1024 * 1024)
#define SAP_DECODER_ARENA_BYTES (4 * 1024 * 1024)

static int SAPM4ACancelled(SAPM4AExportCancellation callback, void *context) {
    return callback && callback(context);
}
typedef struct {SAPM4AExportCancellation cancelled;void *context;} SAPM4AValidationContext;
static int SAPM4AValidationContinue(void *value) {
    SAPM4AValidationContext *validation=value;
    return !SAPM4ACancelled(validation->cancelled,validation->context);
}
static void SAPM4AAddTag(NSMutableArray *items, NSString *key, id value, NSString *dataType) {
    if (!value) return;
    AVMutableMetadataItem *item = AVMutableMetadataItem.new;
    item.keySpace = AVMetadataKeySpaceiTunes;
    item.key = key;
    item.value = value;
    item.dataType = dataType;
    [items addObject:item];
}
static NSArray *SAPM4ATags(const SAPM4AExportMetadata *metadata) {
    NSMutableArray *items = NSMutableArray.array;
    if (!metadata) return items;
    SAPM4AAddTag(items, AVMetadataiTunesMetadataKeySongName,
        metadata->title ? @(metadata->title) : nil, (__bridge NSString *)kCMMetadataBaseDataType_UTF8);
    SAPM4AAddTag(items, AVMetadataiTunesMetadataKeyArtist,
        metadata->artist ? @(metadata->artist) : nil, (__bridge NSString *)kCMMetadataBaseDataType_UTF8);
    SAPM4AAddTag(items, AVMetadataiTunesMetadataKeyAlbum,
        metadata->album ? @(metadata->album) : nil, (__bridge NSString *)kCMMetadataBaseDataType_UTF8);
    SAPM4AAddTag(items, AVMetadataiTunesMetadataKeyReleaseDate,
        metadata->year ? @(metadata->year) : nil, (__bridge NSString *)kCMMetadataBaseDataType_UTF8);
    if (metadata->track && *metadata->track) {
        unsigned int number = 0, total = 0;
        if (sscanf(metadata->track, "%u/%u", &number, &total) >= 1 && number <= UINT16_MAX && total <= UINT16_MAX) {
            uint8_t track[8] = {0, 0, (uint8_t)(number >> 8), (uint8_t)number,
                (uint8_t)(total >> 8), (uint8_t)total, 0, 0};
            SAPM4AAddTag(items, AVMetadataiTunesMetadataKeyTrackNumber,
                [NSData dataWithBytes:track length:sizeof track], (__bridge NSString *)kCMMetadataBaseDataType_RawData);
        }
    }
    if (metadata->jpeg_cover_length) SAPM4AAddTag(items, AVMetadataiTunesMetadataKeyCoverArt,
        [NSData dataWithBytes:metadata->jpeg_cover length:metadata->jpeg_cover_length],
        (__bridge NSString *)kCMMetadataBaseDataType_JPEG);
    return items;
}
// Probe the actual native AAC-LC encoder: bitrate limits vary with mono and rate.
static NSDictionary *SAPM4ASettings(unsigned int inputRate, int channels) {
    AudioStreamBasicDescription aac = {0};
    aac.mFormatID = kAudioFormatMPEG4AAC;
    aac.mFormatFlags = kMPEG4Object_AAC_LC;
    aac.mChannelsPerFrame = (UInt32)channels;
    UInt32 size = 0;
    unsigned int outputRate = 44100;
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_AvailableEncodeSampleRates,
        sizeof aac, &aac, &size) == noErr && size && size <= 4096) {
        AudioValueRange ranges[4096 / sizeof(AudioValueRange)];
        if (AudioFormatGetProperty(kAudioFormatProperty_AvailableEncodeSampleRates,
            sizeof aac, &aac, &size, ranges) == noErr) {
            for (UInt32 i = 0; i < size / sizeof(AudioValueRange); ++i) {
                if (inputRate >= ranges[i].mMinimum && inputRate <= ranges[i].mMaximum) {
                    outputRate = inputRate; break;
                }
            }
        }
    }
    aac.mSampleRate = outputRate;
    UInt32 bitrate = 0;
    size = 0;
    AudioStreamBasicDescription pcm = {0};
    pcm.mSampleRate = inputRate;
    pcm.mFormatID = kAudioFormatLinearPCM;
    pcm.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    pcm.mBytesPerPacket = pcm.mBytesPerFrame = channels * sizeof(float);
    pcm.mFramesPerPacket = 1;
    pcm.mChannelsPerFrame = channels;
    pcm.mBitsPerChannel = 32;
    AudioConverterRef converter = NULL;
    if (AudioConverterNew(&pcm, &aac, &converter) != noErr) return nil;
    // The format-wide bitrate list includes unsupported combinations (for
    // example 320k mono at 22050 Hz). Query this concrete encoder instead.
    if (AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates,
        &size, NULL) == noErr && size && size <= 4096) {
        AudioValueRange ranges[4096 / sizeof(AudioValueRange)];
        if (AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates,
            &size, ranges) == noErr) {
            for (UInt32 i = 0; i < size / sizeof(AudioValueRange); ++i) {
                double candidate = MIN(320000., ranges[i].mMaximum);
                if (candidate >= ranges[i].mMinimum && candidate > bitrate) bitrate = (UInt32)candidate;
            }
        }
    }
    AudioConverterDispose(converter);
    // Unsupported settings must fail explicitly rather than silently changing codec.
    if (!bitrate) return nil;
    return @{AVFormatIDKey:@(kAudioFormatMPEG4AAC), AVSampleRateKey:@(outputRate),
        AVNumberOfChannelsKey:@(channels), AVEncoderBitRateKey:@(bitrate),
        AVEncoderBitRateStrategyKey:AVAudioBitRateStrategy_Constant,
        AVEncoderAudioQualityKey:@(AVAudioQualityMax)};
}
static CMSampleBufferRef SAPM4APCMSample(float *const *pcm, int channels, int count,
    uint64_t position, unsigned int rate, CMAudioFormatDescriptionRef format) {
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    size_t bytes = (size_t)count * channels * sizeof(float);
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, bytes,
        kCFAllocatorDefault, NULL, 0, bytes, kCMBlockBufferAssureMemoryNowFlag, &block) != noErr) return NULL;
    char *storage = NULL;
    if (CMBlockBufferGetDataPointer(block, 0, NULL, NULL, &storage) == noErr) {
        float *interleaved = (float *)storage;
        for (int frame = 0; frame < count; ++frame)
            for (int channel = 0; channel < channels; ++channel)
                interleaved[frame * channels + channel] = pcm[channel][frame];
        CMSampleTimingInfo timing = {CMTimeMake(1, rate), CMTimeMake((int64_t)position, rate), kCMTimeInvalid};
        size_t frameBytes = channels * sizeof(float);
        if (CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, count,
            1, &timing, 1, &frameBytes, &sample) != noErr) sample = NULL;
    }
    CFRelease(block);
    return sample;
}
static SAPM4AExportStatus SAPM4AWrite(stb_vorbis *decoder, stb_vorbis_info info,
    unsigned int expected, NSURL *temporaryURL, const SAPM4AExportMetadata *metadata,
    SAPM4AExportCancellation cancelled, SAPM4AExportProgress progress, void *context) {
    NSDictionary *settings = SAPM4ASettings(info.sample_rate, info.channels);
    if (!settings) return SAPM4AExportEncodeFailed;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:temporaryURL fileType:AVFileTypeAppleM4A error:nil];
    if (!writer) return SAPM4AExportWriteFailed;
    CMAudioFormatDescriptionRef format = NULL;
    @try {
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings];
        input.expectsMediaDataInRealTime = NO;
        if (![writer canAddInput:input]) return SAPM4AExportEncodeFailed;
        [writer addInput:input];
        writer.metadata = SAPM4ATags(metadata);
        AudioStreamBasicDescription pcmFormat = {0};
        pcmFormat.mSampleRate = info.sample_rate;
        pcmFormat.mFormatID = kAudioFormatLinearPCM;
        pcmFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        pcmFormat.mBytesPerPacket = pcmFormat.mBytesPerFrame = info.channels * sizeof(float);
        pcmFormat.mFramesPerPacket = 1;
        pcmFormat.mChannelsPerFrame = info.channels;
        pcmFormat.mBitsPerChannel = 32;
        if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &pcmFormat, 0, NULL,
            0, NULL, NULL, &format) != noErr) return SAPM4AExportEncodeFailed;
        if (![writer startWriting]) return SAPM4AExportEncodeFailed;
        [writer startSessionAtSourceTime:kCMTimeZero];
        float left[SAP_PCM_FRAMES], right[SAP_PCM_FRAMES];
        float *pcm[2] = {left, right};
        uint64_t samples = 0;
        if (progress) progress(0., context);
        for (;;) { @autoreleasepool {
            if (SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
            int count = stb_vorbis_get_samples_float(decoder, info.channels, pcm, SAP_PCM_FRAMES);
            if (stb_vorbis_get_error(decoder)) return SAPM4AExportDecodeFailed;
            if (!count) break;
            if (samples + count > expected) return SAPM4AExportDecodeFailed;
            // Backpressure prevents queueing the whole decoded recording in memory.
            while (!input.readyForMoreMediaData) {
                if (SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
                if (writer.status != AVAssetWriterStatusWriting) return SAPM4AExportEncodeFailed;
                [NSThread sleepForTimeInterval:.001];
            }
            CMSampleBufferRef sample = SAPM4APCMSample(pcm, info.channels, count, samples, info.sample_rate, format);
            if (!sample) return SAPM4AExportEncodeFailed;
            BOOL appended = [input appendSampleBuffer:sample];
            CFRelease(sample);
            if (!appended) return SAPM4AExportEncodeFailed;
            samples += count;
            if (progress) progress(.99 * (double)samples / expected, context);
        }}
        if (samples != expected) return SAPM4AExportDecodeFailed;
        if (SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
        [input markAsFinished];
        [writer endSessionAtSourceTime:CMTimeMake((int64_t)samples, info.sample_rate)];
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(finished);}];
        BOOL wasCancelled = NO;
        while (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC))) {
            if (SAPM4ACancelled(cancelled, context) && !wasCancelled) {
                wasCancelled = YES;
                [writer cancelWriting];
            }
        }
        if (wasCancelled || SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
        return writer.status == AVAssetWriterStatusCompleted ? SAPM4AExportOK : SAPM4AExportEncodeFailed;
    } @catch (NSException *exception) {
        return SAPM4AExportEncodeFailed;
    } @finally {
        if (format) CFRelease(format);
        if (writer.status != AVAssetWriterStatusCompleted && writer.status != AVAssetWriterStatusCancelled)
            [writer cancelWriting];
    }
}
SAPM4AExportStatus SAPExportOggToM4A(const char *input_path, const char *output_path,
    const SAPM4AExportMetadata *metadata, SAPM4AExportCancellation cancelled,
    SAPM4AExportProgress progress, void *context) { @autoreleasepool {
    if (!input_path || !output_path || !*input_path || !*output_path ||
        (metadata && (metadata->jpeg_cover_length > SAP_MAX_COVER_BYTES ||
        (metadata->jpeg_cover_length && !metadata->jpeg_cover)))) return SAPM4AExportInvalidArguments;
    if (SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
    struct stat existing;
    if (!lstat(output_path, &existing)) return SAPM4AExportOutputExists;
    if (errno != ENOENT) return SAPM4AExportWriteFailed;
    FILE *input = fopen(input_path, "rb");
    if (!input) return SAPM4AExportInvalidInput;
    char *arenaMemory = NULL;
    stb_vorbis *decoder = NULL;
    NSString *temporaryDirectory = nil;
    SAPM4AExportStatus status = SAPM4AExportInvalidInput;
    @try {
        uint64_t offset = 0, length = 0;
        SAPM4AValidationContext validation={cancelled,context};
        if (!SAPValidateOggExportDetailedCancellable(input,0,&offset,&length,NULL,SAPM4AValidationContinue,&validation))
            return SAPM4ACancelled(cancelled,context)?SAPM4AExportCancelled:status;
        if (length > UINT_MAX ||
            offset > LONG_MAX || fseek(input, (long)offset, SEEK_SET)) return status;
        if (SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
        arenaMemory = malloc(SAP_DECODER_ARENA_BYTES);
        if (!arenaMemory) return status;
        stb_vorbis_alloc arena = {arenaMemory, SAP_DECODER_ARENA_BYTES};
        int decoderError = 0;
        decoder = stb_vorbis_open_file_section(input, 0, &decoderError, &arena, (unsigned int)length);
        if (!decoder) return status;
        stb_vorbis_info info = stb_vorbis_get_info(decoder);
        if (info.channels < 1 || info.channels > 2 || !info.sample_rate || info.sample_rate > INT_MAX) return status;
        unsigned int expected = stb_vorbis_stream_length_in_samples(decoder);
        if (!expected || expected == UINT_MAX || stb_vorbis_get_error(decoder)) return status;
        NSString *outputPath = [NSFileManager.defaultManager stringWithFileSystemRepresentation:output_path length:strlen(output_path)];
        // Private same-filesystem directory prevents temporary-name replacement.
        NSString *pattern = [outputPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".sap-m4a-XXXXXX"];
        char *directoryTemplate = strdup(pattern.fileSystemRepresentation);
        if (!directoryTemplate) return SAPM4AExportWriteFailed;
        char *created = mkdtemp(directoryTemplate);
        if (created) temporaryDirectory = [NSFileManager.defaultManager stringWithFileSystemRepresentation:created length:strlen(created)];
        free(directoryTemplate);
        if (!temporaryDirectory) return SAPM4AExportWriteFailed;
        NSURL *temporaryURL = [NSURL fileURLWithPath:[temporaryDirectory stringByAppendingPathComponent:@"audio.m4a"]];
        status = SAPM4AWrite(decoder, info, expected, temporaryURL, metadata, cancelled, progress, context);
        if (status != SAPM4AExportOK) return status;
        if (SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
        int descriptor = open(temporaryURL.path.fileSystemRepresentation, O_RDONLY);
        if (descriptor < 0) return SAPM4AExportWriteFailed;
        int syncResult = fsync(descriptor);
        close(descriptor);
        if (syncResult) return SAPM4AExportWriteFailed;
        if (SAPM4ACancelled(cancelled, context)) return SAPM4AExportCancelled;
        // link() is an atomic no-replace publication, including concurrent exports.
        if (link(temporaryURL.path.fileSystemRepresentation, output_path))
            return errno == EEXIST ? SAPM4AExportOutputExists : SAPM4AExportWriteFailed;
        if (progress) progress(1., context);
        return SAPM4AExportOK;
    } @finally {
        if (decoder) stb_vorbis_close(decoder);
        free(arenaMemory);
        fclose(input);
        if (temporaryDirectory) [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
    }
}}
