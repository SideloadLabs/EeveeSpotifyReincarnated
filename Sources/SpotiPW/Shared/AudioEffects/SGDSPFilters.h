// The effects' filter maths: biquads and their designs, the gain a design makes, ViPER DDC and GraphicEQ text
// read, and minimum phase responses made from a magnitude. SGBiquadTick and SGBiquadRun are the render
// thread's; the rest allocates.
#import <stdbool.h>
#import <stddef.h>
#import <stdint.h>

// y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2, run as transposed direct form II in double.
typedef struct {
    double b0, b1, b2, a1, a2;
} SGBiquad;

typedef struct {
    double s1, s2;
} SGBiquadState;

static inline double SGBiquadTick(const SGBiquad *q, SGBiquadState *s, double x) {
    double y = q->b0 * x + s->s1;
    s->s1 = q->b1 * x - q->a1 * y + s->s2;
    s->s2 = q->b2 * x - q->a2 * y;
    return y;
}

// A lane through `count` sections in turn, in place.
void SGBiquadRun(const SGBiquad *sections, SGBiquadState *states, int count, float *lane, uint32_t frames);

SGBiquad SGBiquadPeak(double rate, double frequency, double q, double gainDB);
SGBiquad SGBiquadLowShelf(double rate, double frequency, double q, double gainDB);
SGBiquad SGBiquadLowPass(double rate, double frequency, double q);
SGBiquad SGBiquadHighPass(double rate, double frequency, double q);
SGBiquad SGBiquadAllPass(double rate, double frequency, double q);
double SGBiquadGainDB(const SGBiquad *sections, int count, double rate, double frequency);

// Peaking bands at `frequencies`, their own gains solved so that the whole cascade meets each band's gain
// at its centre. A band at or over 0.46 of the rate stays flat.
void SGDSPDesignEqualizer(double rate, const double frequencies[15], const double gains[15], SGBiquad bands[15]);

// `count` frequencies log spaced from 20 Hz to 20 kHz.
void SGDSPLogFrequencies(int count, double *frequencies);

// A smooth curve through points on a log frequency axis (monotone cubic, flat past the ends), for drawing.
double SGDSPSmoothCurve(const double *frequencies, const double *values, int count, double frequency);

#pragma mark - ViPER DDC

// A .vdc file: biquads for 44.1 and for 48 kHz, five numbers each (b0, b1, b2 and the two feedback
// coefficients, whose sign is read from the file: the one that makes every filter stable).
typedef struct {
    SGBiquad *sections[2];
    int counts[2];
} SGDSPDDC;

bool SGDSPParseDDC(const char *text, SGDSPDDC *ddc, char *error, size_t errorSize);
void SGDSPFreeDDC(SGDSPDDC *ddc);
// The file's filters at `rate`: its own at 44.1 or 48 kHz, otherwise the nearer set moved to the rate by
// a bilinear frequency warp. malloc'd, `count` of them.
SGBiquad *SGDSPDDCFor(const SGDSPDDC *ddc, double rate, int *count);

#pragma mark - GraphicEQ and minimum phase

// AutoEq's "GraphicEQ: 20 -1.2; 21 -1.1; ...": its points, sorted by frequency.
typedef struct {
    double *frequencies, *gains;
    int count;
} SGDSPGraphicCurve;

bool SGDSPParseGraphicEq(const char *text, SGDSPGraphicCurve *curve);
void SGDSPFreeGraphicEq(SGDSPGraphicCurve *curve);
// dB at `frequency`: straight between points on a log frequency axis, flat past the ends.
double SGDSPGraphicEqAt(const SGDSPGraphicCurve *curve, double frequency);
// The curve as a minimum phase FIR at `rate`, `*taps` long (malloc'd); NULL when out of memory.
float *SGDSPDesignGraphicEq(const SGDSPGraphicCurve *curve, double rate, int *taps);

// The minimum phase impulse response of a magnitude given at the n / 2 + 1 bins of an n = 2^log2n point
// spectrum, its first `taps` samples into `impulse`. false when out of memory.
bool SGDSPMinimumPhase(const double *magnitude, int log2n, float *impulse, int taps);
