#import "SGDSPFilters.h"
#import <Accelerate/Accelerate.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - biquads

void SGBiquadRun(const SGBiquad *sections, SGBiquadState *states, int count, float *lane, uint32_t frames) {
    for (int s = 0; s < count; s++) {
        SGBiquad q = sections[s];
        SGBiquadState state = states[s];
        for (uint32_t i = 0; i < frames; i++) lane[i] = (float)SGBiquadTick(&q, &state, lane[i]);
        states[s] = state;
    }
}

static SGBiquad normalized(double b0, double b1, double b2, double a0, double a1, double a2) {
    return (SGBiquad){b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

SGBiquad SGBiquadPeak(double rate, double frequency, double q, double gainDB) {
    double w = 2 * M_PI * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w), a = pow(10, gainDB / 40);
    return normalized(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a);
}

SGBiquad SGBiquadLowShelf(double rate, double frequency, double q, double gainDB) {
    double w = 2 * M_PI * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w), a = pow(10, gainDB / 40);
    double root = 2 * sqrt(a) * alpha;
    return normalized(a * ((a + 1) - (a - 1) * c + root), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - root),
                      (a + 1) + (a - 1) * c + root, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - root);
}

SGBiquad SGBiquadLowPass(double rate, double frequency, double q) {
    double w = 2 * M_PI * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w);
    return normalized((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha);
}

SGBiquad SGBiquadHighPass(double rate, double frequency, double q) {
    double w = 2 * M_PI * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w);
    return normalized((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
}

SGBiquad SGBiquadAllPass(double rate, double frequency, double q) {
    double w = 2 * M_PI * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w);
    return normalized(1 - alpha, -2 * c, 1 + alpha, 1 + alpha, -2 * c, 1 - alpha);
}

double SGBiquadGainDB(const SGBiquad *sections, int count, double rate, double frequency) {
    double w = 2 * M_PI * frequency / rate, c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    double power = 1;
    for (int i = 0; i < count; i++) {
        const SGBiquad *q = &sections[i];
        double nr = q->b0 + q->b1 * c1 + q->b2 * c2, ni = -(q->b1 * s1 + q->b2 * s2);
        double dr = 1 + q->a1 * c1 + q->a2 * c2, di = -(q->a1 * s1 + q->a2 * s2);
        power *= (nr * nr + ni * ni) / fmax(dr * dr + di * di, 1e-300);
    }
    return 10 * log10(fmax(power, 1e-30));
}

#pragma mark - the equalizer

// About two thirds of an octave wide, the bands' spacing, so neighbours overlap enough to leave no dips.
static const double kBandQ = 2.1;

static void designBands(double rate, const double frequencies[15], const double gains[15], const bool usable[15], SGBiquad bands[15]) {
    for (int i = 0; i < 15; i++) {
        bands[i] = usable[i] ? SGBiquadPeak(rate, frequencies[i], kBandQ, gains[i]) : (SGBiquad){1, 0, 0, 0, 0};
    }
}

void SGDSPDesignEqualizer(double rate, const double frequencies[15], const double gains[15], SGBiquad bands[15]) {
    double own[15];
    bool usable[15];
    for (int i = 0; i < 15; i++) {
        usable[i] = frequencies[i] < 0.46 * rate;
        own[i] = usable[i] ? gains[i] : 0;
    }
    // Each band's gain corrected by what the cascade misses at its centre, until it misses by nothing audible.
    for (int iteration = 0; iteration < 60; iteration++) {
        designBands(rate, frequencies, own, usable, bands);
        double worst = 0, missed[15] = {0};
        for (int i = 0; i < 15; i++) {
            if (!usable[i]) continue;
            missed[i] = gains[i] - SGBiquadGainDB(bands, 15, rate, frequencies[i]);
            worst = fmax(worst, fabs(missed[i]));
        }
        if (worst < 1e-4) return;
        for (int i = 0; i < 15; i++) own[i] = fmax(-30, fmin(30, own[i] + 0.9 * missed[i]));
    }
    designBands(rate, frequencies, own, usable, bands);
}

#pragma mark - curves

void SGDSPLogFrequencies(int count, double *frequencies) {
    for (int i = 0; i < count; i++) frequencies[i] = count > 1 ? 20 * pow(1000, (double)i / (count - 1)) : 1000;
}

