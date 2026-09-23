#import "SGDSPConvolver.h"
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import "SGDSPFilters.h"

enum { kBlock = kSGDSPConvolverBlock, kSpread = 8, kTail = kBlock * kSpread, kHeadFrames = 2 * kTail };

typedef struct {
    int input, output, response;
} Route;

// One partition size: the responses' spectra, the inputs' spectra of as many partitions back, and what
// is being summed for each output. Split complex, packed as vDSP's real FFT packs them (bin 0 holds the DC
// and the Nyquist bins).
typedef struct {
    int size, log2n, partitions;
    float *responseRe[4], *responseIm[4];
    float *historyRe[2], *historyIm[2];
    float *window[2];                   // the last two partitions of each input
    float *sumRe[2], *sumIm[2];
    int newest;
} Level;

struct SGDSPConvolver {
    FFTSetup setup;
    Route routes[4];
    int routeCount, responses;
    Level head, tail;
    bool hasTail;
    float *time;                        // an FFT's worth of scratch
    float *output[2];                   // the head's result for the block
    float *tailOutput[2][2];            // the tail's result, read over the next kSpread blocks while the next is made
    int reading, phase, step, done;
    bool pending;
};

#pragma mark - making one

// Zeroed and touched here, so the render thread never takes the page faults of fresh pages.
static float *zeroed(size_t count) {
    float *floats = malloc(count * sizeof(float));
    if (floats) memset(floats, 0, count * sizeof(float));
    return floats;
}

static bool makeLevel(Level *level, FFTSetup setup, int size, const float *const *responses, int count, size_t from, size_t length) {
    level->size = size;
    level->log2n = (int)log2(2 * size);
    level->partitions = (int)((length - from + size - 1) / size);
    size_t floats = (size_t)level->partitions * size;
    float *time = calloc(2 * size, sizeof(float));
    bool ok = time != NULL;
    for (int c = 0; c < 2 && ok; c++) {
        ok = (level->historyRe[c] = zeroed(floats)) && (level->historyIm[c] = zeroed(floats)) && (level->window[c] = zeroed(2 * size))
             && (level->sumRe[c] = zeroed(size)) && (level->sumIm[c] = zeroed(size));
    }
    // A response's partitions transformed once, scaled so that the inverse transform of their products is
    // the convolution itself (vDSP's forward transform doubles, its inverse multiplies by the length).
    float scale = 1.0f / (8.0f * size);
    for (int r = 0; r < count && ok; r++) {
        ok = (level->responseRe[r] = malloc(floats * sizeof(float))) && (level->responseIm[r] = malloc(floats * sizeof(float)));
        for (int j = 0; ok && j < level->partitions; j++) {
            size_t start = from + (size_t)j * size;
            size_t take = length - start < (size_t)size ? length - start : (size_t)size;
            memset(time, 0, 2 * size * sizeof(float));
            memcpy(time, responses[r] + start, take * sizeof(float));
            DSPSplitComplex split = {level->responseRe[r] + (size_t)j * size, level->responseIm[r] + (size_t)j * size};
            vDSP_ctoz((const DSPComplex *)time, 2, &split, 1, size);
            vDSP_fft_zrip(setup, &split, 1, level->log2n, kFFTDirection_Forward);
            vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, size);
            vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, size);
        }
    }
    free(time);
    return ok;
}

static void freeLevel(Level *level) {
    for (int i = 0; i < 4; i++) {
        free(level->responseRe[i]);
        free(level->responseIm[i]);
    }
    for (int c = 0; c < 2; c++) {
        free(level->historyRe[c]);
        free(level->historyIm[c]);
        free(level->window[c]);
        free(level->sumRe[c]);
        free(level->sumIm[c]);
    }
}

