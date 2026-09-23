// SGDSPEngine.h says what this is; SGDSPEffects.h lists the effects.
#import "SGDSPEngine.h"
#import <mach/mach_time.h>
#import <math.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import "SGDSPConvolver.h"
#import "SGDSPEffects.h"
#import "SGDSPFilters.h"

_Static_assert(kSGDSPEngineBlock == kSGDSPConvolverBlock && kSGDSPEngineBlock == kSGDSPEffectMaxFrames, "one block size throughout");

// The FIFO the processed blocks wait in: a power of two holding the primed block, the one being handed out
// and the one just made, with room to spare.
enum { kRing = 4 * kSGDSPEngineBlock };

// The order a block goes through the effects: tone, then dynamics and colour, the script, the stereo image,
// and the rooms last.
typedef enum {
    SlotBass, SlotEqualizer, SlotGraphicEq, SlotDDC, SlotCompander, SlotTube, SlotLiveprog, SlotWide, SlotCrossfeed,
    SlotConvolver, SlotReverb, SlotCount,
} Slot;

static void runConvolver(void *state, float *left, float *right, uint32_t frames) {
    SGDSPConvolverProcess(state, left, right);
}

static void freeConvolver(void *state) {
    SGDSPConvolverFree(state);
}

static const struct {
    SGDSPRun run;
    SGDSPFree free;
} kKinds[SlotCount] = {
    [SlotBass] = {SGDSPBassRun, free},
    [SlotEqualizer] = {SGDSPEqualizerRun, free},
    [SlotGraphicEq] = {runConvolver, freeConvolver},
    [SlotDDC] = {SGDSPCascadeRun, SGDSPCascadeFree},
    [SlotCompander] = {SGDSPCompanderRun, free},
    [SlotTube] = {SGDSPTubeRun, free},
    [SlotLiveprog] = {SGDSPLiveprogRun, SGDSPLiveprogFree},
    [SlotWide] = {SGDSPWideRun, free},
    [SlotCrossfeed] = {SGDSPCrossfeedRun, free},
    [SlotConvolver] = {runConvolver, freeConvolver},
    [SlotReverb] = {SGDSPReverbRun, SGDSPReverbFree},
};

typedef struct {
    void *state;      // running; NULL while off
    void *leaving;    // what `state` replaced: faded out over the next block, then the config side's to free
    bool fade;        // the next block crossfades from `leaving` to `state`, NULL being the dry sound
} Effect;

struct SGDSPEngine {
    pthread_mutex_t lock;             // held by every setter, only ever tried by the render thread
    atomic_uint_fast64_t rateBits;
    atomic_bool restart;
    double rate, releaseMS;           // the config side's

    // Under the lock.
    Effect effects[SlotCount];
    float gainTarget, threshold, release;
    float gain, limiter;              // the gain reached and the limiter's own, as the last block left them

    // The render thread's alone.
    uint32_t fill;                    // frames in the block being gathered
    uint64_t written, read;           // frames into and out of the ring, the written ones a block ahead
    float blockLeft[kSGDSPEngineBlock], blockRight[kSGDSPEngineBlock];
    float fromLeft[kSGDSPEngineBlock], fromRight[kSGDSPEngineBlock];
    float ringLeft[kRing], ringRight[kRing];

    atomic_uint_fast64_t blocks, dry, faults;
    atomic_uint_fast64_t averageBits, peakNanos;
};

static double sg_nanosPerTick;
static float sg_ramp[kSGDSPEngineBlock];   // a crossfade's, half a cosine from 0 to 1

static void startOnce(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sg_nanosPerTick = (double)timebase.numer / timebase.denom;
    for (int i = 0; i < kSGDSPEngineBlock; i++) sg_ramp[i] = (float)(0.5 - 0.5 * cos(M_PI * (i + 1) / kSGDSPEngineBlock));
}

static void storeDouble(atomic_uint_fast64_t *slot, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store_explicit(slot, bits, memory_order_relaxed);
}

