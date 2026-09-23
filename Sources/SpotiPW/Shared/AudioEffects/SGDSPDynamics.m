#import "SGDSPEffects.h"
#import <Accelerate/Accelerate.h>
#import <math.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - the compander

enum { kBands = 7, kCrossovers = kBands - 1, kCompanderStep = 16 };
static const double kMostDB = 12, kQuietDB = -70;

struct SGDSPCompander {
    double rate;
    SGBiquad lows[kCrossovers], highs[kCrossovers], passes[kCrossovers];
    SGBiquadState lowStates[2][kCrossovers][2], highStates[2][kCrossovers][2], passStates[2][15];
    double amount[kBands], fast[kBands], slow[kBands], gain[kBands];
    double attack, release, settle;
    bool primed;
    float bands[kBands][2][kSGDSPEffectMaxFrames];
};

SGDSPCompander *SGDSPCompanderCreate(double rate, double timeConstant, const double frequencies[7], const double gains[7]) {
    SGDSPCompander *compander = calloc(1, sizeof *compander);
    if (!compander) return NULL;
    compander->rate = rate;
    for (int k = 0; k < kCrossovers; k++) {
        double crossover = sqrt(frequencies[k] * frequencies[k + 1]);
        compander->lows[k] = SGBiquadLowPass(rate, crossover, M_SQRT1_2);
        compander->highs[k] = SGBiquadHighPass(rate, crossover, M_SQRT1_2);
        compander->passes[k] = SGBiquadAllPass(rate, crossover, M_SQRT1_2);
    }
    for (int b = 0; b < kBands; b++) compander->gain[b] = 1;
    SGDSPCompanderSet(compander, timeConstant, gains);
    return compander;
}

void SGDSPCompanderSet(SGDSPCompander *compander, double timeConstant, const double gains[7]) {
    double rate = compander->rate, time = fmax(timeConstant, 0.01);
    compander->attack = 1 - exp(-1 / (0.1 * time * rate));
    compander->release = 1 - exp(-1 / (time * rate));
    compander->settle = 1 - exp(-1 / (10 * time * rate));
    for (int b = 0; b < kBands; b++) compander->amount[b] = 0.6 * gains[b];
}

// Each channel into seven bands: a Linkwitz-Riley low pass off what is left at each crossover, the rest
// passing on. A band then goes through the allpasses of the crossovers above it, so the sum is flat.
static void split(SGDSPCompander *compander, int channel, const float *input, uint32_t frames) {
    float *rest = compander->bands[kBands - 1][channel];
    memcpy(rest, input, frames * sizeof(float));
    int pass = 0;
    for (int k = 0; k < kCrossovers; k++) {
        float *band = compander->bands[k][channel];
        memcpy(band, rest, frames * sizeof(float));
        for (int twice = 0; twice < 2; twice++) {
            SGBiquadRun(&compander->lows[k], &compander->lowStates[channel][k][twice], 1, band, frames);
            SGBiquadRun(&compander->highs[k], &compander->highStates[channel][k][twice], 1, rest, frames);
        }
    }
    for (int k = 0; k < kCrossovers - 1; k++) {
        for (int above = k + 1; above < kCrossovers; above++) {
            SGBiquadRun(&compander->passes[above], &compander->passStates[channel][pass++], 1, compander->bands[k][channel], frames);
        }
    }
}

void SGDSPCompanderRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPCompander *compander = state;
    split(compander, 0, left, frames);
    split(compander, 1, right, frames);
    memset(left, 0, frames * sizeof(float));
    memset(right, 0, frames * sizeof(float));
    for (int b = 0; b < kBands; b++) {
        float *l = compander->bands[b][0], *r = compander->bands[b][1];
        for (uint32_t start = 0; start < frames; start += kCompanderStep) {
            uint32_t end = start + kCompanderStep < frames ? start + kCompanderStep : frames;
            double fast = compander->fast[b], slow = compander->slow[b];
            for (uint32_t i = start; i < end; i++) {
                double power = 0.5 * ((double)l[i] * l[i] + (double)r[i] * r[i]);
                fast += (power - fast) * (power > fast ? compander->attack : compander->release);
                slow += (power - slow) * compander->settle;
            }
            // The running level starts where the band is, not from silence.
            if (!compander->primed) slow = fast;
            compander->fast[b] = fast;
            compander->slow[b] = slow;
            double fastDB = 10 * log10(fast + 1e-12), slowDB = 10 * log10(slow + 1e-12);
            double gainDB = fmax(-kMostDB, fmin(kMostDB, -compander->amount[b] * (fastDB - slowDB)));
            if (fastDB < kQuietDB && gainDB > 0) gainDB = 0;
            double from = compander->gain[b], to = pow(10, gainDB / 20), step = (to - from) / (end - start);
            for (uint32_t i = start; i < end; i++) {
                float g = (float)(from + step * (i - start + 1));
                left[i] += l[i] * g;
                right[i] += r[i] * g;
            }
            compander->gain[b] = to;
        }
    }
    compander->primed = true;
}