SGDSPConvolver *SGDSPConvolverCreate(const float *const *responses, int paths, size_t length) {
    if ((paths != 1 && paths != 2 && paths != 4) || !length) return NULL;
    SGDSPConvolver *convolver = calloc(1, sizeof *convolver);
    if (!convolver) return NULL;
    static const Route mono[] = {{0, 0, 0}, {1, 1, 0}}, stereo[] = {{0, 0, 0}, {1, 1, 1}},
                       full[] = {{0, 0, 0}, {0, 1, 1}, {1, 0, 2}, {1, 1, 3}};
    const Route *routes = paths == 1 ? mono : paths == 2 ? stereo : full;
    convolver->routeCount = paths == 4 ? 4 : 2;
    memcpy(convolver->routes, routes, convolver->routeCount * sizeof(Route));
    convolver->responses = paths;
    convolver->hasTail = length > kHeadFrames;
    convolver->setup = vDSP_create_fftsetup(convolver->hasTail ? 14 : 11, kFFTRadix2);
    bool ok = convolver->setup && (convolver->time = zeroed(2 * kTail));
    for (int c = 0; c < 2 && ok; c++) ok = (convolver->output[c] = zeroed(kBlock));
    ok = ok && makeLevel(&convolver->head, convolver->setup, kBlock, responses, paths, 0, length < kHeadFrames ? length : kHeadFrames);
    if (ok && convolver->hasTail) {
        ok = makeLevel(&convolver->tail, convolver->setup, kTail, responses, paths, kHeadFrames, length);
        for (int b = 0; b < 2 && ok; b++) {
            for (int c = 0; c < 2 && ok; c++) ok = (convolver->tailOutput[b][c] = zeroed(kTail));
        }
    }
    if (!ok) {
        SGDSPConvolverFree(convolver);
        return NULL;
    }
    return convolver;
}

void SGDSPConvolverFree(SGDSPConvolver *convolver) {
    if (!convolver) return;
    freeLevel(&convolver->head);
    freeLevel(&convolver->tail);
    for (int c = 0; c < 2; c++) {
        free(convolver->output[c]);
        free(convolver->tailOutput[0][c]);
        free(convolver->tailOutput[1][c]);
    }
    free(convolver->time);
    if (convolver->setup) vDSP_destroy_fftsetup(convolver->setup);
    free(convolver);
}

#pragma mark - the render thread

static void forward(SGDSPConvolver *convolver, Level *level, int channel) {
    size_t at = (size_t)level->newest * level->size;
    DSPSplitComplex split = {level->historyRe[channel] + at, level->historyIm[channel] + at};
    vDSP_ctoz((const DSPComplex *)level->window[channel], 2, &split, 1, level->size);
    vDSP_fft_zrip(convolver->setup, &split, 1, level->log2n, kFFTDirection_Forward);
}

// sum += input * response, bin by bin; bin 0's two halves are real and multiply apart.
static void multiplyAdd(Level *level, const Route *route, int partition) {
    int size = level->size, slot = (level->newest - partition + level->partitions) % level->partitions;
    const float *xr = level->historyRe[route->input] + (size_t)slot * size, *xi = level->historyIm[route->input] + (size_t)slot * size;
    const float *hr = level->responseRe[route->response] + (size_t)partition * size;
    const float *hi = level->responseIm[route->response] + (size_t)partition * size;
    float *sr = level->sumRe[route->output], *si = level->sumIm[route->output];
    float dc = sr[0] + xr[0] * hr[0], nyquist = si[0] + xi[0] * hi[0];
    DSPSplitComplex x = {(float *)xr + 1, (float *)xi + 1}, h = {(float *)hr + 1, (float *)hi + 1}, s = {sr + 1, si + 1};
    vDSP_zvma(&x, 1, &h, 1, &s, 1, &s, 1, size - 1);
    sr[0] = dc;
    si[0] = nyquist;
}

static void accumulate(SGDSPConvolver *convolver, Level *level, int from, int to) {
    for (int j = from; j < to; j++) {
        for (int r = 0; r < convolver->routeCount; r++) multiplyAdd(level, &convolver->routes[r], j);
    }
}