static double loadDouble(const atomic_uint_fast64_t *slot) {
    uint64_t bits = atomic_load_explicit((atomic_uint_fast64_t *)slot, memory_order_relaxed);
    double value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static void copyError(char *error, size_t errorSize, const char *text) {
    if (error && errorSize) snprintf(error, errorSize, "%s", text);
}

static bool validRate(double rate) {
    return rate >= 8000 && rate <= 384000;
}

#pragma mark - making one

// The FIFO back to one block of silence ahead of the first frame in.
static void startOver(SGDSPEngine *engine) {
    engine->fill = 0;
    engine->read = 0;
    engine->written = kSGDSPEngineBlock;
    memset(engine->ringLeft, 0, kSGDSPEngineBlock * sizeof(float));
    memset(engine->ringRight, 0, kSGDSPEngineBlock * sizeof(float));
}

SGDSPEngine *SGDSPEngineCreate(double sampleRate) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    if (!validRate(sampleRate)) return NULL;
    pthread_once(&once, startOnce);
    SGDSPEngine *engine = calloc(1, sizeof *engine);
    if (!engine || pthread_mutex_init(&engine->lock, NULL) != 0) {
        free(engine);
        return NULL;
    }
    engine->rate = sampleRate;
    storeDouble(&engine->rateBits, sampleRate);
    engine->gain = engine->gainTarget = engine->limiter = 1;
    SGDSPEngineSetOutput(engine, 0, -0.1, 60);
    startOver(engine);
    return engine;
}

// Every effect off at once, with nothing to fade: what was running is freed.
static void dropAll(SGDSPEngine *engine, double rate) {
    void *dropped[SlotCount][2];
    pthread_mutex_lock(&engine->lock);
    for (int s = 0; s < SlotCount; s++) {
        Effect *effect = &engine->effects[s];
        dropped[s][0] = effect->state;
        dropped[s][1] = effect->leaving;
        *effect = (Effect){0};
    }
    engine->rate = rate;
    storeDouble(&engine->rateBits, rate);
    engine->release = (float)exp(-1000 / (engine->releaseMS * rate));
    engine->gain = engine->gainTarget;
    engine->limiter = 1;
    pthread_mutex_unlock(&engine->lock);
    for (int s = 0; s < SlotCount; s++) {
        for (int i = 0; i < 2; i++) {
            if (dropped[s][i]) kKinds[s].free(dropped[s][i]);
        }
    }
}

void SGDSPEngineFree(SGDSPEngine *engine) {
    if (!engine) return;
    dropAll(engine, engine->rate);
    pthread_mutex_destroy(&engine->lock);
    free(engine);
}

double SGDSPEngineSampleRate(const SGDSPEngine *engine) {
    return loadDouble(&engine->rateBits);
}

void SGDSPEngineSetSampleRate(SGDSPEngine *engine, double sampleRate) {
    if (validRate(sampleRate) && sampleRate != engine->rate) dropAll(engine, sampleRate);
}

void SGDSPEngineReset(SGDSPEngine *engine) {
    dropAll(engine, engine->rate);
}

void SGDSPEngineCollect(SGDSPEngine *engine) {
    void *done[SlotCount] = {0};
    pthread_mutex_lock(&engine->lock);
    for (int s = 0; s < SlotCount; s++) {
        Effect *effect = &engine->effects[s];
        if (effect->fade || !effect->leaving) continue;
        done[s] = effect->leaving;
        effect->leaving = NULL;
    }
    pthread_mutex_unlock(&engine->lock);
    for (int s = 0; s < SlotCount; s++) {
        if (done[s]) kKinds[s].free(done[s]);
    }
}

#pragma mark - the render thread

static bool allFinite(const float *left, const float *right) {
    // Anything times zero is zero, but for NaN and infinity: the sum is NaN when one of them is.
    float sum = 0;
    for (uint32_t i = 0; i < kSGDSPEngineBlock; i++) sum += left[i] * 0.0f + right[i] * 0.0f;
    return sum == sum;
}