double SGDSPSmoothCurve(const double *frequencies, const double *values, int count, double frequency) {
    if (count <= 0) return 0;
    double x = log(frequency);
    if (count == 1 || x <= log(frequencies[0])) return values[0];
    if (x >= log(frequencies[count - 1])) return values[count - 1];
    int k = 0;
    while (k < count - 2 && x > log(frequencies[k + 1])) k++;
    double x0 = log(frequencies[k]), x1 = log(frequencies[k + 1]), h = x1 - x0;
    double slope = (values[k + 1] - values[k]) / h;
    // Fritsch-Carlson tangents: no overshoot between points.
    double tangents[2];
    for (int e = 0; e < 2; e++) {
        int i = k + e;
        if (i == 0 || i == count - 1) {
            tangents[e] = slope;
            continue;
        }
        double before = (values[i] - values[i - 1]) / (log(frequencies[i]) - log(frequencies[i - 1]));
        double after = (values[i + 1] - values[i]) / (log(frequencies[i + 1]) - log(frequencies[i]));
        tangents[e] = before * after <= 0 ? 0 : 2 / (1 / before + 1 / after);
    }
    double t = (x - x0) / h, t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * values[k] + (t3 - 2 * t2 + t) * h * tangents[0] + (-2 * t3 + 3 * t2) * values[k + 1] + (t3 - t2) * h * tangents[1];
}

#pragma mark - ViPER DDC

// Every number between `from` and `to`, whatever separates them. malloc'd, NULL when there are none.
static double *numbersIn(const char *from, const char *to, int *count) {
    int capacity = 64;
    double *numbers = malloc(capacity * sizeof *numbers);
    *count = 0;
    for (const char *p = from; numbers && p < to;) {
        if (!strchr("0123456789+-.", *p)) {
            p++;
            continue;
        }
        char *end;
        double value = strtod(p, &end);
        if (end == p || end > to) {
            p++;
            continue;
        }
        p = end;
        if (*count == capacity) {
            capacity *= 2;
            double *grown = capacity <= (1 << 20) ? realloc(numbers, capacity * sizeof *numbers) : NULL;
            if (!grown) {
                free(numbers);
                return NULL;
            }
            numbers = grown;
        }
        numbers[(*count)++] = value;
    }
    if (numbers && !*count) {
        free(numbers);
        numbers = NULL;
    }
    return numbers;
}

static bool stable(double a1, double a2) {
    return isfinite(a1) && isfinite(a2) && fabs(a2) < 1 && fabs(a1) < 1 + a2;
}

static void copyError(char *error, size_t size, const char *text) {
    if (error && size) snprintf(error, size, "%s", text);
}

bool SGDSPParseDDC(const char *text, SGDSPDDC *ddc, char *error, size_t errorSize) {
    memset(ddc, 0, sizeof *ddc);
    static const char *markers[2] = {"SR_44100", "SR_48000"};
    double *numbers[2] = {NULL, NULL};
    int counts[2] = {0, 0};
    const char *end = text + strlen(text);
    bool ok = true;
    for (int s = 0; s < 2 && ok; s++) {
        const char *at = strstr(text, markers[s]);
        if (!at) {
            ok = false;
            break;
        }
        at += strlen(markers[s]);
        const char *next = strstr(at, "SR_");
        numbers[s] = numbersIn(at, next ? next : end, &counts[s]);
        ok = numbers[s] && counts[s] % 5 == 0;
    }
    if (!ok) {
        free(numbers[0]);
        free(numbers[1]);
        copyError(error, errorSize, "Not a ViPER DDC file: it has filters for SR_44100 and SR_48000, five numbers each");
        return false;
    }
    // The feedback's sign: added (y += f1 y1 + f2 y2) unless only subtracted keeps every filter stable.
    int sign = 0;
    for (int candidate = -1; candidate <= 1 && !sign; candidate += 2) {
        bool all = true;
        for (int s = 0; s < 2 && all; s++) {
            for (int i = 0; i < counts[s] && all; i += 5) all = stable(candidate * numbers[s][i + 3], candidate * numbers[s][i + 4]);
        }
        if (all) sign = candidate;
    }
    for (int s = 0; s < 2 && sign; s++) {
        ddc->counts[s] = counts[s] / 5;
        ddc->sections[s] = malloc(ddc->counts[s] * sizeof(SGBiquad));
        if (!ddc->sections[s]) {
            sign = 0;
            break;
        }
        for (int i = 0; i < ddc->counts[s]; i++) {
            const double *n = numbers[s] + i * 5;
            ddc->sections[s][i] = (SGBiquad){n[0], n[1], n[2], sign * n[3], sign * n[4]};
        }
    }
    free(numbers[0]);
    free(numbers[1]);
    if (!sign) {
        SGDSPFreeDDC(ddc);
        copyError(error, errorSize, "The DDC file's filters are not stable either way their feedback is read");
        return false;
    }
    return true;
}

