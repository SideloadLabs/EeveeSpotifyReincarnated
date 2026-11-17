// a 15 band equalizer on Spotify's sound, after speed and pitch (Equalizer/README.md). main thread only.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

enum { EeveeEqualizerBandCount = 15 };

// a band's centre in Hz, lowest first.
double EeveeEqualizerFrequency(NSInteger band);

// on, the sound goes through `gains`, EeveeEqualizerBandCount of them in dB, each within ±12; off, it fades back
// to as it was. applies at once, or as soon as Spotify's output starts.
void EeveeEqualizerSet(BOOL on, const double *gains);

// what `gains` do, for drawing: `count` points from 20 Hz to 20 kHz into `frequencies` and `decibels`. returns
// how far the sound is turned down so the boosts can't clip, in dB (0 or less).
double EeveeEqualizerCurve(const double *gains, NSInteger count, double *frequencies, double *decibels);

NS_ASSUME_NONNULL_END