static void crossfade(SGDSPEngine *engine, Slot slot, float *left, float *right) {
    Effect *effect = &engine->effects[slot];
    memcpy(engine->fromLeft, left, sizeof engine->fromLeft);
    memcpy(engine->fromRight, right, sizeof engine->fromRight);
    if (effect->leaving) kKinds[slot].run(effect->leaving, engine->fromLeft, engine->fromRight, kSGDSPEngineBlock);
    if (effect->state) kKinds[slot].run(effect->state, left, right, kSGDSPEngineBlock);
    for (uint32_t i = 0; i < kSGDSPEngineBlock; i++) {
        left[i] = engine->fromLeft[i] + (left[i] - engine->fromLeft[i]) * sg_ramp[i];
        right[i] = engine->fromRight[i] + (right[i] - engine->fromRight[i]) * sg_ramp[i];
    }
    effect->fade = false;
}

// The gain, moving to a new one over the block, then a limiter with no lookahead: it clamps a peak the
// sample it comes, stereo linked, and lets go at the release's pace.
static void output(SGDSPEngine *engine, float *left, float *right) {
    float from = engine->gain, to = engine->gainTarget, step = (to - from) / kSGDSPEngineBlock;
    float threshold = engine->threshold, release = engine->release, limiter = engine->limiter;
    for (uint32_t i = 0; i < kSGDSPEngineBlock; i++) {
        float gain = from == to ? to : from + step * (i + 1);
        float l = left[i] * gain, r = right[i] * gain;
        float peak = fmaxf(fabsf(l), fabsf(r));
        float target = peak > threshold ? threshold / peak : 1;
        limiter = target < limiter ? target : target + (limiter - target) * release;
        left[i] = l * limiter;
        right[i] = r * limiter;
    }
    engine->gain = to;
    engine->limiter = limiter;
}

// The block through what is on; answers whether anything touched it.
static bool process(SGDSPEngine *engine, float *left, float *right) {
    bool active = false;
    for (int s = 0; s < SlotCount; s++) {
        Effect *effect = &engine->effects[s];
        if (effect->fade) crossfade(engine, (Slot)s, left, right);
        else if (effect->state) kKinds[s].run(effect->state, left, right, kSGDSPEngineBlock);
        else continue;
        active = true;
    }
    active = active || engine->gain != 1 || engine->gainTarget != 1 || engine->limiter != 1;
    if (active) output(engine, left, right);
    return active;
}

// The gathered block, processed (or as it is, when a setter holds the lock) into the ring. The ring is a
// whole number of blocks and blocks are written whole, so a block never wraps.
static void runBlock(SGDSPEngine *engine) {
    uint64_t at = engine->written & (kRing - 1);
    float *left = engine->ringLeft + at, *right = engine->ringRight + at;
    memcpy(left, engine->blockLeft, sizeof engine->blockLeft);
    memcpy(right, engine->blockRight, sizeof engine->blockRight);
    if (pthread_mutex_trylock(&engine->lock) != 0) {
        atomic_fetch_add_explicit(&engine->dry, 1, memory_order_relaxed);
    } else {
        uint64_t start = mach_absolute_time();
        bool active = process(engine, left, right);
        pthread_mutex_unlock(&engine->lock);
        uint64_t nanos = (uint64_t)((mach_absolute_time() - start) * sg_nanosPerTick);
        double average = loadDouble(&engine->averageBits);
        storeDouble(&engine->averageBits, average ? average + (nanos - average) * 0.05 : nanos);
        if (nanos > atomic_load_explicit(&engine->peakNanos, memory_order_relaxed)) {
            atomic_store_explicit(&engine->peakNanos, nanos, memory_order_relaxed);
        }
        atomic_fetch_add_explicit(&engine->blocks, 1, memory_order_relaxed);
        // An effect gone unstable would put NaN into its own state and every block after; silence rather
        // than noise, and the config side resets the engine when it sees the count move.
        if (active && !allFinite(left, right)) {
            memset(left, 0, sizeof engine->blockLeft);
            memset(right, 0, sizeof engine->blockRight);
            atomic_fetch_add_explicit(&engine->faults, 1, memory_order_relaxed);
        }
    }
    engine->written += kSGDSPEngineBlock;
}