// The sum back to time: its second half is the output (overlap-save).
static void inverse(SGDSPConvolver *convolver, Level *level, int channel, float *output) {
    DSPSplitComplex split = {level->sumRe[channel], level->sumIm[channel]};
    vDSP_fft_zrip(convolver->setup, &split, 1, level->log2n, kFFTDirection_Inverse);
    vDSP_ztoc(&split, 1, (DSPComplex *)convolver->time, 2, level->size);
    memcpy(output, convolver->time + level->size, level->size * sizeof(float));
    memset(level->sumRe[channel], 0, level->size * sizeof(float));
    memset(level->sumIm[channel], 0, level->size * sizeof(float));
}

void SGDSPConvolverProcess(SGDSPConvolver *convolver, float *left, float *right) {
    float *lanes[2] = {left, right};
    Level *head = &convolver->head, *tail = &convolver->tail;

    head->newest = (head->newest + 1) % head->partitions;
    for (int c = 0; c < 2; c++) {
        memmove(head->window[c], head->window[c] + kBlock, kBlock * sizeof(float));
        memcpy(head->window[c] + kBlock, lanes[c], kBlock * sizeof(float));
        forward(convolver, head, c);
    }
    accumulate(convolver, head, 0, head->partitions);
    for (int c = 0; c < 2; c++) inverse(convolver, head, c, convolver->output[c]);

    if (convolver->hasTail) {
        int phase = convolver->phase;
        for (int c = 0; c < 2; c++) {
            memcpy(tail->window[c] + kTail + phase * kBlock, lanes[c], kBlock * sizeof(float));
            vDSP_vadd(convolver->output[c], 1, convolver->tailOutput[convolver->reading][c] + phase * kBlock, 1, convolver->output[c], 1, kBlock);
        }
        if (phase == kSpread - 1) {
            // A tail partition of input is complete: the sum for the one before it is finished and becomes the
            // next kSpread blocks' output, and this one's spectrum starts a new sum.
            int next = 1 - convolver->reading;
            for (int c = 0; c < 2; c++) {
                if (convolver->pending) {
                    accumulate(convolver, tail, convolver->done, tail->partitions);
                    inverse(convolver, tail, c, convolver->tailOutput[next][c]);
                } else {
                    memset(convolver->tailOutput[next][c], 0, kTail * sizeof(float));
                }
            }
            convolver->reading = next;
            tail->newest = (tail->newest + 1) % tail->partitions;
            for (int c = 0; c < 2; c++) {
                forward(convolver, tail, c);
                memmove(tail->window[c], tail->window[c] + kTail, kTail * sizeof(float));
            }
            convolver->pending = true;
            convolver->step = convolver->done = 0;
        }
        if (convolver->pending) {
            int target = (convolver->step + 1) * tail->partitions / kSpread;
            if (convolver->step == kSpread - 1) target = tail->partitions;
            accumulate(convolver, tail, convolver->done, target);
            convolver->done = target > convolver->done ? target : convolver->done;
            convolver->step++;
        }
        convolver->phase = (phase + 1) % kSpread;
    }
    memcpy(left, convolver->output[0], kBlock * sizeof(float));
    memcpy(right, convolver->output[1], kBlock * sizeof(float));
}

#pragma mark - reading a response

static void copyError(char *error, size_t size, const char *text) {
    if (error && size) snprintf(error, size, "%s", text);
}

