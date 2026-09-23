// Audio effects on Spotify's sound: the mod's own engine (SGDSPEngine), run on every buffer Spotify's output
// unit finishes, before the speaker. Either look: it draws nothing on Spotify's screens. Mod Settings >
// Audio effects is its page.
//
// What it offers: output gain and limiter, a multiband compander, dynamic bass boost, a 15 band equalizer,
// the Graphic EQ (any curve, as AutoEq writes them), the convolver (impulse responses), ViPER DDC files,
// Liveprog (EEL2 scripts), reverb, stereo widening, crossfeed and analog modelling. Each effect has a switch
// and its own values, kept under its own keys.
//
// Unlike the mod's other switches these apply as they change, not at launch: every setter below stores the
// value and hands the effect it belongs to to the engine, which re-reads that effect's keys off the main
// thread. The engine is made the first time Spotify starts its output with the master switch on.
//
// Threading: everything here is main thread, except SGDSPStatus and SGDSPError, which any thread may call.
#import <Foundation/Foundation.h>

#pragma mark - keys

// The master switch, off until asked for. Off, Spotify's sound is left exactly as it was.
#define SGKeyDSP                        @"spotifyglass.dsp"

// Output control, applied while the master switch is on.
#define SGKeyDSPPostGain                @"spotifyglass.dsp.postGain"            // dB
#define SGKeyDSPLimiterThreshold        @"spotifyglass.dsp.limiterThreshold"    // dB
#define SGKeyDSPLimiterRelease          @"spotifyglass.dsp.limiterRelease"      // ms

#define SGKeyDSPCompander               @"spotifyglass.dsp.compander"
#define SGKeyDSPCompanderTime           @"spotifyglass.dsp.compander.time"      // s, the release
// Seven amounts, "a;a;a;a;a;a;a", one per band at SGDSPCompanderFrequencies, each within SGDSPCompanderGainLimit:
// over 0 evens the band's loud and quiet moments out, under 0 pulls them apart.
#define SGKeyDSPCompanderGains          @"spotifyglass.dsp.compander.gains"

#define SGKeyDSPBass                    @"spotifyglass.dsp.bass"
#define SGKeyDSPBassGain                @"spotifyglass.dsp.bass.gain"           // dB, the most it lifts

#define SGKeyDSPEqualizer               @"spotifyglass.dsp.eq"
// Fifteen gains in dB, "g;g;...;g", at SGDSPEqualizerFrequencies, each within SGDSPEqualizerGainLimit.
#define SGKeyDSPEqualizerGains          @"spotifyglass.dsp.eq.gains"

// The Graphic EQ, in AutoEq's GraphicEQ format: "GraphicEQ: 20 -1.2; 21 -1.1; ...".
#define SGKeyDSPGraphicEq               @"spotifyglass.dsp.geq"
#define SGKeyDSPGraphicEqNodes          @"spotifyglass.dsp.geq.nodes"

// File effects name a file in their library (SGDSPLibraryFiles), by its name alone: the app's container
// moves on every reinstall, the name does not.
#define SGKeyDSPConvolver               @"spotifyglass.dsp.convolver"
#define SGKeyDSPConvolverFile           @"spotifyglass.dsp.convolver.file"
#define SGKeyDSPConvolverMode           @"spotifyglass.dsp.convolver.mode"      // SGDSPConvolverModeNames index

#define SGKeyDSPDDC                     @"spotifyglass.dsp.ddc"
#define SGKeyDSPDDCFile                 @"spotifyglass.dsp.ddc.file"

#define SGKeyDSPLiveprog                @"spotifyglass.dsp.liveprog"
#define SGKeyDSPLiveprogFile            @"spotifyglass.dsp.liveprog.file"

#define SGKeyDSPReverb                  @"spotifyglass.dsp.reverb"
#define SGKeyDSPReverbPreset            @"spotifyglass.dsp.reverb.preset"       // SGDSPReverbPresetNames index

#define SGKeyDSPStereoWide              @"spotifyglass.dsp.wide"
#define SGKeyDSPStereoWideLevel         @"spotifyglass.dsp.wide.level"          // percent, 50 leaving the width as it is