void SGDSPEngineProcess(SGDSPEngine *engine, float *left, float *right, uint32_t frames) {
    if (atomic_exchange_explicit(&engine->restart, false, memory_order_acquire)) startOver(engine);
    uint32_t in = 0, out = 0;
    while (in < frames) {
        uint32_t take = kSGDSPEngineBlock - engine->fill;
        if (take > frames - in) take = frames - in;
        memcpy(engine->blockLeft + engine->fill, left + in, take * sizeof(float));
        memcpy(engine->blockRight + engine->fill, right + in, take * sizeof(float));
        engine->fill += take;
        in += take;
        if (engine->fill == kSGDSPEngineBlock) {
            runBlock(engine);
            engine->fill = 0;
        }
        // As many frames out as came in: the ring is always a block ahead, so it has them, and the frames
        // overwritten were copied into the block already.
        while (out < in) {
            uint32_t at = (uint32_t)(engine->read & (kRing - 1));
            uint32_t count = in - out;
            if (count > kRing - at) count = kRing - at;
            memcpy(left + out, engine->ringLeft + at, count * sizeof(float));
            memcpy(right + out, engine->ringRight + at, count * sizeof(float));
            engine->read += count;
            out += count;
        }
    }
}

void SGDSPEngineRestart(SGDSPEngine *engine) {
    atomic_store_explicit(&engine->restart, true, memory_order_release);
}

SGDSPEngineStats SGDSPEngineReadStats(SGDSPEngine *engine, bool takePeak) {
    SGDSPEngineStats stats = {
        .blocks = atomic_load_explicit(&engine->blocks, memory_order_relaxed),
        .dry = atomic_load_explicit(&engine->dry, memory_order_relaxed),
        .faults = atomic_load_explicit(&engine->faults, memory_order_relaxed),
        .averageMS = loadDouble(&engine->averageBits) / 1e6,
        .peakMS = (takePeak ? atomic_exchange_explicit(&engine->peakNanos, 0, memory_order_relaxed)
                            : atomic_load_explicit(&engine->peakNanos, memory_order_relaxed)) / 1e6,
    };
    double blockMS = kSGDSPEngineBlock / SGDSPEngineSampleRate(engine) * 1000;
    stats.load = stats.averageMS / blockMS;
    return stats;
}

#pragma mark - setting the effects

// A new state for the slot (NULL: off), crossfaded in over the next block. A fade still to be heard keeps
// what is heard now as its start, and the state it was going to drops.
static void install(SGDSPEngine *engine, Slot slot, void *state) {
    Effect *effect = &engine->effects[slot];
    void *dropped;
    pthread_mutex_lock(&engine->lock);
    if (effect->fade) {
        dropped = effect->state;
    } else {
        dropped = effect->leaving;
        effect->leaving = effect->state;
    }
    effect->state = state;
    effect->fade = effect->leaving || state;
    pthread_mutex_unlock(&engine->lock);
    if (dropped) kKinds[slot].free(dropped);
    SGDSPEngineCollect(engine);
}

// The running state, under the lock, for a setter to change in place; NULL (and the lock released) when off.
static void *running(SGDSPEngine *engine, Slot slot) {
    pthread_mutex_lock(&engine->lock);
    void *state = engine->effects[slot].state;
    if (!state) pthread_mutex_unlock(&engine->lock);
    return state;
}

static void done(SGDSPEngine *engine) {
    pthread_mutex_unlock(&engine->lock);
}

void SGDSPEngineSetOutput(SGDSPEngine *engine, double postGainDB, double limiterThresholdDB, double limiterReleaseMS) {
    engine->releaseMS = fmax(limiterReleaseMS, 0.1);
    pthread_mutex_lock(&engine->lock);
    engine->gainTarget = (float)pow(10, postGainDB / 20);
    engine->threshold = (float)pow(10, fmin(limiterThresholdDB, 0) / 20);
    engine->release = (float)exp(-1000 / (engine->releaseMS * engine->rate));
    pthread_mutex_unlock(&engine->lock);
}