#pragma mark - the tube

enum { kTaps = 64, kHistory = kTaps - 1, kPhaseHistory = kTaps / 2 - 1 };
static const float kBias = 0.25f;

// The filter of both the doubling and the halving: a low pass at a quarter of the doubled rate, minimum
// phase, so it delays by a few samples rather than half its length. Made once, the same at every rate.
static float sg_halfband[kTaps];

static double besselI0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 30; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

static void designHalfband(void) {
    enum { kLength = 63, kLog2n = 12 };
    double linear[kLength], sum = 0, beta = 7;
    for (int n = 0; n < kLength; n++) {
        int m = n - kLength / 2;
        double sinc = m ? sin(M_PI * m / 2) / (M_PI * m) : 0.5;
        double x = (double)m / (kLength / 2);
        linear[n] = sinc * besselI0(beta * sqrt(fmax(0, 1 - x * x))) / besselI0(beta);
        sum += linear[n];
    }
    double magnitude[(1 << kLog2n) / 2 + 1];
    for (int k = 0; k <= (1 << kLog2n) / 2; k++) {
        double re = 0, im = 0, w = 2 * M_PI * k / (1 << kLog2n);
        for (int n = 0; n < kLength; n++) {
            re += linear[n] / sum * cos(w * n);
            im -= linear[n] / sum * sin(w * n);
        }
        magnitude[k] = hypot(re, im);
    }
    SGDSPMinimumPhase(magnitude, kLog2n, sg_halfband, kTaps);
}

struct SGDSPTube {
    float drive, normalize, offset;
    double dcCoefficient, dcIn[2], dcOut[2];
    float input[2][kPhaseHistory + kSGDSPEffectMaxFrames];
    float doubled[2][kHistory + 2 * kSGDSPEffectMaxFrames];
    float scratch[2 * kSGDSPEffectMaxFrames];
};

SGDSPTube *SGDSPTubeCreate(double rate, double driveDB) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, designHalfband);
    SGDSPTube *tube = calloc(1, sizeof *tube);
    if (!tube) return NULL;
    tube->dcCoefficient = exp(-2 * M_PI * 10 / rate);
    SGDSPTubeSet(tube, driveDB);
    return tube;
}

// A full scale sound at 0 dB of drive reaches half way up the curve; the output is scaled back by the
// curve's slope at rest, so quiet sounds keep their level.
void SGDSPTubeSet(SGDSPTube *tube, double driveDB) {
    double drive = 0.5 * pow(10, driveDB / 20), slope = 1 - tanh(kBias) * tanh(kBias);
    tube->drive = (float)drive;
    tube->normalize = (float)(1 / (drive * slope));
    tube->offset = tanhf(kBias);
}

static void shape(SGDSPTube *tube, int channel, float *lane, uint32_t frames) {
    float *input = tube->input[channel], *doubled = tube->doubled[channel], *curve = tube->scratch;
    memcpy(input + kPhaseHistory, lane, frames * sizeof(float));
    // Doubled: each output phase is every other tap over the input, times two for the zeros stuffed between.
    for (uint32_t n = 0; n < frames; n++) {
        const float *x = input + kPhaseHistory + n;
        float even = 0, odd = 0;
        for (int k = 0; k < kTaps / 2; k++) {
            even += sg_halfband[2 * k] * x[-k];
            odd += sg_halfband[2 * k + 1] * x[-k];
        }
        curve[2 * n] = 2 * even * tube->drive + kBias;
        curve[2 * n + 1] = 2 * odd * tube->drive + kBias;
    }
    int count = (int)(2 * frames);
    vvtanhf(curve, curve, &count);
    float *shaped = doubled + kHistory;
    for (int i = 0; i < count; i++) shaped[i] = (curve[i] - tube->offset) * tube->normalize;
    // Halved: the same filter, every other output.
    double in = tube->dcIn[channel], out = tube->dcOut[channel];
    for (uint32_t n = 0; n < frames; n++) {
        const float *u = shaped + 2 * n;
        float sum = 0;
        for (int k = 0; k < kTaps; k++) sum += sg_halfband[k] * u[-k];
        out = sum - in + tube->dcCoefficient * out;
        in = sum;
        lane[n] = (float)out;
    }
    tube->dcIn[channel] = in;
    tube->dcOut[channel] = out;
    memmove(input, input + frames, kPhaseHistory * sizeof(float));
    memmove(doubled, doubled + count, kHistory * sizeof(float));
}

void SGDSPTubeRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPTube *tube = state;
    shape(tube, 0, left, frames);
    shape(tube, 1, right, frames);
}
