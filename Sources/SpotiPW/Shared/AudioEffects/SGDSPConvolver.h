// Impulse responses of up to 4 paths through blocks of stereo, and the files they are read from. The first
// 16384 frames go in partitions of one block, so the output is ready as the block comes in; the rest in
// partitions of 8 blocks, their work spread evenly over the 8. SGDSPConvolverProcess never allocates or locks.
#import <stdbool.h>
#import <stddef.h>
#import <stdint.h>

enum { kSGDSPConvolverBlock = 1024 };
// The longest response kept, in frames at the output's rate; past it a response is faded out and cut.
enum { kSGDSPConvolverMaxFrames = 1 << 19 };

typedef struct SGDSPConvolver SGDSPConvolver;

// `paths` responses of `length` frames: 1 (each channel through it), 2 (left to left, right to right) or 4
// (left to left, left to right, right to left, right to right). NULL when out of memory.
SGDSPConvolver *SGDSPConvolverCreate(const float *const *responses, int paths, size_t length);
void SGDSPConvolverFree(SGDSPConvolver *convolver);
// A block of kSGDSPConvolverBlock frames through it, in place.
void SGDSPConvolverProcess(SGDSPConvolver *convolver, float *left, float *right);

typedef struct {
    float *responses[4];
    int paths;
    size_t length;
} SGDSPImpulse;

typedef enum {
    SGDSPImpulseOriginal,
    SGDSPImpulseTrimmed,        // the tail under -80 dB of the peak cut off
    SGDSPImpulseMinimumPhase,   // each path made minimum phase, then trimmed
} SGDSPImpulseMode;

// A WAV (.wav, .irs) or FLAC file of 1, 2 or 4 channels, resampled to `rate` and scaled so its loudest
// output channel passes as much power as it takes in.
bool SGDSPReadImpulse(const char *path, double rate, SGDSPImpulseMode mode, SGDSPImpulse *impulse, char *error, size_t errorSize);
void SGDSPFreeImpulse(SGDSPImpulse *impulse);
