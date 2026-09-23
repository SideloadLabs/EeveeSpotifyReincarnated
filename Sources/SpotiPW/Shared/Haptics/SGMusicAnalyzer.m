#import <limits.h>
#import <math.h>
#import <string.h>
#import "SGMusicAnalyzer.h"

static const double kHopSeconds = 0.0058;      // 256 frames at 44.1 kHz
static const double kAverageSeconds = 1.0;     // what a hit is measured against
static const double kLowCutoff = 110, kHighCutoff = 2000, kMidLowCutoff = 250;
static const double kWarmupSeconds = 0.12;
static const float kFloorDb = -62;             // quieter than this is silence
static const float kPeakFallDbPerSecond = 0.5;

// How far over its average a band's energy has to go to hit, how far under it to hit again, how much it
// has to have risen over the last SGMusicAttackHops (a swell rises too slowly), the rest after a hit,
// the dB over the threshold that makes a tap as strong as it gets, how quiet the band may be and still
// hit, and the level a band is called loud at even when it has not been louder lately. The energy a
// band is judged by is the mean of its last `windowHops`, which for the bass has to span a cycle of a
// 40 Hz note (25 ms), or the note's own ripple reads as hits. `midRatio` is how far over its own average
// the middle of the sound (250 Hz to 2 kHz, over the bass that fills the whole) has to go at the same
// time: a snare or a clap lifts it, a hi-hat hardly does.
typedef struct {
    float ratio, rearm, attackDb;
    double restSeconds;
    float rangeDb, floorDb, loudDb;
    int windowHops;
    float midRatio;
} BandTuning;
static const BandTuning kKickTuning = {1.6f, 1.05f, 3, 0.1, 9, -42, -16, 4, 0};
static const BandTuning kSnapTuning = {2.2f, 1.0f, 6, 0.18, 9, -52, -26, 2, 1.6f};
// A hit keeps rising for at most this many hops before it is taken at its highest. Longer finds no
// more hits (a 172 BPM track gave 3.2 taps a second at 2, 3 and 5) and only makes every tap later.
static const int kMaxRisingHops = 3;
// Quieter than the band's loud level by this much, a hit is as weak as a tap gets.
static const float kLoudRangeDb = 24;
// A hit this much louder than the last one is taken even while the band rests, once this long has passed:
// a soft rise just before a big one would otherwise hold the big one back.
static const float kLouderRatio = 4;
static const double kLouderAfterSeconds = 0.05;
// A snap this near a kick is felt as the same hit.
static const double kSnapAfterKickSeconds = 0.06;

static const float kLevelMax = 0.35f;
static const float kLevelRangeDb = 15;
static const double kBassAttackSeconds = 0.01, kBassReleaseSeconds = 0.15, kBrightnessSeconds = 0.2;
static const int kLevelEveryHops = 3;

static inline float clamp01(float value) {
    return value < 0 ? 0 : value > 1 ? 1 : value;
}

static inline float decibels(double energy) {
    return (float)(10 * log10(energy + 1e-12));
}

// RBJ's cookbook, Q 0.707; two in a row make 24 dB an octave.
static void setBiquad(SGMusicBiquad *filter, double sampleRate, double cutoff, int highPass) {
    double w = 2 * M_PI * cutoff / sampleRate;
    double cosw = cos(w), alpha = sin(w) / (2 * M_SQRT1_2);
    double a0 = 1 + alpha;
    double b1 = highPass ? -(1 + cosw) : 1 - cosw;
    double b0 = highPass ? (1 + cosw) / 2 : (1 - cosw) / 2;
    filter->b0 = b0 / a0;
    filter->b1 = b1 / a0;
    filter->b2 = b0 / a0;
    filter->a1 = -2 * cosw / a0;
    filter->a2 = (1 - alpha) / a0;
    filter->z1 = filter->z2 = 0;
}

static inline double runBiquad(SGMusicBiquad *filter, double x) {
    double y = filter->b0 * x + filter->z1;
    filter->z1 = filter->b1 * x - filter->a1 * y + filter->z2;
    filter->z2 = filter->b2 * x - filter->a2 * y;
    return y;
}

static void resetBand(SGMusicBand *band) {
    memset(band, 0, sizeof(*band));
    band->peakDb = kFloorDb;
    for (int i = 0; i < SGMusicAttackHops; i++) band->recentDb[i] = kFloorDb;
    band->armed = 1;
}

// A band is loud at its recent peak, or at the tuning's loud level when it has been quieter than that.
static inline float loudDbOf(const SGMusicBand *band, const BandTuning *tuning) {
    return band->peakDb > tuning->loudDb ? band->peakDb : tuning->loudDb;
}