void SGDSPEngineSetCompander(SGDSPEngine *engine, bool on, double timeConstant, const double frequencies[7], const double gains[7]) {
    if (!on) {
        install(engine, SlotCompander, NULL);
        return;
    }
    SGDSPCompander *compander = running(engine, SlotCompander);
    if (compander) {
        SGDSPCompanderSet(compander, timeConstant, gains);
        done(engine);
        return;
    }
    install(engine, SlotCompander, SGDSPCompanderCreate(engine->rate, timeConstant, frequencies, gains));
}

void SGDSPEngineSetBassBoost(SGDSPEngine *engine, bool on, double maxGainDB) {
    if (!on) {
        install(engine, SlotBass, NULL);
        return;
    }
    SGDSPBass *bass = running(engine, SlotBass);
    if (bass) {
        SGDSPBassSet(bass, maxGainDB);
        done(engine);
        return;
    }
    install(engine, SlotBass, SGDSPBassCreate(engine->rate, maxGainDB));
}

void SGDSPEngineSetEqualizer(SGDSPEngine *engine, bool on, const double frequencies[15], const double gains[15]) {
    if (!on) {
        install(engine, SlotEqualizer, NULL);
        return;
    }
    SGBiquad bands[15];
    SGDSPDesignEqualizer(engine->rate, frequencies, gains, bands);
    SGDSPEqualizer *equalizer = running(engine, SlotEqualizer);
    if (equalizer) {
        SGDSPEqualizerSet(equalizer, bands);
        done(engine);
        return;
    }
    install(engine, SlotEqualizer, SGDSPEqualizerCreate(bands));
}

void SGDSPEngineSetReverb(SGDSPEngine *engine, bool on, int preset) {
    if (!on) {
        install(engine, SlotReverb, NULL);
        return;
    }
    SGDSPReverb *reverb = running(engine, SlotReverb);
    if (reverb) {
        SGDSPReverbSet(reverb, preset);
        done(engine);
        return;
    }
    install(engine, SlotReverb, SGDSPReverbCreate(engine->rate, preset));
}

void SGDSPEngineSetStereoWide(SGDSPEngine *engine, bool on, double levelPercent) {
    if (!on) {
        install(engine, SlotWide, NULL);
        return;
    }
    SGDSPWide *wide = running(engine, SlotWide);
    if (wide) {
        SGDSPWideSet(wide, levelPercent);
        done(engine);
        return;
    }
    install(engine, SlotWide, SGDSPWideCreate(engine->rate, levelPercent));
}

void SGDSPEngineSetCrossfeed(SGDSPEngine *engine, bool on, int preset) {
    if (!on) {
        install(engine, SlotCrossfeed, NULL);
        return;
    }
    SGDSPCrossfeed *crossfeed = running(engine, SlotCrossfeed);
    if (crossfeed) {
        SGDSPCrossfeedSet(crossfeed, preset);
        done(engine);
        return;
    }
    install(engine, SlotCrossfeed, SGDSPCrossfeedCreate(engine->rate, preset));
}

void SGDSPEngineSetTube(SGDSPEngine *engine, bool on, double driveDB) {
    if (!on) {
        install(engine, SlotTube, NULL);
        return;
    }
    SGDSPTube *tube = running(engine, SlotTube);
    if (tube) {
        SGDSPTubeSet(tube, driveDB);
        done(engine);
        return;
    }
    install(engine, SlotTube, SGDSPTubeCreate(engine->rate, driveDB));
}

#pragma mark - effects that read something

