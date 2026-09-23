#import "SGDSPEffects.h"
#import <math.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - bass boost

static const double kShelfFrequency = 100, kDetectorFrequency = 150, kKneeDB = -3;
enum { kBassStep = 32 };   // frames between the shelf's redesigns

struct SGDSPBass {
    double rate, maxGain, gain;
    double level, levelAttack, levelRelease, gainAttack, gainRelease;
    SGBiquad detector, shelf;
    SGBiquadState detectorState, shelfState[2];
};

SGDSPBass *SGDSPBassCreate(double rate, double maxGainDB) {
    SGDSPBass *bass = calloc(1, sizeof *bass);
    if (!bass) return NULL;
    bass->rate = rate;
    bass->detector = SGBiquadLowPass(rate, kDetectorFrequency, M_SQRT1_2);
    bass->levelAttack = exp(-1 / (0.005 * rate));
    bass->levelRelease = exp(-1 / (0.2 * rate));
    bass->gainAttack = exp(-kBassStep / (0.01 * rate));
    bass->gainRelease = exp(-kBassStep / (0.3 * rate));
    SGDSPBassSet(bass, maxGainDB);
    bass->gain = bass->maxGain;
    bass->shelf = SGBiquadLowShelf(rate, kShelfFrequency, M_SQRT1_2, bass->gain);
    return bass;
}

void SGDSPBassSet(SGDSPBass *bass, double maxGainDB) {
    bass->maxGain = fmax(0, maxGainDB);
}

void SGDSPBassRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPBass *bass = state;
    for (uint32_t start = 0; start < frames; start += kBassStep) {
        uint32_t end = start + kBassStep < frames ? start + kBassStep : frames;
        for (uint32_t i = start; i < end; i++) {
            double low = fabs(SGBiquadTick(&bass->detector, &bass->detectorState, 0.5 * (left[i] + right[i])));
            double coefficient = low > bass->level ? bass->levelAttack : bass->levelRelease;
            bass->level = low + (bass->level - low) * coefficient;
        }
        // As much lift as keeps the lows' peaks under the knee, and no more than asked for.
        double levelDB = 20 * log10(bass->level + 1e-9);
        double target = fmax(0, fmin(bass->maxGain, kKneeDB - levelDB));
        double coefficient = target < bass->gain ? bass->gainAttack : bass->gainRelease;
        double gain = target + (bass->gain - target) * coefficient;
        if (fabs(gain - bass->gain) > 0.005) {
            bass->gain = gain;
            bass->shelf = SGBiquadLowShelf(bass->rate, kShelfFrequency, M_SQRT1_2, gain);
        }
        SGBiquadRun(&bass->shelf, &bass->shelfState[0], 1, left + start, end - start);
        SGBiquadRun(&bass->shelf, &bass->shelfState[1], 1, right + start, end - start);
    }
}

#pragma mark - the equalizer

struct SGDSPEqualizer {
    SGBiquad bands[15];
    SGBiquadState states[2][15];
};

SGDSPEqualizer *SGDSPEqualizerCreate(const SGBiquad bands[15]) {
    SGDSPEqualizer *equalizer = calloc(1, sizeof *equalizer);
    if (equalizer) SGDSPEqualizerSet(equalizer, bands);
    return equalizer;
}

void SGDSPEqualizerSet(SGDSPEqualizer *equalizer, const SGBiquad bands[15]) {
    memcpy(equalizer->bands, bands, sizeof equalizer->bands);
}

void SGDSPEqualizerRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPEqualizer *equalizer = state;
    SGBiquadRun(equalizer->bands, equalizer->states[0], 15, left, frames);
    SGBiquadRun(equalizer->bands, equalizer->states[1], 15, right, frames);
}

#pragma mark - ViPER DDC

struct SGDSPCascade {
    SGBiquad *sections;
    SGBiquadState *states[2];
    int count;
};

SGDSPCascade *SGDSPCascadeCreate(SGBiquad *sections, int count) {
    SGDSPCascade *cascade = calloc(1, sizeof *cascade);
    if (!cascade) {
        free(sections);
        return NULL;
    }
    cascade->sections = sections;
    cascade->count = count;
    cascade->states[0] = calloc(count ? count : 1, sizeof(SGBiquadState));
    cascade->states[1] = calloc(count ? count : 1, sizeof(SGBiquadState));
    if (!cascade->states[0] || !cascade->states[1]) {
        SGDSPCascadeFree(cascade);
        return NULL;
    }
    return cascade;
}

void SGDSPCascadeRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPCascade *cascade = state;
    SGBiquadRun(cascade->sections, cascade->states[0], cascade->count, left, frames);
    SGBiquadRun(cascade->sections, cascade->states[1], cascade->count, right, frames);
}

void SGDSPCascadeFree(void *state) {
    SGDSPCascade *cascade = state;
    if (!cascade) return;
    free(cascade->sections);
    free(cascade->states[0]);
    free(cascade->states[1]);
    free(cascade);
}

#pragma mark - stereo widening

struct SGDSPWide {
    double side;
    SGBiquad highs;
    SGBiquadState highsState;
};

SGDSPWide *SGDSPWideCreate(double rate, double levelPercent) {
    SGDSPWide *wide = calloc(1, sizeof *wide);
    if (!wide) return NULL;
    wide->highs = SGBiquadHighPass(rate, 150, M_SQRT1_2);
    SGDSPWideSet(wide, levelPercent);
    return wide;
}

void SGDSPWideSet(SGDSPWide *wide, double levelPercent) {
    wide->side = fmax(0, levelPercent) / 50;
}

void SGDSPWideRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPWide *wide = state;
    double extra = wide->side - 1;
    for (uint32_t i = 0; i < frames; i++) {
        double mid = 0.5 * ((double)left[i] + right[i]), side = 0.5 * ((double)left[i] - right[i]);
        // Narrowing scales the whole side; widening adds to it over 150 Hz only, so the bass stays centred.
        double highs = SGBiquadTick(&wide->highs, &wide->highsState, side);
        side = extra > 0 ? side + extra * highs : side * wide->side;
        left[i] = (float)(mid + side);
        right[i] = (float)(mid - side);
    }
}