void SGMusicAnalyzerReset(SGMusicAnalyzer *analyzer, double sampleRate, double ticksPerSecond) {
    memset(analyzer, 0, sizeof(*analyzer));
    analyzer->sampleRate = sampleRate;
    analyzer->ticksPerSecond = ticksPerSecond;
    analyzer->hopFrames = (int)lround(sampleRate * kHopSeconds);
    if (analyzer->hopFrames < 64) analyzer->hopFrames = 64;
    int hops = (int)lround(kAverageSeconds * sampleRate / analyzer->hopFrames);
    analyzer->historyHops = hops < 8 ? 8 : hops > SGMusicHistoryLength ? SGMusicHistoryLength : hops;
    for (int i = 0; i < 2; i++) {
        setBiquad(&analyzer->lowPass[i], sampleRate, kLowCutoff, 0);
        setBiquad(&analyzer->highPass[i], sampleRate, kHighCutoff, 1);
    }
    setBiquad(&analyzer->midPass[0], sampleRate, kMidLowCutoff, 1);
    setBiquad(&analyzer->midPass[1], sampleRate, kHighCutoff, 0);
    resetBand(&analyzer->kick);
    resetBand(&analyzer->snap);
    resetBand(&analyzer->mid);
    analyzer->sinceKick = 1 << 20;
}

static double hopDuration(const SGMusicAnalyzer *analyzer) {
    return analyzer->hopFrames / analyzer->sampleRate;
}

// Moves a band on by one hop's energy: the energy of its last `windowHops` hops, and the average of the
// last second before this hop in `average`.
static float track(SGMusicAnalyzer *analyzer, SGMusicBand *band, int windowHops, double energy, double *average) {
    band->window[band->windowNext] = (float)energy;
    band->windowNext = (band->windowNext + 1) % SGMusicWindowHops;
    double sum = 0;
    for (int i = 1; i <= windowHops; i++) sum += band->window[(band->windowNext - i + SGMusicWindowHops) % SGMusicWindowHops];
    float instant = (float)(sum / windowHops);
    *average = band->count ? band->sum / band->count : instant;

    if (band->count == analyzer->historyHops) band->sum -= band->history[band->next];
    else band->count++;
    band->history[band->next] = (float)energy;
    band->sum += energy;
    if (band->sum < 0) band->sum = 0;
    band->next = (band->next + 1) % analyzer->historyHops;
    return instant;
}

// Takes one hop's energy; returns 1 and fills `event` when a hit that was rising has peaked.
static int listen(SGMusicAnalyzer *analyzer, SGMusicBand *band, const BandTuning *tuning, double energy,
                  uint64_t time, float brightness, float midRatio, SGMusicEvent *event) {
    double hop = hopDuration(analyzer);
    double average;
    float instant = track(analyzer, band, tuning->windowHops, energy, &average);

    float db = decibels(instant);
    band->peakDb = fmax(db, band->peakDb - kPeakFallDbPerSecond * hop);
    if (band->peakDb < kFloorDb) band->peakDb = kFloorDb;
    float attack = db - band->recentDb[band->recentNext];
    band->recentDb[band->recentNext] = db;
    band->recentNext = (band->recentNext + 1) % SGMusicAttackHops;
    if (band->rest > 0) band->rest--;
    if (band->sinceHit < INT_MAX) band->sinceHit++;

    int fired = 0;
    float ratio = average > 0 ? (float)(instant / average) : 0;
    if (band->pending) {
        if (ratio > band->pendingRatio) {
            band->pendingRatio = ratio;
            band->pendingEnergy = instant;
            band->pendingDb = db;
            band->pendingBright = brightness;
        }
        if (instant < band->lastInstant || band->pending >= kMaxRisingHops) {
            float over = 10 * log10(band->pendingRatio / tuning->ratio);
            float strength = clamp01(over / tuning->rangeDb);
            float loud = clamp01((band->pendingDb - (loudDbOf(band, tuning) - kLoudRangeDb)) / kLoudRangeDb);
            event->hostTime = band->pendingTime;
            event->intensity = (0.45f + 0.55f * strength) * (0.3f + 0.7f * loud);
            event->sharpness = band->pendingBright;
            band->lastHit = band->pendingEnergy;
            band->sinceHit = 0;
            band->pending = 0;
            band->armed = 0;
            band->rest = (int)ceil(tuning->restSeconds / hop);
            fired = 1;
        } else {
            band->pending++;
        }
    } else {
        if (!band->armed && instant < tuning->rearm * average) band->armed = 1;
        int warm = band->count * hop >= kWarmupSeconds;
        int free = (band->armed && !band->rest)
            || (instant > kLouderRatio * band->lastHit && band->sinceHit * hop >= kLouderAfterSeconds);
        if (warm && free && db > tuning->floorDb && ratio > tuning->ratio && attack > tuning->attackDb && instant > band->lastInstant
            && midRatio >= tuning->midRatio) {
            band->pending = 1;
            band->pendingRatio = ratio;
            band->pendingEnergy = instant;
            band->pendingDb = db;
            band->pendingBright = brightness;
            // The window crosses the threshold about when half of it holds the hit, so the hit began half a
            // window back; a haptic lands a touch after its sound rather than before.
            band->pendingTime = time - (uint64_t)(0.5 * tuning->windowHops * hop * analyzer->ticksPerSecond);
        }
    }
    band->lastInstant = instant;
    return fired;
}