// Interleaved float at `rate`, however the file is stored. malloc'd; NULL when it cannot be read.
static float *readFile(const char *path, double rate, int *channels, size_t *frames) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) return NULL;
    const char *dot = strrchr(path, '.');
    AudioFileTypeID hint = dot && !strcasecmp(dot, ".flac") ? kAudioFileFLACType : kAudioFileWAVEType;
    AudioFileID file = NULL;
    OSStatus status = AudioFileOpenURL(url, kAudioFileReadPermission, hint, &file);
    CFRelease(url);
    if (status != noErr) return NULL;
    ExtAudioFileRef audio = NULL;
    if (ExtAudioFileWrapAudioFileID(file, false, &audio) != noErr) {
        AudioFileClose(file);
        return NULL;
    }
    float *samples = NULL;
    AudioStreamBasicDescription source = {0};
    SInt64 fileFrames = 0;
    UInt32 size = sizeof source;
    status = ExtAudioFileGetProperty(audio, kExtAudioFileProperty_FileDataFormat, &size, &source);
    size = sizeof fileFrames;
    if (!status) status = ExtAudioFileGetProperty(audio, kExtAudioFileProperty_FileLengthFrames, &size, &fileFrames);
    int count = (int)source.mChannelsPerFrame;
    if (!status && (count == 1 || count == 2 || count == 4) && source.mSampleRate > 0 && fileFrames > 0) {
        AudioStreamBasicDescription client = {
            .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
            .mBytesPerPacket = 4 * count, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * count, .mChannelsPerFrame = count, .mBitsPerChannel = 32,
        };
        status = ExtAudioFileSetProperty(audio, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client);
        AudioConverterRef converter = NULL;
        size = sizeof converter;
        if (!status && source.mSampleRate != rate
            && ExtAudioFileGetProperty(audio, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr && converter) {
            UInt32 quality = kAudioConverterQuality_Max, complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
            AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, sizeof quality, &quality);
            AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity, sizeof complexity, &complexity);
            CFArrayRef config = NULL;
            ExtAudioFileSetProperty(audio, kExtAudioFileProperty_ConverterConfig, sizeof config, &config);
        }
        size_t capacity = (size_t)ceil(fileFrames * rate / source.mSampleRate) + 4096;
        if (capacity > kSGDSPConvolverMaxFrames + 4096) capacity = kSGDSPConvolverMaxFrames + 4096;
        samples = status ? NULL : malloc(capacity * count * sizeof(float));
        size_t done = 0;
        while (samples && done < capacity) {
            UInt32 chunk = (UInt32)(capacity - done < 16384 ? capacity - done : 16384);
            AudioBufferList list = {1, {{(UInt32)count, chunk * 4 * count, samples + done * count}}};
            if (ExtAudioFileRead(audio, &chunk, &list) != noErr) {
                free(samples);
                samples = NULL;
                break;
            }
            if (!chunk) break;
            done += chunk;
        }
        *channels = count;
        *frames = done;
    }
    ExtAudioFileDispose(audio);
    AudioFileClose(file);
    return samples;
}

// The last frame over -80 dB of the response's peak, plus one.
static size_t audibleLength(const SGDSPImpulse *impulse) {
    float peak = 0;
    for (int p = 0; p < impulse->paths; p++) {
        float m = 0;
        vDSP_maxmgv(impulse->responses[p], 1, &m, impulse->length);
        peak = fmaxf(peak, m);
    }
    size_t length = 1;
    for (int p = 0; p < impulse->paths; p++) {
        for (size_t i = impulse->length; i > length; i--) {
            if (fabsf(impulse->responses[p][i - 1]) > peak * 1e-4f) {
                length = i;
                break;
            }
        }
    }
    return length;
}

