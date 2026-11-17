// what Swift calls (include/EeveeEqualizer.h). the sliders are kept here and designed again for the music's
// output rate whenever either changes, then handed to the render thread (Equalizer.m).
#import "EeveeEqualizer.h"
#import "Equalizer.h"
#import "../SpeedPitch/SpeedPitchPrivate.h"

_Static_assert(EeveeEqualizerBandCount == kEqualizerBands, "one band count");

static BOOL sg_on, sg_set;
static double sg_gains[kEqualizerBands];
static double sg_rate;      // 0 until the music's output starts

static void publish(void) {
    if (sg_rate <= 0) return;
    static const double flat[kEqualizerBands];
    EqualizerDesign design;
    EqualizerDesignFor(sg_rate, sg_on ? sg_gains : flat, &design);
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

void EeveeEqualizerFollowOutput(double rate) {
    if (rate <= 0 || rate == sg_rate) return;
    sg_rate = rate;
    publish();
    SPLog(@"equalizer: the music's output plays at %.0f Hz", rate);
}

double EeveeEqualizerCurve(const double *gains, NSInteger count, double *frequencies, double *decibels) {
    EqualizerDesign design;
    EqualizerDesignFor(48000, gains, &design);
    for (NSInteger n = 0; n < count; n++) {
        frequencies[n] = count > 1 ? 20 * pow(1000, (double)n / (count - 1)) : 1000;
        decibels[n] = EqualizerResponse(&design, frequencies[n]);
    }
    return 20 * log10(design.gain);
}