static void endHop(SGMusicAnalyzer *analyzer, SGMusicEmit emit, void *context) {
    double n = analyzer->hopFrames;
    double low = analyzer->lowSum / n, high = analyzer->highSum / n, full = analyzer->fullSum / n;
    analyzer->lowSum = analyzer->highSum = analyzer->fullSum = 0;
    double hop = hopDuration(analyzer);
    uint64_t time = analyzer->hopTime;

    // Brightness: how much of the sound is over 2 kHz, where 0.25 of the energy is already very bright.
    float share = full > 1e-12 ? (float)(high / full) : 0;
    float bright = clamp01(share / 0.25f);
    analyzer->brightness += (bright - analyzer->brightness) * (1 - exp(-hop / kBrightnessSeconds));

    double midAverage;
    float midInstant = track(analyzer, &analyzer->mid, kSnapTuning.windowHops, analyzer->midSum / n, &midAverage);
    float midRatio = midAverage > 0 ? (float)(midInstant / midAverage) : 0;
    analyzer->midSum = 0;

    SGMusicEvent event;
    analyzer->sinceKick++;
    if (listen(analyzer, &analyzer->kick, &kKickTuning, low, time, bright, midRatio, &event)) {
        event.kind = SGMusicEventKick;
        event.sharpness = 0.15f + 0.3f * event.sharpness;
        analyzer->sinceKick = 0;
        emit(&event, context);
    }
    if (listen(analyzer, &analyzer->snap, &kSnapTuning, high, time, bright, midRatio, &event)) {
        if (analyzer->sinceKick * hop > kSnapAfterKickSeconds) {
            event.kind = SGMusicEventSnare;
            event.intensity *= 0.8f;
            event.sharpness = 0.55f + 0.4f * event.sharpness;
            emit(&event, context);
        }
    }

    double coefficient = low > analyzer->bassEnvelope ? kBassAttackSeconds : kBassReleaseSeconds;
    analyzer->bassEnvelope += (low - analyzer->bassEnvelope) * (1 - exp(-hop / coefficient));
    if (--analyzer->levelCountdown <= 0) {
        analyzer->levelCountdown = kLevelEveryHops;
        float db = decibels(analyzer->bassEnvelope);
        float loud = loudDbOf(&analyzer->kick, &kKickTuning);
        float level = decibels(full) < kFloorDb ? 0 : clamp01((db - (loud - kLevelRangeDb)) / kLevelRangeDb);
        SGMusicEvent rumble = {
            .kind = SGMusicEventLevel,
            .hostTime = time,
            .intensity = level * level * kLevelMax,
            .sharpness = 0.1f + 0.25f * (float)analyzer->brightness,
        };
        emit(&rumble, context);
    }
}

void SGMusicAnalyzerProcess(SGMusicAnalyzer *analyzer, const float *mono, uint32_t frames, uint64_t hostTime,
                             SGMusicEmit emit, void *context) {
    if (analyzer->sampleRate <= 0) return;
    double ticksPerFrame = analyzer->ticksPerSecond / analyzer->sampleRate;
    for (uint32_t i = 0; i < frames; i++) {
        if (analyzer->hopFilled == 0) analyzer->hopTime = hostTime + (uint64_t)(i * ticksPerFrame);
        double x = mono[i] + 1e-18;
        double low = runBiquad(&analyzer->lowPass[1], runBiquad(&analyzer->lowPass[0], x));
        double high = runBiquad(&analyzer->highPass[1], runBiquad(&analyzer->highPass[0], x));
        double mid = runBiquad(&analyzer->midPass[1], runBiquad(&analyzer->midPass[0], x));
        analyzer->lowSum += low * low;
        analyzer->highSum += high * high;
        analyzer->midSum += mid * mid;
        analyzer->fullSum += x * x;
        if (++analyzer->hopFilled == analyzer->hopFrames) {
            analyzer->hopFilled = 0;
            endHop(analyzer, emit, context);
        }
    }
}