void SGDSPFreeDDC(SGDSPDDC *ddc) {
    free(ddc->sections[0]);
    free(ddc->sections[1]);
    memset(ddc, 0, sizeof *ddc);
}

// v = (alpha + z^-1) / (1 + alpha z^-1) put into c0 + c1 v + c2 v^2, times (1 + alpha z^-1)^2.
static void warped(double c0, double c1, double c2, double alpha, double out[3]) {
    out[0] = c0 + c1 * alpha + c2 * alpha * alpha;
    out[1] = 2 * alpha * c0 + c1 * (1 + alpha * alpha) + 2 * alpha * c2;
    out[2] = alpha * alpha * c0 + alpha * c1 + c2;
}

SGBiquad *SGDSPDDCFor(const SGDSPDDC *ddc, double rate, int *count) {
    static const double rates[2] = {44100, 48000};
    int s = fabs(log(rate / rates[0])) < fabs(log(rate / rates[1])) ? 0 : 1;
    *count = ddc->counts[s];
    SGBiquad *sections = malloc(*count * sizeof *sections);
    if (!sections) return NULL;
    double c = rate / rates[s], alpha = (1 - c) / (1 + c);
    for (int i = 0; i < *count; i++) {
        const SGBiquad *q = &ddc->sections[s][i];
        if (fabs(rate - rates[s]) < 0.5) {
            sections[i] = *q;
            continue;
        }
        double b[3], a[3];
        warped(q->b0, q->b1, q->b2, alpha, b);
        warped(1, q->a1, q->a2, alpha, a);
        sections[i] = normalized(b[0], b[1], b[2], a[0], a[1], a[2]);
    }
    return sections;
}

#pragma mark - GraphicEQ

static int byFrequency(const void *a, const void *b) {
    double fa = ((const double *)a)[0], fb = ((const double *)b)[0];
    return fa < fb ? -1 : fa > fb;
}

bool SGDSPParseGraphicEq(const char *text, SGDSPGraphicCurve *curve) {
    memset(curve, 0, sizeof *curve);
    const char *p = text ? strchr(text, ':') : NULL;
    if (!p || strncasecmp(text, "GraphicEQ:", 10) != 0) return false;
    p++;
    int capacity = 0, count = 0;
    double *pairs = NULL;
    while (*p) {
        char *end;
        double frequency = strtod(p, &end);
        if (end == p) {
            p++;
            continue;
        }
        p = end;
        while (*p == ' ' || *p == '\t') p++;
        double gain = strtod(p, &end);
        if (end == p) break;
        p = end;
        if (!isfinite(frequency) || !isfinite(gain) || frequency < 0) continue;
        if (count == capacity) {
            capacity = capacity ? capacity * 2 : 64;
            double *grown = capacity <= (1 << 16) ? realloc(pairs, capacity * 2 * sizeof *pairs) : NULL;
            if (!grown) break;
            pairs = grown;
        }
        pairs[count * 2] = frequency;
        pairs[count * 2 + 1] = fmax(-60, fmin(30, gain));
        count++;
    }
    if (!count) {
        free(pairs);
        return false;
    }
    qsort(pairs, count, 2 * sizeof *pairs, byFrequency);
    curve->frequencies = malloc(count * sizeof(double));
    curve->gains = malloc(count * sizeof(double));
    if (!curve->frequencies || !curve->gains) {
        free(pairs);
        SGDSPFreeGraphicEq(curve);
        return false;
    }
    // A frequency given twice keeps its last gain.
    for (int i = 0; i < count; i++) {
        double frequency = fmax(pairs[i * 2], 1);
        if (curve->count && curve->frequencies[curve->count - 1] == frequency) curve->count--;
        curve->frequencies[curve->count] = frequency;
        curve->gains[curve->count] = pairs[i * 2 + 1];
        curve->count++;
    }
    free(pairs);
    return true;
}

void SGDSPFreeGraphicEq(SGDSPGraphicCurve *curve) {
    free(curve->frequencies);
    free(curve->gains);
    memset(curve, 0, sizeof *curve);
}

