// what Swift calls (include/EeveeEqualizer.h). the sliders and the correction are kept here and designed again
// for the music's output rate whenever any of them changes, then handed to the render thread (Equalizer.m).
#import "EeveeEqualizer.h"
#import "../Shared/LogSink.h"
#import "Equalizer.h"

_Static_assert(EeveeEqualizerBandCount == kEqualizerBands && EeveeEqualizerMaxCorrection == kEqualizerMaxCorrection
               && (int)EeveeEqualizerFilterHighShelf == (int)EqualizerHighShelf, "one size");

// a change settles this long before the report line, so a dragged slider makes one line, not one per step.
static const double kReportAfter = 3;

static BOOL sg_on, sg_set, sg_preventClipping = YES;
static double sg_gains[kEqualizerBands];
static EqualizerFilter sg_correction[kEqualizerMaxCorrection];
static int sg_correctionCount;
static double sg_rate;          // 0 until the music's output starts
static double sg_peak;          // dB, the highest point of the design handed over last

void EeveeEqualizerSetLog(void (^log)(NSString *message)) {
    EeveeLogSinkSet(EeveeLogEqualizer, log);
}

// the equalizer's log lines, through the sink Swift sets (EeveeEqualizerSetLog). never on the render thread.
static void EQLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void EQLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    EeveeLogSinkWrite(EeveeLogEqualizer, format, args);
    va_end(args);
}

// what it's set to, and what the render thread did with it since the last report. "for another rate" climbing
// means the design didn't follow the output; "refused" that the hardware's format isn't one the in-place path
// reads (the speed & pitch lines have the format). "limited" counts buffers the limiter turned down; the trim is
// its slow turn-down at the moment of the report.
static void report(void) {
    static EqualizerStats last;
    EqualizerStats now = EqualizerReadStats();
    NSMutableArray<NSString *> *bands = [NSMutableArray arrayWithCapacity:kEqualizerBands];
    for (int i = 0; i < kEqualizerBands; i++) [bands addObject:[NSString stringWithFormat:@"%+g", sg_gains[i]]];
    NSString *rate = sg_rate > 0 ? [NSString stringWithFormat:@"at %.0f Hz", sg_rate] : @"waiting for Spotify's output";
    // the peak is known once a design is made, for the output's rate.
    NSString *level = sg_rate <= 0          ? (sg_preventClipping ? @"clip prevention on" : @"clip prevention off")
                      : sg_preventClipping ? [NSString stringWithFormat:@"limiter on, peaks at +%.2f dB, trim %.2f dB", sg_peak, now.trim]
                                           : [NSString stringWithFormat:@"clip prevention off, peaks at +%.2f dB", sg_peak];
    EQLog(@"%@ %@, bands %@, correction %d filters, %@; since the last report %llu buffers run, %llu limited, %llu for "
          @"another rate, %llu refused, %llu passed over, %llu cleared after a fault",
          sg_on ? @"on" : @"off", rate, [bands componentsJoinedByString:@" "], sg_correctionCount, level,
          now.run - last.run, now.limited - last.limited, now.otherRate - last.otherRate, now.refused - last.refused,
          now.passedOver - last.passedOver, now.cleared - last.cleared);
    last = now;
}

static void scheduleReport(void) {
    static NSUInteger generation;
    NSUInteger mine = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReportAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == generation) report();
    });
}

static void publish(void) {
    scheduleReport();
    if (sg_rate <= 0) return;
    static const double flat[kEqualizerBands];
    EqualizerDesign design;
    EqualizerDesignFor(sg_rate, sg_on ? sg_gains : flat, sg_correction, sg_on ? sg_correctionCount : 0, &design);
    sg_peak = design.peak;
    design.limit = sg_preventClipping;
    EqualizerPublish(&design);
}

double EeveeEqualizerFrequency(NSInteger band) {
    return band >= 0 && band < kEqualizerBands ? kEqualizerFrequencies[band] : 0;
}

void EeveeEqualizerSet(BOOL on, const double *gains, BOOL preventClipping) {
    double next[kEqualizerBands];
    for (int i = 0; i < kEqualizerBands; i++) {
        next[i] = isfinite(gains[i]) ? fmax(-kEqualizerGainLimit, fmin(kEqualizerGainLimit, gains[i])) : 0;
    }
    preventClipping = !!preventClipping;
    if (sg_set && on == sg_on && preventClipping == sg_preventClipping && memcmp(next, sg_gains, sizeof next) == 0) return;
    if (!sg_set || on != sg_on) EQLog(@"%@", on ? @"on" : @"off");
    // at launch only when off, it being on by default.
    if (sg_set ? preventClipping != sg_preventClipping : !preventClipping) EQLog(@"clip prevention %@", preventClipping ? @"on" : @"off");
    sg_set = YES;
    sg_on = on;
    sg_preventClipping = preventClipping;
    memcpy(sg_gains, next, sizeof next);
    publish();
}

void EeveeEqualizerSetCorrection(const EeveeEqualizerFilter *kinds, const double *frequencies, const double *gains, const double *qs,
                                 NSInteger count) {
    EqualizerFilter next[kEqualizerMaxCorrection] = {0};
    int filters = (int)MAX(0, MIN(count, kEqualizerMaxCorrection));
    for (int i = 0; i < filters; i++) {
        // the same order as EqualizerFilterType.
        EqualizerFilterType type = kinds[i] >= EeveeEqualizerFilterPeak && kinds[i] <= EeveeEqualizerFilterHighShelf ? (EqualizerFilterType)kinds[i] : EqualizerPeak;
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
    publish();
}

void EeveeEqualizerFollowOutput(double rate) {
    if (rate <= 0 || rate == sg_rate) return;
    EQLog(@"the music's output plays at %.0f Hz%@", rate, sg_rate > 0 ? [NSString stringWithFormat:@", was %.0f Hz", sg_rate] : @"");
    sg_rate = rate;
    publish();
}

double EeveeEqualizerCurve(const double *gains, NSInteger count, double *frequencies, double *decibels, double *correction) {
    EqualizerDesign design;
    EqualizerDesignFor(48000, gains, sg_correction, sg_correctionCount, &design);
    for (NSInteger n = 0; n < count; n++) {
        frequencies[n] = count > 1 ? 20 * pow(1000, (double)n / (count - 1)) : 1000;
        decibels[n] = EqualizerResponse(&design, 0, kEqualizerBands, frequencies[n]);
        correction[n] = EqualizerResponse(&design, kEqualizerBands, design.count - kEqualizerBands, frequencies[n]);
    }
    return design.peak;
}
