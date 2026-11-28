// the equalizer's core (README.md): the filters designed from the sliders and the headphone correction on the
// main thread, and run on the render thread. plain C, so it can be checked off the phone (README.md, testing).
#include <stdbool.h>
#include <stdint.h>

enum {
    kEqualizerBands = 15,
    kEqualizerMaxCorrection = 16,
    kEqualizerSections = kEqualizerBands + kEqualizerMaxCorrection,
    kEqualizerMaxChannels = 2,
};

extern const double kEqualizerFrequencies[kEqualizerBands];   // Hz, 25 ... 16000
extern const double kEqualizerGainLimit;                      // ±12 dB

typedef struct {
    double b0, b1, b2, a1, a2;
} EqualizerBiquad;

// one of a headphone correction's filters, as AutoEq's parametric files give them (RBJ's, with a Q).
typedef enum { EqualizerPeak, EqualizerLowShelf, EqualizerHighShelf } EqualizerFilterType;

typedef struct {
    EqualizerFilterType type;
    double frequency, gain, q;
} EqualizerFilter;

typedef struct {
    EqualizerBiquad sections[kEqualizerSections];  // the bands, then the correction's filters, then pass-throughs
    int count;      // sections in use
    double rate;
    double peak;    // dB, at least 0: the most the sections boost anything, the furthest the limiter's trim goes
    bool limit;     // clip prevention: the sound goes through the limiter after the sections (README.md)
    bool flat;      // every slider at 0 and no correction: the sections pass the sound as it is
} EqualizerDesign;

#pragma mark - the config side, one thread (the main one)

// the sliders' `gains` in dB, clamped to the limit, and `correction` (up to kEqualizerMaxCorrection filters,
// NULL for none) as filters at `rate`.
void EqualizerDesignFor(double rate, const double gains[kEqualizerBands], const EqualizerFilter *correction, int correctionCount,
                        EqualizerDesign *design);
// the response in dB at `frequency` of `count` sections from `first`, without the turn-down.
double EqualizerResponse(const EqualizerDesign *design, int first, int count, double frequency);
// hands a design to the render thread, which fades to it. until the first, the sound passes as it is.
void EqualizerPublish(const EqualizerDesign *design);

#pragma mark - the render thread

// whether EqualizerRun could change anything, so the caller can skip setting up its lanes.
bool EqualizerWanted(void);
// `lanes` through the published design, if it was made for `rate`. `owner` is the stream: another one starts
// the filters empty. `silent` is a buffer of silence, whose lanes are not read. returns whether they changed.
// never allocates, locks or waits; a second render thread calling at the same time is passed over.
bool EqualizerRun(const void *owner, double rate, float *const *lanes, uint32_t channels, uint32_t frames, bool silent);
// a buffer it wanted but the in-place path couldn't read: its format, its size, or its channels (over
// kEqualizerMaxChannels). counted for the log.
void EqualizerCountRefused(void);

#pragma mark - for the log, any thread

// buffers since launch: run through it, passed as they were because the design was made for another rate, refused
// for their format, passed over while another render thread had it, those whose filters went non-finite and
// were cleared, and those the limiter turned down. `trim` is the limiter's slow turn-down now, in dB.
typedef struct {
    uint64_t run, otherRate, refused, passedOver, cleared, limited;
    double trim;
} EqualizerStats;

EqualizerStats EqualizerReadStats(void);

#pragma mark - EeveeEqualizer.m

// the music's output now plays at `rate` (SpeedPitchEngine.m). main thread.
void EeveeEqualizerFollowOutput(double rate);