double SGDSPGraphicEqAt(const SGDSPGraphicCurve *curve, double frequency) {
    int n = curve->count;
    if (frequency <= curve->frequencies[0]) return curve->gains[0];
    if (frequency >= curve->frequencies[n - 1]) return curve->gains[n - 1];
    int low = 0, high = n - 1;
    while (high - low > 1) {
        int middle = (low + high) / 2;
        if (curve->frequencies[middle] <= frequency) low = middle;
        else high = middle;
    }
    double t = log(frequency / curve->frequencies[low]) / log(curve->frequencies[high] / curve->frequencies[low]);
    return curve->gains[low] + t * (curve->gains[high] - curve->gains[low]);
}

float *SGDSPDesignGraphicEq(const SGDSPGraphicCurve *curve, double rate, int *taps) {
    // 85 ms or more at any rate: fine enough for the lowest octave's points.
    int length = 4096;
    while (length < rate * 0.08) length *= 2;
    int log2n = 0;
    while ((1 << log2n) < length * 4) log2n++;
    int n = 1 << log2n;
    double *magnitude = malloc((n / 2 + 1) * sizeof *magnitude);
    float *impulse = malloc(length * sizeof *impulse);
    if (!magnitude || !impulse) {
        free(magnitude);
        free(impulse);
        return NULL;
    }
    for (int k = 0; k <= n / 2; k++) {
        double frequency = k ? k * rate / n : curve->frequencies[0];
        magnitude[k] = pow(10, SGDSPGraphicEqAt(curve, frequency) / 20);
    }
    bool ok = SGDSPMinimumPhase(magnitude, log2n, impulse, length);
    free(magnitude);
    if (!ok) {
        free(impulse);
        return NULL;
    }
    // The last eighth faded out, so the cut leaves no ripple.
    int fade = length / 8;
    for (int i = 0; i < fade; i++) impulse[length - fade + i] *= (float)(0.5 + 0.5 * cos(M_PI * (i + 1) / fade));
    *taps = length;
    return impulse;
}

#pragma mark - minimum phase

bool SGDSPMinimumPhase(const double *magnitude, int log2n, float *impulse, int taps) {
    int n = 1 << log2n, half = n / 2;
    FFTSetupD setup = vDSP_create_fftsetupD(log2n, kFFTRadix2);
    double *re = malloc(half * sizeof *re), *im = malloc(half * sizeof *im), *time = malloc(n * sizeof *time);
    bool ok = setup && re && im && time;
    if (ok) {
        // The real cepstrum: the log magnitude's inverse transform.
        DSPDoubleSplitComplex split = {re, im};
        re[0] = log(fmax(magnitude[0], 1e-9));
        im[0] = log(fmax(magnitude[half], 1e-9));
        for (int k = 1; k < half; k++) {
            re[k] = log(fmax(magnitude[k], 1e-9));
            im[k] = 0;
        }
        vDSP_fft_zripD(setup, &split, 1, log2n, kFFTDirection_Inverse);
        vDSP_ztocD(&split, 1, (DSPDoubleComplex *)time, 2, half);
        // Folded onto its causal half, then back: the log spectrum of the minimum phase response.
        double scale = 1.0 / n;
        time[0] *= scale;
        time[half] *= scale;
        for (int i = 1; i < half; i++) time[i] *= 2 * scale;
        for (int i = half + 1; i < n; i++) time[i] = 0;
        vDSP_ctozD((DSPDoubleComplex *)time, 2, &split, 1, half);
        vDSP_fft_zripD(setup, &split, 1, log2n, kFFTDirection_Forward);
        re[0] = exp(re[0] / 2);
        im[0] = exp(im[0] / 2);
        for (int k = 1; k < half; k++) {
            double m = exp(re[k] / 2), phase = im[k] / 2;
            re[k] = m * cos(phase);
            im[k] = m * sin(phase);
        }
        vDSP_fft_zripD(setup, &split, 1, log2n, kFFTDirection_Inverse);
        vDSP_ztocD(&split, 1, (DSPDoubleComplex *)time, 2, half);
        for (int i = 0; i < taps && i < n; i++) impulse[i] = (float)(time[i] * scale);
        for (int i = n; i < taps; i++) impulse[i] = 0;
    }
    if (setup) vDSP_destroy_fftsetupD(setup);
    free(re);
    free(im);
    free(time);
    return ok;
}
