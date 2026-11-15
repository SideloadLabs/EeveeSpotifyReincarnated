#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "AudioProbe.h"

// These hooks run when the app schedules audio. They do not install a timer,
// traverse view trees, or swizzle generic NSObject/UIView methods.
static IMP enqueueOriginal, scheduleOriginal[4];
static _Thread_local unsigned enqueueDepth, scheduleDepth;

static CMSampleBufferRef copySample(CMSampleBufferRef source) CF_RETURNS_RETAINED {
    CMBlockBufferRef data = CMSampleBufferGetDataBuffer(source), copied = NULL;
    if (!data || CMBlockBufferCreateContiguous(kCFAllocatorDefault, data, kCFAllocatorDefault,
            NULL, 0, 0, kCMBlockBufferAlwaysCopyDataFlag, &copied)) return NULL;
    CMItemCount timingCount = 0, sizeCount = 0;
    CMSampleBufferRef result = NULL;
    CMSampleTimingInfo *timing = NULL;
    size_t *sizes = NULL;
    OSStatus timeStatus = CMSampleBufferGetSampleTimingInfoArray(source, 0, NULL, &timingCount);
    OSStatus sizeStatus = CMSampleBufferGetSampleSizeArray(source, 0, NULL, &sizeCount);
    if (sizeStatus == kCMSampleBufferError_BufferHasNoSampleSizes) { sizeCount = 0; sizeStatus = noErr; }
    if (timeStatus == kCMSampleBufferError_BufferHasNoSampleTimingInfo) { timingCount = 0; timeStatus = noErr; }
    if (timeStatus || sizeStatus) goto done;
    // Malformed or enormous lists fall back to unmodified playback.
    if (timingCount < 0 || sizeCount < 0 || timingCount > 1048576 || sizeCount > 1048576) goto done;
    timing = calloc(MAX(timingCount, 1), sizeof(*timing));
    sizes = calloc(MAX(sizeCount, 1), sizeof(*sizes));
    if (!timing || !sizes) goto done;
    if ((timingCount && CMSampleBufferGetSampleTimingInfoArray(source, timingCount, timing, &timingCount))
        || (sizeCount && CMSampleBufferGetSampleSizeArray(source, sizeCount, sizes, &sizeCount))) goto done;
    if (CMSampleBufferCreateReady(kCFAllocatorDefault, copied, CMSampleBufferGetFormatDescription(source),
            CMSampleBufferGetNumSamples(source), timingCount, timing, sizeCount, sizes, &result)) goto done;
    CMPropagateAttachments(source, result);
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(source, false);
    if (attachments) {
        CFArrayRef destination = CMSampleBufferGetSampleAttachmentsArray(result, true);
        for (CFIndex i = 0; destination && i < CFArrayGetCount(attachments) && i < CFArrayGetCount(destination); ++i)
            [(__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(destination, i)
                addEntriesFromDictionary:(__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, i)];
    }
    CMTime outputTime = CMSampleBufferGetOutputPresentationTimeStamp(source);
    if (CMTIME_IS_VALID(outputTime)) CMSampleBufferSetOutputPresentationTimeStamp(result, outputTime);
done:
    free(timing); free(sizes); CFRelease(copied);
    return result;
}

static void enqueue(id receiver, SEL command, CMSampleBufferRef sample) {
    if (enqueueDepth++) {
        @try { ((void (*)(id, SEL, CMSampleBufferRef))enqueueOriginal)(receiver, command, sample); }
        @finally { --enqueueDepth; }
        return;
    }
    CMSampleBufferRef copy = NULL;
    @try {
        CMAudioFormatDescriptionRef description = sample ? CMSampleBufferGetFormatDescription(sample) : NULL;
        const AudioStreamBasicDescription *format = description && CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio
            ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
        SAPNoteScheduledBuffer(true, format ? format->mFormatID : 0);
        CMItemCount frames = sample ? CMSampleBufferGetNumSamples(sample) : 0;
        if (format && format->mFormatID == kAudioFormatLinearPCM && frames > 0 && frames <= UINT32_MAX
            && CMSampleBufferDataIsReady(sample)) {
            bool writable = SAPWantsMutableBuffers();
            if (writable) copy = copySample(sample);
            if (!writable || copy) {
                CMSampleBufferRef selected = copy ?: sample;
                struct { UInt32 count; AudioBuffer buffers[32]; } storage = {0};
                CMBlockBufferRef retained = NULL;
                size_t needed = 0;
                OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(selected, &needed,
                    NULL, 0, NULL, NULL, 0, NULL);
                if (!status && needed <= sizeof(storage))
                    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(selected, NULL,
                        (AudioBufferList *)&storage, needed, kCFAllocatorDefault, kCFAllocatorDefault, 0, &retained);
                else if (!status) status = kCMSampleBufferError_ArrayTooSmall;
                if (!status) {
                    SAPProcessExternal((__bridge const void *)receiver, "AVSampleBufferAudioRenderer", format,
                        (AudioBufferList *)&storage, (UInt32)frames, writable);
                    // CoreMedia can return copied storage. Ensure that modified bytes
                    // are the bytes of the buffer actually passed to the renderer.
                    if (copy) {
                        size_t offset = 0;
                        CMBlockBufferRef target = CMSampleBufferGetDataBuffer(copy);
                        for (UInt32 i = 0; i < storage.count; ++i) {
                            status = CMBlockBufferReplaceDataBytes(storage.buffers[i].mData, target, offset, storage.buffers[i].mDataByteSize);
                            if (status) break;
                            offset += storage.buffers[i].mDataByteSize;
                        }
                        if (status) { SAPNoteExtractionError(); CFRelease(copy); copy = NULL; }
                    }
                } else SAPNoteExtractionError();
                if (retained) CFRelease(retained);
            } else SAPNoteExtractionError();
        }
        ((void (*)(id, SEL, CMSampleBufferRef))enqueueOriginal)(receiver, command, copy ?: sample);
    } @finally {
        if (copy) CFRelease(copy);
        --enqueueDepth;
    }
}

static AVAudioPCMBuffer *preparePlayer(id receiver, AVAudioPCMBuffer *buffer) {
    const AudioStreamBasicDescription *format = buffer.format.streamDescription;
    SAPNoteScheduledBuffer(false, format ? format->mFormatID : 0);
    if (!buffer.frameLength || !format || format->mFormatID != kAudioFormatLinearPCM) return buffer;
    bool writable = SAPWantsMutableBuffers();
    AVAudioPCMBuffer *selected = buffer;
    if (writable) {
        selected = [[AVAudioPCMBuffer alloc] initWithPCMFormat:buffer.format frameCapacity:buffer.frameLength];
        if (!selected) { SAPNoteExtractionError(); return buffer; }
        selected.frameLength = buffer.frameLength;
        const AudioBufferList *source = buffer.audioBufferList;
        AudioBufferList *dest = selected.mutableAudioBufferList;
        if (source->mNumberBuffers != dest->mNumberBuffers) { SAPNoteExtractionError(); return buffer; }
        for (UInt32 i = 0; i < source->mNumberBuffers; ++i) {
            if (!source->mBuffers[i].mData || dest->mBuffers[i].mDataByteSize < source->mBuffers[i].mDataByteSize) {
                SAPNoteExtractionError(); return buffer;
            }
            memcpy(dest->mBuffers[i].mData, source->mBuffers[i].mData, source->mBuffers[i].mDataByteSize);
        }
    }
    SAPProcessExternal((__bridge const void *)receiver, "AVAudioPlayerNode", format,
        selected.mutableAudioBufferList, selected.frameLength, writable);
    return selected;
}

static void schedule0(id self, SEL cmd, AVAudioPCMBuffer *buffer, AVAudioNodeCompletionHandler completion) {
    bool outer = scheduleDepth++ == 0;
    @try { ((void (*)(id, SEL, AVAudioPCMBuffer *, AVAudioNodeCompletionHandler))scheduleOriginal[0])
        (self, cmd, outer ? preparePlayer(self, buffer) : buffer, completion); }
    @finally { --scheduleDepth; }
}
static void schedule1(id self, SEL cmd, AVAudioPCMBuffer *buffer, AVAudioPlayerNodeCompletionCallbackType type, AVAudioPlayerNodeCompletionHandler completion) {
    bool outer = scheduleDepth++ == 0;
    @try { ((void (*)(id, SEL, AVAudioPCMBuffer *, AVAudioPlayerNodeCompletionCallbackType, AVAudioPlayerNodeCompletionHandler))scheduleOriginal[1])
        (self, cmd, outer ? preparePlayer(self, buffer) : buffer, type, completion); }
    @finally { --scheduleDepth; }
}
static void schedule2(id self, SEL cmd, AVAudioPCMBuffer *buffer, AVAudioTime *when, AVAudioPlayerNodeBufferOptions options, AVAudioNodeCompletionHandler completion) {
    bool outer = scheduleDepth++ == 0;
    @try { ((void (*)(id, SEL, AVAudioPCMBuffer *, AVAudioTime *, AVAudioPlayerNodeBufferOptions, AVAudioNodeCompletionHandler))scheduleOriginal[2])
        (self, cmd, outer ? preparePlayer(self, buffer) : buffer, when, options, completion); }
    @finally { --scheduleDepth; }
}
static void schedule3(id self, SEL cmd, AVAudioPCMBuffer *buffer, AVAudioTime *when, AVAudioPlayerNodeBufferOptions options,
                      AVAudioPlayerNodeCompletionCallbackType type, AVAudioPlayerNodeCompletionHandler completion) {
    bool outer = scheduleDepth++ == 0;
    @try { ((void (*)(id, SEL, AVAudioPCMBuffer *, AVAudioTime *, AVAudioPlayerNodeBufferOptions, AVAudioPlayerNodeCompletionCallbackType, AVAudioPlayerNodeCompletionHandler))scheduleOriginal[3])
        (self, cmd, outer ? preparePlayer(self, buffer) : buffer, when, options, type, completion); }
    @finally { --scheduleDepth; }
}

static bool install(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return false;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        method_setImplementation(method, replacement);
    return true;
}
void SAPInstallAVHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned installed = install(AVSampleBufferAudioRenderer.class, @selector(enqueueSampleBuffer:), (IMP)enqueue, &enqueueOriginal);
        installed += install(AVAudioPlayerNode.class, @selector(scheduleBuffer:completionHandler:), (IMP)schedule0, &scheduleOriginal[0]);
        installed += install(AVAudioPlayerNode.class, @selector(scheduleBuffer:completionCallbackType:completionHandler:), (IMP)schedule1, &scheduleOriginal[1]);
        installed += install(AVAudioPlayerNode.class, @selector(scheduleBuffer:atTime:options:completionHandler:), (IMP)schedule2, &scheduleOriginal[2]);
        installed += install(AVAudioPlayerNode.class, @selector(scheduleBuffer:atTime:options:completionCallbackType:completionHandler:), (IMP)schedule3, &scheduleOriginal[3]);
        SAPNoteObjCHooks(installed);
    });
}