static bool makeMinimumPhase(SGDSPImpulse *impulse) {
    int log2n = 0;
    while ((1ul << log2n) < 2 * impulse->length) log2n++;
    if (log2n > 21) log2n = 21;
    size_t n = 1ul << log2n;
    FFTSetup setup = vDSP_create_fftsetup(log2n, kFFTRadix2);
    float *re = malloc(n / 2 * sizeof(float)), *im = malloc(n / 2 * sizeof(float)), *time = calloc(n, sizeof(float));
    double *magnitude = malloc((n / 2 + 1) * sizeof(double));
    bool ok = setup && re && im && time && magnitude;
    for (int p = 0; p < impulse->paths && ok; p++) {
        size_t take = impulse->length < n ? impulse->length : n;
        memset(time, 0, n * sizeof(float));
        memcpy(time, impulse->responses[p], take * sizeof(float));
        DSPSplitComplex split = {re, im};
        vDSP_ctoz((const DSPComplex *)time, 2, &split, 1, n / 2);
        vDSP_fft_zrip(setup, &split, 1, log2n, kFFTDirection_Forward);
        magnitude[0] = fabs(re[0]) / 2;
        magnitude[n / 2] = fabs(im[0]) / 2;
        for (size_t k = 1; k < n / 2; k++) magnitude[k] = hypot(re[k], im[k]) / 2;
        ok = SGDSPMinimumPhase(magnitude, log2n, impulse->responses[p], (int)impulse->length);
    }
    if (setup) vDSP_destroy_fftsetup(setup);
    free(re);
    free(im);
    free(time);
    free(magnitude);
    return ok;
}

bool SGDSPReadImpulse(const char *path, double rate, SGDSPImpulseMode mode, SGDSPImpulse *impulse, char *error, size_t errorSize) {
    memset(impulse, 0, sizeof *impulse);
    int channels = 0;
    size_t frames = 0;
    float *samples = path ? readFile(path, rate, &channels, &frames) : NULL;
    if (!samples) {
        copyError(error, errorSize, "The impulse response could not be read: a WAV or FLAC file of 1, 2 or 4 channels");
        return false;
    }
    if (!frames) {
        free(samples);
        copyError(error, errorSize, "The impulse response is empty");
        return false;
    }
    size_t length = frames < kSGDSPConvolverMaxFrames ? frames : kSGDSPConvolverMaxFrames;
    impulse->paths = channels;
    impulse->length = length;
    bool ok = true;
    for (int p = 0; p < channels && ok; p++) {
        ok = (impulse->responses[p] = malloc(length * sizeof(float)));
        for (size_t i = 0; ok && i < length; i++) impulse->responses[p][i] = samples[i * channels + p];
    }
    free(samples);
    if (ok && frames > length) {
        // Cut at the limit: the last 4096 frames faded out.
        for (int p = 0; p < channels; p++) {
            for (size_t i = 0; i < 4096; i++) impulse->responses[p][length - 4096 + i] *= (float)(0.5 + 0.5 * cos(M_PI * (i + 1) / 4096));
        }
    }
    if (ok && mode == SGDSPImpulseMinimumPhase) ok = makeMinimumPhase(impulse);
    if (ok && mode != SGDSPImpulseOriginal) impulse->length = audibleLength(impulse);
    if (!ok) {
        SGDSPFreeImpulse(impulse);
        copyError(error, errorSize, "Not enough memory for the impulse response");
        return false;
    }
    // The power each output takes from its paths; the loudest one brought to unity.
    double power[2] = {0, 0};
    for (int p = 0; p < channels; p++) {
        float sum = 0;
        vDSP_svesq(impulse->responses[p], 1, &sum, impulse->length);
        int output = channels == 4 ? p & 1 : p & (channels > 1);
        power[output] += sum;
    }
    double loudest = fmax(power[0], power[1]);
    if (!(loudest > 1e-12) || !isfinite(loudest)) {
        SGDSPFreeImpulse(impulse);
        copyError(error, errorSize, "The impulse response is silent");
        return false;
    }
    float scale = (float)(1 / sqrt(loudest));
    for (int p = 0; p < channels; p++) vDSP_vsmul(impulse->responses[p], 1, &scale, impulse->responses[p], 1, impulse->length);
    return true;
}

void SGDSPFreeImpulse(SGDSPImpulse *impulse) {
    for (int p = 0; p < 4; p++) free(impulse->responses[p]);
    memset(impulse, 0, sizeof *impulse);
}