#define SGKeyDSPCrossfeed               @"spotifyglass.dsp.crossfeed"
#define SGKeyDSPCrossfeedMode           @"spotifyglass.dsp.crossfeed.mode"      // SGDSPCrossfeedModeNames index

#define SGKeyDSPTube                    @"spotifyglass.dsp.tube"
#define SGKeyDSPTubeDrive               @"spotifyglass.dsp.tube.drive"          // dB

#pragma mark - values

// A number setting's bounds, the value it has until set, and the step a slider moves it by.
typedef struct {
    double min, max, fallback, step;
} SGDSPRange;

SGDSPRange SGDSPRangeFor(NSString *key);

// Switches, numbers (clamped to their range) and strings. Setting one applies it.
BOOL SGDSPSwitch(NSString *key);
void SGDSPSetSwitch(NSString *key, BOOL on);
double SGDSPNumber(NSString *key);
void SGDSPSetNumber(NSString *key, double value);
NSString *SGDSPString(NSString *key);
void SGDSPSetString(NSString *key, NSString *value);

// The equalizer's and the compander's gains as numbers (15 and 7 of them), from and to their keys.
NSArray<NSNumber *> *SGDSPGains(NSString *key);
void SGDSPSetGains(NSString *key, NSArray<NSNumber *> *gains);

// Every key above back to its value until set; the master switch stays as it is.
void SGDSPResetAll(void);

#pragma mark - the lists the choices pick from

extern const double SGDSPEqualizerFrequencies[15];     // Hz, 25 ... 16000
extern const double SGDSPEqualizerGainLimit;           // ±12 dB
extern const double SGDSPCompanderFrequencies[7];      // Hz, 95 ... 7500
extern const double SGDSPCompanderGainLimit;           // ±1.2

NSArray<NSString *> *SGDSPConvolverModeNames(void);
NSArray<NSString *> *SGDSPCrossfeedModeNames(void);
NSArray<NSString *> *SGDSPReverbPresetNames(void);
// The equalizer's presets, names and their 15 gains.
NSArray<NSString *> *SGDSPEqualizerPresetNames(void);
NSArray<NSNumber *> *SGDSPEqualizerPreset(NSInteger index);

#pragma mark - file libraries

typedef NS_ENUM(NSInteger, SGDSPFileKind) {
    SGDSPFileImpulseResponse,   // the convolver's: .wav .flac .irs (a WAV by another name)
    SGDSPFileDDC,               // ViPER DDC's .vdc
    SGDSPFileLiveprog,          // Liveprog's .eel
};

// Documents/spoti.pw/Audio effects/<Convolver|DDC|Liveprog>, made on first use, empty until files are imported.
NSString *SGDSPLibraryDirectory(SGDSPFileKind kind);
NSArray<NSString *> *SGDSPLibraryFiles(SGDSPFileKind kind);   // names, sorted
NSArray<NSString *> *SGDSPFileExtensions(SGDSPFileKind kind); // lowercase, without the dot
// Copies a picked file into the library, replacing one of the same name; answers its name, nil and an
// error when it is not a file of that kind.
NSString *SGDSPImportFile(SGDSPFileKind kind, NSURL *url, NSError **error);
BOOL SGDSPDeleteFile(SGDSPFileKind kind, NSString *name);

#pragma mark - what the engine is doing

// One line for the page: off, waiting for Spotify to play, or running (sample rate, load).
NSString *SGDSPStatus(void);
// Why an effect's last change did not take, nil when it did: a script that did not compile (with the
// line), an impulse response that could not be read, a DDC file that was not one. Keyed by the effect's
// switch key (SGKeyDSPLiveprog, SGKeyDSPConvolver, SGKeyDSPDDC, SGKeyDSPGraphicEq).
NSString *SGDSPError(NSString *switchKey);

// The equalizer's magnitude response for the given gains, for drawing the curve: `count` points
// log-spaced from 20 Hz to 20 kHz into `frequencies` and `decibels`.
void SGDSPEqualizerResponse(NSArray<NSNumber *> *gains, NSInteger count, double *frequencies, double *decibels);
// The compander's amounts drawn as a smooth curve, the same way.
void SGDSPCompanderResponse(NSArray<NSNumber *> *gains, NSInteger count, double *frequencies, double *values);