bool SGDSPEngineSetGraphicEq(SGDSPEngine *engine, bool on, const char *nodes, char *error, size_t errorSize) {
    if (!on) {
        install(engine, SlotGraphicEq, NULL);
        return true;
    }
    SGDSPGraphicCurve curve;
    if (!SGDSPParseGraphicEq(nodes, &curve)) {
        install(engine, SlotGraphicEq, NULL);
        copyError(error, errorSize, "Not in AutoEq's GraphicEQ format (\"GraphicEQ: 20 -1.2; 21 -1.1; ...\")");
        return false;
    }
    int taps = 0;
    float *impulse = SGDSPDesignGraphicEq(&curve, engine->rate, &taps);
    SGDSPFreeGraphicEq(&curve);
    const float *responses[1] = {impulse};
    SGDSPConvolver *convolver = impulse ? SGDSPConvolverCreate(responses, 1, (size_t)taps) : NULL;
    free(impulse);
    install(engine, SlotGraphicEq, convolver);
    if (!convolver) copyError(error, errorSize, "Not enough memory for the curve");
    return convolver != NULL;
}

bool SGDSPEngineSetConvolver(SGDSPEngine *engine, bool on, const char *path, int mode, char *error, size_t errorSize) {
    if (!on) {
        install(engine, SlotConvolver, NULL);
        return true;
    }
    SGDSPImpulse impulse;
    SGDSPImpulseMode kind = mode == 1 ? SGDSPImpulseTrimmed : mode == 2 ? SGDSPImpulseMinimumPhase : SGDSPImpulseOriginal;
    if (!SGDSPReadImpulse(path, engine->rate, kind, &impulse, error, errorSize)) {
        install(engine, SlotConvolver, NULL);
        return false;
    }
    SGDSPConvolver *convolver = SGDSPConvolverCreate((const float *const *)impulse.responses, impulse.paths, impulse.length);
    SGDSPFreeImpulse(&impulse);
    install(engine, SlotConvolver, convolver);
    if (!convolver) copyError(error, errorSize, "Not enough memory for the impulse response");
    return convolver != NULL;
}

bool SGDSPEngineSetDDC(SGDSPEngine *engine, bool on, const char *text, char *error, size_t errorSize) {
    if (!on) {
        install(engine, SlotDDC, NULL);
        return true;
    }
    SGDSPDDC ddc;
    if (!text || !SGDSPParseDDC(text, &ddc, error, errorSize)) {
        if (!text) copyError(error, errorSize, "The DDC file could not be read");
        install(engine, SlotDDC, NULL);
        return false;
    }
    int count = 0;
    SGBiquad *sections = SGDSPDDCFor(&ddc, engine->rate, &count);
    SGDSPFreeDDC(&ddc);
    SGDSPCascade *cascade = sections ? SGDSPCascadeCreate(sections, count) : NULL;
    install(engine, SlotDDC, cascade);
    if (!cascade) copyError(error, errorSize, "Not enough memory for the DDC file");
    return cascade != NULL;
}

bool SGDSPEngineSetLiveprog(SGDSPEngine *engine, bool on, const char *script, char *error, size_t errorSize) {
    SGDSPLiveprog *liveprog = on ? SGDSPLiveprogCreate(script, engine->rate, error, errorSize) : NULL;
    install(engine, SlotLiveprog, liveprog);
    return !on || liveprog;
}

#pragma mark - curves

void SGDSPEngineEqualizerCurve(const double bandFrequencies[15], const double gains[15], int count, double *frequencies, double *decibels) {
    if (count <= 0) return;
    SGDSPLogFrequencies(count, frequencies);
    SGBiquad bands[15];
    SGDSPDesignEqualizer(48000, bandFrequencies, gains, bands);
    for (int i = 0; i < count; i++) decibels[i] = SGBiquadGainDB(bands, 15, 48000, frequencies[i]);
}

void SGDSPEngineCompanderCurve(const double bandFrequencies[7], const double gains[7], int count, double *frequencies, double *values) {
    if (count <= 0) return;
    SGDSPLogFrequencies(count, frequencies);
    for (int i = 0; i < count; i++) values[i] = SGDSPSmoothCurve(bandFrequencies, gains, 7, frequencies[i]);
}
