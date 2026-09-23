// The effects SGDSPEngine chains (SGDSPTone.m, SGDSPDynamics.m, SGDSPCrossfeed.m, SGDSPReverb.m,
// SGDSPLiveprog.m; the convolver is SGDSPConvolver.h). Create, Set and Free are never the render thread's, and
// a Set changes a running state, so it is called under the engine's lock. Run never allocates, locks or logs.
#import <stdbool.h>
#import <stddef.h>
#import <stdint.h>
#import "SGDSPFilters.h"

typedef void (*SGDSPRun)(void *state, float *left, float *right, uint32_t frames);
typedef void (*SGDSPFree)(void *state);

// Every Run takes up to this many frames.
enum { kSGDSPEffectMaxFrames = 1024 };

// A low shelf at 100 Hz lifting by up to `maxGainDB`, less while the lows are loud: never past -3 dBFS
// where the headroom allows none.
typedef struct SGDSPBass SGDSPBass;
SGDSPBass *SGDSPBassCreate(double rate, double maxGainDB);
void SGDSPBassSet(SGDSPBass *bass, double maxGainDB);
void SGDSPBassRun(void *bass, float *left, float *right, uint32_t frames);

typedef struct SGDSPEqualizer SGDSPEqualizer;
// `bands` from SGDSPDesignEqualizer.
SGDSPEqualizer *SGDSPEqualizerCreate(const SGBiquad bands[15]);
void SGDSPEqualizerSet(SGDSPEqualizer *equalizer, const SGBiquad bands[15]);
void SGDSPEqualizerRun(void *equalizer, float *left, float *right, uint32_t frames);

// A cascade of biquads on both channels (ViPER DDC's filters); takes `sections`, which Free frees.
typedef struct SGDSPCascade SGDSPCascade;
SGDSPCascade *SGDSPCascadeCreate(SGBiquad *sections, int count);
void SGDSPCascadeRun(void *cascade, float *left, float *right, uint32_t frames);
void SGDSPCascadeFree(void *cascade);

// Mid and side, the side scaled by level / 50 (50 leaves it as it is); widening leaves the side's lows alone.
typedef struct SGDSPWide SGDSPWide;
SGDSPWide *SGDSPWideCreate(double rate, double levelPercent);
void SGDSPWideSet(SGDSPWide *wide, double levelPercent);
void SGDSPWideRun(void *wide, float *left, float *right, uint32_t frames);

// Seven Linkwitz-Riley bands around `frequencies`, each band's loud and quiet moments pulled towards its own
// running level by gains[i] (1: 60% less dynamics) or pushed away from it (-1: 60% more), by 12 dB at most.
// `timeConstant` is the release; the attack a tenth of it, the running level ten times it.
typedef struct SGDSPCompander SGDSPCompander;
SGDSPCompander *SGDSPCompanderCreate(double rate, double timeConstant, const double frequencies[7], const double gains[7]);
void SGDSPCompanderSet(SGDSPCompander *compander, double timeConstant, const double gains[7]);
void SGDSPCompanderRun(void *compander, float *left, float *right, uint32_t frames);

// An asymmetric soft clip at twice the rate: even harmonics first, the level kept for quiet sounds.
typedef struct SGDSPTube SGDSPTube;
SGDSPTube *SGDSPTubeCreate(double rate, double driveDB);
void SGDSPTubeSet(SGDSPTube *tube, double driveDB);
void SGDSPTubeRun(void *tube, float *left, float *right, uint32_t frames);

// preset: SGDSPCrossfeedPresetCount of them, lightest first.
enum { SGDSPCrossfeedPresetCount = 3 };
typedef struct SGDSPCrossfeed SGDSPCrossfeed;
SGDSPCrossfeed *SGDSPCrossfeedCreate(double rate, int preset);
void SGDSPCrossfeedSet(SGDSPCrossfeed *crossfeed, int preset);
void SGDSPCrossfeedRun(void *crossfeed, float *left, float *right, uint32_t frames);

// preset: an index of SGDSPReverbPresetCount. NULL when the unit could not be made.
enum { SGDSPReverbPresetCount = 9 };
typedef struct SGDSPReverb SGDSPReverb;
SGDSPReverb *SGDSPReverbCreate(double rate, int preset);
void SGDSPReverbSet(SGDSPReverb *reverb, int preset);
void SGDSPReverbRun(void *reverb, float *left, float *right, uint32_t frames);
void SGDSPReverbFree(void *reverb);

// A script in JSFX's shape: a desc: line and sliderN: defaults, then @init, @slider, @block and @sample
// sections, spl0 and spl1 the samples, srate the rate. NULL and why, with the file's line, when it does
// not compile.
typedef struct SGDSPLiveprog SGDSPLiveprog;
SGDSPLiveprog *SGDSPLiveprogCreate(const char *script, double rate, char *error, size_t errorSize);
void SGDSPLiveprogRun(void *liveprog, float *left, float *right, uint32_t frames);
void SGDSPLiveprogFree(void *liveprog);
