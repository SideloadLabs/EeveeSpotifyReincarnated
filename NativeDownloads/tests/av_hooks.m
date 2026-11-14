#include "Diagnostics.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "AudioProbe.h"
#include <assert.h>

static float expected = 0.5f;
static unsigned sinkCalls, completions;
static CMSampleBufferRef lastOriginal;
static AVAudioPCMBuffer *originalPlayer;
static AVAudioTime *expectedTime;
static BOOL reenterAndThrow, insideEnqueueException;
static unsigned enqueueExceptionCalls;
static void verify(const AudioBufferList *data, UInt32 frames) {
    for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
        const float *samples = data->mBuffers[b].mData;
        for (UInt32 i = 0; i < frames * data->mBuffers[b].mNumberChannels; ++i) { if (samples[i] != expected) fprintf(stderr,"sink=%u b=%u i=%u actual=%f expected=%f\n",sinkCalls,b,i,samples[i],expected); assert(samples[i] == expected); }
    }
}
static void sampleSink(id self, SEL cmd, CMSampleBufferRef sample) {
    if (reenterAndThrow) {
        enqueueExceptionCalls++;
        if (insideEnqueueException) {
            reenterAndThrow = NO;
            @throw [NSException exceptionWithName:@"NestedEnqueueOriginal" reason:nil userInfo:nil];
        }
        insideEnqueueException = YES;
        @try { [self enqueueSampleBuffer:sample]; }
        @finally { insideEnqueueException = NO; }
        return;
    }
    const AudioStreamBasicDescription *fmt = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
    if (fmt->mFormatID != kAudioFormatLinearPCM) { assert(sample == lastOriginal); sinkCalls++; return; }
    struct { UInt32 count; AudioBuffer buffers[32]; } data;
    CMBlockBufferRef retained = NULL;
    size_t needed = 0; OSStatus q = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &needed, NULL, 0, NULL, NULL, 0, NULL); assert(!q && needed <= sizeof(data));
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, NULL, (AudioBufferList *)&data,
        needed, kCFAllocatorDefault, kCFAllocatorDefault, 0, &retained);
    if (status) fprintf(stderr, "sink status=%d calls=%u expected=%f size=%zu samples=%ld\n", status, sinkCalls, expected, CMSampleBufferGetTotalSampleSize(sample), CMSampleBufferGetNumSamples(sample));
    assert(!status);
    verify((AudioBufferList *)&data, (UInt32)CMSampleBufferGetNumSamples(sample));
    assert(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(7, 1)) == 0);
    if (expected == 0.5f) assert(sample == lastOriginal);
    else assert(sample != lastOriginal);
    assert([(__bridge id)CMGetAttachment(sample, CFSTR("probe-test"), NULL) isEqual:@"preserved"]);
    CFRelease(retained); sinkCalls++;
}
static void playerSink(id self, SEL cmd, AVAudioPCMBuffer *buffer, AVAudioTime *when, AVAudioPlayerNodeBufferOptions options,
                       AVAudioPlayerNodeCompletionCallbackType type, AVAudioPlayerNodeCompletionHandler completion) {
    assert(when == expectedTime && options == AVAudioPlayerNodeBufferInterrupts && type == AVAudioPlayerNodeCompletionDataConsumed);
    verify(buffer.audioBufferList, buffer.frameLength);
    assert(expected == 0.5f ? buffer == originalPlayer : buffer != originalPlayer);
    sinkCalls++; if (completion) completion(type);
}
// Simulate the real framework's convenience method forwarding to the long form:
// nested swizzles must not apply processing twice.
static void playerShortSink(AVAudioPlayerNode *self, SEL cmd, AVAudioPCMBuffer *buffer, AVAudioNodeCompletionHandler completion) {
    [self scheduleBuffer:buffer atTime:expectedTime options:AVAudioPlayerNodeBufferInterrupts
        completionCallbackType:AVAudioPlayerNodeCompletionDataConsumed completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
            if (completion) completion();
        }];
}
static void scale(const AudioStreamBasicDescription *format, AudioBufferList *data, UInt32 frames) {
    for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
        float *samples = data->mBuffers[b].mData;
        for (UInt32 i = 0; i < data->mBuffers[b].mDataByteSize / 4; ++i) samples[i] *= 0.5f;
    }
}
static AVAudioPCMBuffer *pcm(BOOL interleaved) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000 channels:2 interleaved:interleaved];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:127];
    buffer.frameLength = 127;
    AudioBufferList *list = buffer.mutableAudioBufferList;
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        float *samples = list->mBuffers[b].mData;
        for (UInt32 i = 0; i < list->mBuffers[b].mDataByteSize / 4; ++i) samples[i] = 0.5f;
    }
    return buffer;
}
static CMSampleBufferRef sample(AVAudioPCMBuffer *pcm) {
    CMAudioFormatDescriptionRef format;
    assert(!CMAudioFormatDescriptionCreate(kCFAllocatorDefault, pcm.format.streamDescription, 0, NULL, 0, NULL, NULL, &format));
    CMSampleTimingInfo time = {CMTimeMake(1, 48000), CMTimeMake(7, 1), kCMTimeInvalid};
    size_t size = pcm.format.streamDescription->mBytesPerFrame * (pcm.format.isInterleaved ? 1 : pcm.format.channelCount);
    CMSampleBufferRef result;
    assert(!CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL, format, pcm.frameLength, 1, &time, 1, &size, &result));
    assert(!CMSampleBufferSetDataBufferFromAudioBufferList(result, kCFAllocatorDefault, kCFAllocatorDefault, 0, pcm.audioBufferList));
    assert(!CMSampleBufferSetDataReady(result));
    CMSetAttachment(result, CFSTR("probe-test"), CFSTR("preserved"), kCMAttachmentMode_ShouldPropagate);
    CFRelease(format); return result;
}
int main(void) { @autoreleasepool {
    SAPDiagnosticsSetEnabled(true);

    method_setImplementation(class_getInstanceMethod(AVSampleBufferAudioRenderer.class, @selector(enqueueSampleBuffer:)), (IMP)sampleSink);
    method_setImplementation(class_getInstanceMethod(AVAudioPlayerNode.class, @selector(scheduleBuffer:atTime:options:completionCallbackType:completionHandler:)), (IMP)playerSink);
    method_setImplementation(class_getInstanceMethod(AVAudioPlayerNode.class, @selector(scheduleBuffer:completionHandler:)), (IMP)playerShortSink);
    SpotifyAudioProbeInitialize(); SAPInstallAVHooks(); SAPInstallAVHooks();
    AVSampleBufferAudioRenderer *renderer = [AVSampleBufferAudioRenderer new];
    for (unsigned layout = 0; layout < 2; ++layout) {
        AVAudioPCMBuffer *buffer = pcm(layout);
        CMSampleBufferRef input = sample(buffer); lastOriginal = input;
        expected = 0.5f; [renderer enqueueSampleBuffer:input];
        SpotifyAudioProbeSetObserver(scale); expected = 0.25f;
        [renderer enqueueSampleBuffer:input];
        SpotifyAudioProbeSetObserver(NULL); expected = 0.5f;
        [renderer enqueueSampleBuffer:input]; // observer copy left the original unchanged
        CFRelease(input);
    }
    AVAudioPlayerNode *player = [AVAudioPlayerNode new]; originalPlayer = pcm(NO);
    expectedTime = [AVAudioTime timeWithSampleTime:512 atRate:48000];
    expected = 0.5f; [player scheduleBuffer:originalPlayer completionHandler:^{ completions++; }];
    SpotifyAudioProbeSetObserver(scale); expected = 0.25f;
    [player scheduleBuffer:originalPlayer completionHandler:^{ completions++; }];
    SpotifyAudioProbeSetObserver(NULL); expected = 0.5f; verify(originalPlayer.audioBufferList, originalPlayer.frameLength);
    AudioStreamBasicDescription compressed = {48000, kAudioFormatMPEG4AAC, 0, 0, 1024, 0, 2, 0, 0};
    CMAudioFormatDescriptionRef compressedFormat;
    assert(!CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &compressed, 0, NULL, 0, NULL, NULL, &compressedFormat));
    CMBlockBufferRef encoded;
    assert(!CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, 16, kCFAllocatorDefault, NULL, 0, 16, 0, &encoded));
    AudioStreamPacketDescription packet = {0, 1024, 16}; CMSampleBufferRef encodedSample;
    assert(!CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, encoded, compressedFormat, 1,
        CMTimeMake(7, 1), &packet, &encodedSample));
    lastOriginal = encodedSample; SpotifyAudioProbeSetObserver(scale);
    [renderer enqueueSampleBuffer:encodedSample];
    SpotifyAudioProbeSetObserver(NULL);
    CFRelease(encodedSample); CFRelease(encoded); CFRelease(compressedFormat);
    SAPSnapshot s; SpotifyAudioProbeReadSnapshot(&s);
    assert(s.objcHooks == 5 && s.sampleBufferCalls == 7 && s.playerBufferCalls == 2 && s.callbacks == 8);
    assert(sinkCalls == 9 && s.compressedBuffers == 1 && completions == 2 && s.extractionErrors == 0);
    // A chained original may reenter and throw. Catching that exception must
    // leave subsequent calls on this thread eligible for Pixie processing.
    AVAudioPCMBuffer *recoveryPCM = pcm(NO);
    CMSampleBufferRef recoverySample = sample(recoveryPCM);
    lastOriginal = recoverySample; expected = 0.5f;
    uint64_t callsBeforeException = s.sampleBufferCalls;
    reenterAndThrow = YES;
    BOOL exceptionObserved = NO;
    @try { [renderer enqueueSampleBuffer:recoverySample]; }
    @catch (NSException *exception) { exceptionObserved = [exception.name isEqual:@"NestedEnqueueOriginal"]; }
    assert(exceptionObserved && enqueueExceptionCalls == 2);
    [renderer enqueueSampleBuffer:recoverySample];
    SpotifyAudioProbeReadSnapshot(&s);
    assert(s.sampleBufferCalls == callsBeforeException + 2 && sinkCalls == 10);
    CFRelease(recoverySample);
    puts("PASS: nested original enqueue exception propagates; later buffers still reach Pixie processing");
    printf("PASS: actual Objective-C method interception; CoreMedia interleaved/planar PCM; passthrough identity; independent mutable copies; unchanged originals; metadata/timing; nested scheduling and completions. AV hooks=%u calls=%llu/%llu\n", s.objcHooks, s.sampleBufferCalls, s.playerBufferCalls);
} }
