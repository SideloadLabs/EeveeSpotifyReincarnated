// a 15 band equalizer on Spotify's sound, after speed and pitch, with a headphone correction under it
// (Equalizer/README.md). main thread only.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

enum { EeveeEqualizerBandCount = 15, EeveeEqualizerMaxCorrection = 16 };

// a correction filter's kind, as AutoEq's parametric files name them: PK, LSC and HSC.
typedef NS_ENUM(NSInteger, EeveeEqualizerFilter) {
    EeveeEqualizerFilterPeak,
    EeveeEqualizerFilterLowShelf,
    EeveeEqualizerFilterHighShelf,
};

// where the equalizer's log lines go, set once at launch; any thread but the render thread calls it.
void EeveeEqualizerSetLog(void (^log)(NSString *message));

// a band's centre in Hz, lowest first.
double EeveeEqualizerFrequency(NSInteger band);

// on, the sound goes through `gains`, EeveeEqualizerBandCount of them in dB, each within ±12, and the correction;
// off, it fades back to as it was. with `preventClipping` a limiter catches the peaks the boosts would push over,
// without it they can clip. applies at once, or as soon as Spotify's output starts.
void EeveeEqualizerSet(BOOL on, const double *gains, BOOL preventClipping);

// the headphone correction under the bands, `count` filters (0 for none; past EeveeEqualizerMaxCorrection the rest
// are left out), each a kind, a frequency in Hz, a gain in dB and a Q. it only plays while the equalizer is on.
void EeveeEqualizerSetCorrection(const EeveeEqualizerFilter *kinds, const double *frequencies, const double *gains, const double *qs,
                                 NSInteger count);

// what `gains` and the correction do, for drawing: `count` points from 20 Hz to 20 kHz into `frequencies`, the
// bands' response into `decibels` and the correction's into `correction`. returns the most the two together boost
// anything, in dB (0 or more).
double EeveeEqualizerCurve(const double *gains, NSInteger count, double *frequencies, double *decibels, double *correction);

NS_ASSUME_NONNULL_END
