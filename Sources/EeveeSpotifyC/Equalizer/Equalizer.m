// Equalizer.h says what this is; README.md how the bands are designed and why.
#include "Equalizer.h"
#include <math.h>
#include <stdatomic.h>
#include <string.h>

const double kEqualizerFrequencies[kEqualizerBands] = {25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000};
const double kEqualizerGainLimit = 12;

#pragma mark - design

// a band's width at half its gain, in octaves: wider than the 2/3 octave between bands, so neighbours add up flat.
static const double kBandwidth = 0.9;
// a band's own gain can go past its slider's, to make up for its neighbours.
static const double kOwnLimit = 30;
// the curve is met at the bands and halfway between them, those counting half.
static const double kHalfwayWeight = 0.5;
static const int kRefinements = 3;
// past this fraction of the rate a band can't be shaped; it's left out.
static const double kHighest = 0.45;

enum { kPoints = 2 * kEqualizerBands - 1, kScan = 160 };

static bool usable(double rate, int index) {
    return kEqualizerFrequencies[index] < kHighest * rate;
}

static const EqualizerBiquad kPassThrough = {1, 0, 0, 0, 0};

// RBJ's cookbook filter at ω `w`, with `alpha` from its bandwidth or Q.
static EqualizerBiquad rbj(EqualizerFilterType type, double w, double alpha, double gainDB) {
    double c = cos(w), a = pow(10, fmax(-30, fmin(30, gainDB)) / 40);
    double b0, b1, b2, a0, a1, a2, root = 2 * sqrt(a) * alpha;
    switch (type) {
        case EqualizerLowShelf:
            b0 = a * ((a + 1) - (a - 1) * c + root), b1 = 2 * a * ((a - 1) - (a + 1) * c), b2 = a * ((a + 1) - (a - 1) * c - root);
            a0 = (a + 1) + (a - 1) * c + root, a1 = -2 * ((a - 1) + (a + 1) * c), a2 = (a + 1) + (a - 1) * c - root;
            break;
        case EqualizerHighShelf:
            b0 = a * ((a + 1) + (a - 1) * c + root), b1 = -2 * a * ((a - 1) + (a + 1) * c), b2 = a * ((a + 1) + (a - 1) * c - root);
            a0 = (a + 1) - (a - 1) * c + root, a1 = 2 * ((a - 1) - (a + 1) * c), a2 = (a + 1) - (a - 1) * c - root;
            break;
        default:
            b0 = 1 + alpha * a, b1 = -2 * c, b2 = 1 - alpha * a;
            a0 = 1 + alpha / a, a1 = -2 * c, a2 = 1 - alpha / a;
            break;
    }
    return (EqualizerBiquad){b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

// a band: a peak with its bandwidth prewarped, so the 16 kHz band is as wide as the others (with a plain Q it
// shrinks to a quarter octave).
static EqualizerBiquad band(double rate, int index, double gainDB) {
    if (!usable(rate, index)) return kPassThrough;
    double w = 2 * M_PI * kEqualizerFrequencies[index] / rate;
    return rbj(EqualizerPeak, w, sin(w) * sinh(M_LN2 / 2 * kBandwidth * w / sin(w)), gainDB);
}

// a correction's filter with a plain Q, as AutoEq fits them and Equalizer APO runs them.
static EqualizerBiquad filter(double rate, EqualizerFilter f) {
    if (!(f.frequency > 0 && f.frequency < kHighest * rate) || !(f.q > 0) || !isfinite(f.gain)) return kPassThrough;
    double w = 2 * M_PI * f.frequency / rate;
    return rbj(f.type, w, sin(w) / (2 * f.q), f.gain);
}

// cos and sin of ω and 2ω, for responses at one frequency.
typedef struct {
    double c1, s1, c2, s2;
} Phase;

static Phase phaseAt(double rate, double frequency) {
    double w = 2 * M_PI * frequency / rate;
    return (Phase){cos(w), sin(w), cos(2 * w), sin(2 * w)};
}

static double biquadDB(const EqualizerBiquad *q, Phase p) {
    double nr = q->b0 + q->b1 * p.c1 + q->b2 * p.c2, ni = -(q->b1 * p.s1 + q->b2 * p.s2);
    double dr = 1 + q->a1 * p.c1 + q->a2 * p.c2, di = -(q->a1 * p.s1 + q->a2 * p.s2);
    return 10 * log10(fmax(nr * nr + ni * ni, 1e-30) / fmax(dr * dr + di * di, 1e-30));
}

static double cascadeDB(const EqualizerBiquad *sections, int count, Phase p) {
    double total = 0;
    for (int i = 0; i < count; i++) total += biquadDB(&sections[i], p);
    return total;
}

// the bands' gains by weighted least squares (Välimäki and Liski's accurate cascade graphic EQ): each band's
// effect taken as linear in its gain, then corrected against the real cascade.
typedef struct {
    double rate;                                        // 0 while unused
    int count;                                          // points under kHighest, from the lowest
    Phase phases[kPoints];
    double weights[kPoints];
    double interaction[kPoints][kEqualizerBands];       // a band's dB at a point, per dB of its gain
    double factor[kEqualizerBands][kEqualizerBands];    // Cholesky factor of the normal equations, lower
} Solver;

// the output's rate and the page's curve take turns while a slider moves.
static Solver sg_solvers[2];
static int sg_lastSolver;

// the points: the bands' centres at even indexes, halfway between two (on a log scale) at odd ones.
static double pointFrequency(int k) {
    int i = k / 2;
    return k % 2 ? sqrt(kEqualizerFrequencies[i] * kEqualizerFrequencies[i + 1]) : kEqualizerFrequencies[i];
}

static void prepare(Solver *solver, double rate) {
    memset(solver, 0, sizeof *solver);
    solver->rate = rate;
    for (int k = 0; k < kPoints && pointFrequency(k) < kHighest * rate; k++) {
        solver->phases[k] = phaseAt(rate, pointFrequency(k));
        solver->weights[k] = k % 2 ? kHalfwayWeight : 1;
        solver->count = k + 1;
    }
    const double prototype = 12;
    for (int i = 0; i < kEqualizerBands; i++) {
        if (!usable(rate, i)) continue;
        EqualizerBiquad q = band(rate, i, prototype);
        for (int k = 0; k < solver->count; k++) solver->interaction[k][i] = biquadDB(&q, solver->phases[k]) / prototype;
    }
    // a little on the diagonal, so a band that was left out solves to 0.
    double normal[kEqualizerBands][kEqualizerBands];
    for (int i = 0; i < kEqualizerBands; i++) {
        for (int j = 0; j <= i; j++) {
            double sum = i == j ? 1e-6 : 0;
            for (int k = 0; k < solver->count; k++) sum += solver->weights[k] * solver->interaction[k][i] * solver->interaction[k][j];
            normal[i][j] = sum;
        }
    }
    for (int i = 0; i < kEqualizerBands; i++) {
        for (int j = 0; j <= i; j++) {
            double sum = normal[i][j];
            for (int k = 0; k < j; k++) sum -= solver->factor[i][k] * solver->factor[j][k];
            solver->factor[i][j] = i == j ? sqrt(fmax(sum, 1e-12)) : sum / solver->factor[j][j];
        }
    }
}

static const Solver *solverFor(double rate) {
    for (int s = 0; s < 2; s++) {
        if (sg_solvers[s].rate == rate) {
            sg_lastSolver = s;
            return &sg_solvers[s];
        }
    }
    sg_lastSolver = 1 - sg_lastSolver;
    prepare(&sg_solvers[sg_lastSolver], rate);
    return &sg_solvers[sg_lastSolver];
}

// the gains that best move the curve by `error` at the points.
static void solve(const Solver *solver, const double error[kPoints], double gains[kEqualizerBands]) {
    double y[kEqualizerBands];
    for (int i = 0; i < kEqualizerBands; i++) {
        double sum = 0;
        for (int k = 0; k < solver->count; k++) sum += solver->weights[k] * solver->interaction[k][i] * error[k];
        for (int j = 0; j < i; j++) sum -= solver->factor[i][j] * y[j];
        y[i] = sum / solver->factor[i][i];
    }
    for (int i = kEqualizerBands - 1; i >= 0; i--) {
        double sum = y[i];
        for (int j = i + 1; j < kEqualizerBands; j++) sum -= solver->factor[j][i] * gains[j];
        gains[i] = sum / solver->factor[i][i];
    }
}

void EqualizerDesignFor(double rate, const double gains[kEqualizerBands], const EqualizerFilter *correction, int correctionCount,
                        EqualizerDesign *design) {
    double sliders[kEqualizerBands], own[kEqualizerBands] = {0};
    bool flat = true;
    for (int i = 0; i < kEqualizerBands; i++) {
        sliders[i] = isfinite(gains[i]) ? fmax(-kEqualizerGainLimit, fmin(kEqualizerGainLimit, gains[i])) : 0;
        flat = flat && sliders[i] == 0;
    }
    EqualizerBiquad *sections = design->sections;
    if (!flat) {
        const Solver *solver = solverFor(rate);
        // the curve the sliders ask for: theirs at the centres, halfway between two the mean of them.
        double wanted[kPoints], error[kPoints], change[kEqualizerBands];
        for (int k = 0; k < solver->count; k++) wanted[k] = k % 2 ? (sliders[k / 2] + sliders[k / 2 + 1]) / 2 : sliders[k / 2];
        solve(solver, wanted, own);
        for (int pass = 0; pass < kRefinements; pass++) {
            for (int i = 0; i < kEqualizerBands; i++) sections[i] = band(rate, i, own[i]);
            for (int k = 0; k < solver->count; k++) error[k] = wanted[k] - cascadeDB(sections, kEqualizerBands, solver->phases[k]);
            solve(solver, error, change);
            for (int i = 0; i < kEqualizerBands; i++) own[i] = fmax(-kOwnLimit, fmin(kOwnLimit, own[i] + change[i]));
        }
    }
    // flat, the bands are 0 dB peaks, not left out: a fade to or from them moves each band's gain alone.
    for (int i = 0; i < kEqualizerBands; i++) sections[i] = band(rate, i, own[i]);
    int filters = correction && correctionCount > 0 ? (correctionCount < kEqualizerMaxCorrection ? correctionCount : kEqualizerMaxCorrection) : 0;
    for (int i = 0; i < kEqualizerMaxCorrection; i++) sections[kEqualizerBands + i] = i < filters ? filter(rate, correction[i]) : kPassThrough;
    design->count = kEqualizerBands + filters;
    design->rate = rate;
    design->flat = flat && filters == 0;
    design->gain = 1;
    if (design->flat) return;
    // the loudest the cascade makes anything, up to just under Nyquist, is taken back off (the correction's
    // own preamp aside).
    double loudest = 0;
    for (int n = 0; n < kScan; n++) {
        loudest = fmax(loudest, cascadeDB(sections, design->count, phaseAt(rate, 20 * pow(0.49 * rate / 20, (double)n / (kScan - 1)))));
    }
    for (int i = 0; i < kEqualizerBands; i++) {
        if (usable(rate, i)) loudest = fmax(loudest, cascadeDB(sections, design->count, phaseAt(rate, kEqualizerFrequencies[i])));
    }
    for (int i = 0; i < filters; i++) {
        double f = correction[i].frequency;
        if (f > 0 && f < kHighest * rate) loudest = fmax(loudest, cascadeDB(sections, design->count, phaseAt(rate, f)));
    }
    design->gain = pow(10, -loudest / 20);
}

double EqualizerResponse(const EqualizerDesign *design, int first, int count, double frequency) {
    if (first < 0 || count <= 0 || first + count > kEqualizerSections) return 0;
    return cascadeDB(design->sections + first, count, phaseAt(design->rate, frequency));
}

#pragma mark - handing designs over

// a triple buffer: each side swaps its own slot for the shared one, marked fresh going in. neither waits.
enum { kFresh = 4 };

static EqualizerDesign sg_slots[3];
static atomic_uint sg_shared = 1;
static unsigned sg_back = 2;        // the config side's

void EqualizerPublish(const EqualizerDesign *design) {
    sg_slots[sg_back] = *design;
    sg_back = atomic_exchange_explicit(&sg_shared, sg_back | kFresh, memory_order_acq_rel) & 3;
}

#pragma mark - the render thread

// a new design is faded to over this long, its coefficients stepped every kStep frames.
static const double kFadeSeconds = 0.03;
enum { kStep = 32 };

static atomic_flag sg_busy = ATOMIC_FLAG_INIT;
static atomic_uint_fast64_t sg_ran, sg_otherRate, sg_refused, sg_passedOver, sg_cleared;

static void tally(atomic_uint_fast64_t *counter) {
    atomic_fetch_add_explicit(counter, 1, memory_order_relaxed);
}

static struct {
    unsigned front;                 // the slot taken last
    bool ready;                     // a design was taken
    const void *owner;
    uint32_t channels;
    double rate;                    // the design's
    EqualizerBiquad from[kEqualizerSections], to[kEqualizerSections], now[kEqualizerSections];
    int sections;                   // run now: the design's, or while fading the more of the two
    int target;                     // the design's
    double gainFrom, gainTo, gainNow;
    uint32_t at, length;            // frames into the fade, at == length once it's over
    bool flat;                      // the design faded to is flat
    bool idle;                      // flat and faded: nothing runs, the filters are empty
    double state[kEqualizerMaxChannels][kEqualizerSections][2];
} sg_run;

static const EqualizerDesign *take(void) {
    if (!(atomic_load_explicit(&sg_shared, memory_order_relaxed) & kFresh)) return NULL;
    sg_run.front = atomic_exchange_explicit(&sg_shared, sg_run.front, memory_order_acq_rel) & 3;
    return &sg_slots[sg_run.front];
}

static void empty(void) {
    memset(sg_run.state, 0, sizeof sg_run.state);
}

// the fade over at once, the filters empty: for another stream, or one coming back from silence.
static void startClean(void) {
    memcpy(sg_run.now, sg_run.to, sizeof sg_run.now);
    sg_run.gainNow = sg_run.gainTo;
    sg_run.at = sg_run.length;
    sg_run.sections = sg_run.target;
    sg_run.idle = sg_run.flat;
    empty();
}

static void adopt(const EqualizerDesign *design, bool fade) {
    memcpy(sg_run.to, design->sections, sizeof sg_run.to);
    sg_run.target = design->count;
    sg_run.gainTo = design->gain;
    sg_run.flat = design->flat;
    sg_run.rate = design->rate;
    if (!fade || (sg_run.idle && design->flat)) {
        startClean();
        return;
    }
    memcpy(sg_run.from, sg_run.now, sizeof sg_run.from);
    // sections coming into use start empty: they passed the sound through, and kept what they held last.
    for (; sg_run.sections < sg_run.target; sg_run.sections++) {
        for (int c = 0; c < kEqualizerMaxChannels; c++) memset(sg_run.state[c][sg_run.sections], 0, sizeof sg_run.state[c][0]);
    }
    sg_run.gainFrom = sg_run.gainNow;
    sg_run.at = 0;
    sg_run.length = (uint32_t)ceil(kFadeSeconds * design->rate / kStep) * kStep;
    sg_run.idle = false;
}

static EqualizerBiquad mix(const EqualizerBiquad *a, const EqualizerBiquad *b, double t) {
    return (EqualizerBiquad){a->b0 + (b->b0 - a->b0) * t, a->b1 + (b->b1 - a->b1) * t, a->b2 + (b->b2 - a->b2) * t,
                             a->a1 + (b->a1 - a->a1) * t, a->a2 + (b->a2 - a->a2) * t};
}

// the coefficients step along the fade (a line between stable biquads stays stable); the gain moves every frame.
static void process(float *const *lanes, uint32_t channels, uint32_t frames) {
    for (uint32_t start = 0; start < frames; start += kStep) {
        uint32_t count = frames - start < kStep ? frames - start : kStep;
        double gainStart = sg_run.gainNow;
        if (sg_run.at < sg_run.length) {
            sg_run.at = sg_run.at + count < sg_run.length ? sg_run.at + count : sg_run.length;
            if (sg_run.at == sg_run.length) {
                memcpy(sg_run.now, sg_run.to, sizeof sg_run.now);
                sg_run.gainNow = sg_run.gainTo;
                sg_run.sections = sg_run.target;
            } else {
                double t = (double)sg_run.at / sg_run.length;
                for (int i = 0; i < sg_run.sections; i++) sg_run.now[i] = mix(&sg_run.from[i], &sg_run.to[i], t);
                sg_run.gainNow = sg_run.gainFrom + (sg_run.gainTo - sg_run.gainFrom) * t;
            }
        }
        double gainStep = (sg_run.gainNow - gainStart) / count;
        for (uint32_t c = 0; c < channels; c++) {
            float *lane = lanes[c] + start;
            double x[kStep];
            for (uint32_t n = 0; n < count; n++) x[n] = lane[n];
            for (int i = 0; i < sg_run.sections; i++) {
                EqualizerBiquad q = sg_run.now[i];
                double s1 = sg_run.state[c][i][0], s2 = sg_run.state[c][i][1];
                for (uint32_t n = 0; n < count; n++) {
                    double y = q.b0 * x[n] + s1;
                    s1 = q.b1 * x[n] - q.a1 * y + s2;
                    s2 = q.b2 * x[n] - q.a2 * y;
                    x[n] = y;
                }
                sg_run.state[c][i][0] = s1;
                sg_run.state[c][i][1] = s2;
            }
            for (uint32_t n = 0; n < count; n++) lane[n] = (float)(x[n] * (gainStart + gainStep * (n + 1)));
        }
    }
    // a NaN let in would stay in the filters for good.
    for (uint32_t c = 0; c < channels; c++) {
        for (int i = 0; i < sg_run.sections; i++) {
            if (!isfinite(sg_run.state[c][i][0]) || !isfinite(sg_run.state[c][i][1])) {
                empty();
                tally(&sg_cleared);
                return;
            }
        }
    }
}

static bool run(const void *owner, double rate, float *const *lanes, uint32_t channels, uint32_t frames, bool silent) {
    if (channels < 1 || channels > kEqualizerMaxChannels) return false;
    bool another = owner != sg_run.owner || channels != sg_run.channels;
    const EqualizerDesign *fresh = take();
    if (fresh) {
        adopt(fresh, sg_run.ready && !another && fresh->rate == sg_run.rate);
        sg_run.ready = true;
    } else if (another && sg_run.ready) {
        startClean();
    }
    sg_run.owner = owner;
    sg_run.channels = channels;
    // a design for another rate passes the sound as it is until the one for this rate comes.
    if (!sg_run.ready || sg_run.idle) return false;
    if (sg_run.rate != rate) {
        tally(&sg_otherRate);
        return false;
    }
    if (silent) {
        startClean();
        return false;
    }
    process(lanes, channels, frames);
    tally(&sg_ran);
    if (sg_run.flat && sg_run.at == sg_run.length) {
        sg_run.idle = true;
        empty();
    }
    return true;
}

bool EqualizerWanted(void) {
    return (atomic_load_explicit(&sg_shared, memory_order_relaxed) & kFresh) || (sg_run.ready && !sg_run.idle);
}

bool EqualizerRun(const void *owner, double rate, float *const *lanes, uint32_t channels, uint32_t frames, bool silent) {
    if (atomic_flag_test_and_set_explicit(&sg_busy, memory_order_acquire)) {
        tally(&sg_passedOver);
        return false;
    }
    bool changed = run(owner, rate, lanes, channels, frames, silent);
    atomic_flag_clear_explicit(&sg_busy, memory_order_release);
    return changed;
}

void EqualizerCountRefused(void) {
    tally(&sg_refused);
}

EqualizerStats EqualizerReadStats(void) {
    return (EqualizerStats){
        atomic_load_explicit(&sg_ran, memory_order_relaxed), atomic_load_explicit(&sg_otherRate, memory_order_relaxed),
        atomic_load_explicit(&sg_refused, memory_order_relaxed), atomic_load_explicit(&sg_passedOver, memory_order_relaxed),
        atomic_load_explicit(&sg_cleared, memory_order_relaxed),
    };
}
