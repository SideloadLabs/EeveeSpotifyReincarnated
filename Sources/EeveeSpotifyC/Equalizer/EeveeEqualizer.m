// what Swift calls (include/EeveeEqualizer.h). the sliders and the correction are kept here and designed again
// for the music's output rate whenever any of them changes, then handed to the render thread (Equalizer.m).
#import "EeveeEqualizer.h"
#import "Equalizer.h"
#import "../SpeedPitch/SpeedPitchPrivate.h"

_Static_assert(EeveeEqualizerBandCount == kEqualizerBands && EeveeEqualizerMaxCorrection == kEqualizerMaxCorrection, "one size");

static BOOL sg_on, sg_set;
static double sg_gains[kEqualizerBands];
static EqualizerFilter sg_correction[kEqualizerMaxCorrection];
static int sg_correctionCount;
static double sg_rate;      // 0 until the music's output starts

static void publish(void) {
    if (sg_rate <= 0) return;
    static const double flat[kEqualizerBands];
    EqualizerDesign design;
    EqualizerDesignFor(sg_rate, sg_on ? sg_gains : flat, sg_correction, sg_on ? sg_correctionCount : 0, &design);
    EqualizerPublish(&design);
}

double EeveeEqualizerFrequency(NSInteger band) {
    return band >= 0 && band < kEqualizerBands ? kEqualizerFrequencies[band] : 0;
}

void EeveeEqualizerSet(BOOL on, const double *gains) {
    double next[kEqualizerBands];
    for (int i = 0; i < kEqualizerBands; i++) {
        next[i] = isfinite(gains[i]) ? fmax(-kEqualizerGainLimit, fmin(kEqualizerGainLimit, gains[i])) : 0;
    }
    if (sg_set && on == sg_on && memcmp(next, sg_gains, sizeof next) == 0) return;
    if (!sg_set || on != sg_on) SPLog(@"equalizer %@", on ? @"on" : @"off");
    sg_set = YES;
    sg_on = on;
    memcpy(sg_gains, next, sizeof next);
    publish();
}

void EeveeEqualizerSetCorrection(const EeveeEqualizerFilter *kinds, const double *frequencies, const double *gains, const double *qs,
                                 NSInteger count) {
    EqualizerFilter next[kEqualizerMaxCorrection] = {0};
    int filters = (int)MAX(0, MIN(count, kEqualizerMaxCorrection));
    for (int i = 0; i < filters; i++) {
        EqualizerFilterType type = kinds[i] == EeveeEqualizerFilterLowShelf ? EqualizerLowShelf
                                   : kinds[i] == EeveeEqualizerFilterHighShelf ? EqualizerHighShelf : EqualizerPeak;
        next[i] = (EqualizerFilter){type, frequencies[i], gains[i], qs[i]};
    }
    BOOL same = filters == sg_correctionCount;
    for (int i = 0; same && i < filters; i++) {
        same = next[i].type == sg_correction[i].type && next[i].frequency == sg_correction[i].frequency
               && next[i].gain == sg_correction[i].gain && next[i].q == sg_correction[i].q;
    }
    if (same) return;
    memcpy(sg_correction, next, sizeof next);
    sg_correctionCount = filters;
    SPLog(@"equalizer: a correction of %d filters", filters);
    publish();
}

void EeveeEqualizerFollowOutput(double rate) {
    if (rate <= 0 || rate == sg_rate) return;
    sg_rate = rate;
    publish();
    SPLog(@"equalizer: the music's output plays at %.0f Hz", rate);
}

double EeveeEqualizerCurve(const double *gains, NSInteger count, double *frequencies, double *decibels, double *correction) {
    EqualizerDesign design;
    EqualizerDesignFor(48000, gains, sg_correction, sg_correctionCount, &design);
    for (NSInteger n = 0; n < count; n++) {
        frequencies[n] = count > 1 ? 20 * pow(1000, (double)n / (count - 1)) : 1000;
        decibels[n] = EqualizerResponse(&design, 0, kEqualizerBands, frequencies[n]);
        correction[n] = EqualizerResponse(&design, kEqualizerBands, design.count - kEqualizerBands, frequencies[n]);
    }
    return 20 * log10(design.gain);
}
