// The audio effects' file libraries: Documents/spoti.pw/Audio effects/<Convolver|DDC|Liveprog>, where the
// file effects find their files by name. Documents, which the app's backups keep. Every file in them is
// one the user imported.
//
// Threading: any thread (the engine's queue reads the paths too); a library is made once.
#import <os/lock.h>
#import "Core/SGCore.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h"

static NSString *const SGDSPFileErrorDomain = @"spotifyglass.dsp.files";

static NSString *libraryName(SGDSPFileKind kind) {
    switch (kind) {
    case SGDSPFileImpulseResponse: return @"Convolver";
    case SGDSPFileDDC: return @"DDC";
    case SGDSPFileLiveprog: return @"Liveprog";
    }
    return @"Other";
}

// The key naming the file an effect uses, and its switch, for a library.
static NSString *fileKey(SGDSPFileKind kind) {
    switch (kind) {
    case SGDSPFileImpulseResponse: return SGKeyDSPConvolverFile;
    case SGDSPFileDDC: return SGKeyDSPDDCFile;
    case SGDSPFileLiveprog: return SGKeyDSPLiveprogFile;
    }
    return nil;
}

NSArray<NSString *> *SGDSPFileExtensions(SGDSPFileKind kind) {
    switch (kind) {
    case SGDSPFileImpulseResponse: return @[@"wav", @"flac", @"irs"];
    case SGDSPFileDDC: return @[@"vdc"];
    case SGDSPFileLiveprog: return @[@"eel"];
    }
    return @[];
}

// Files imported into the library's earlier home move over once; the ones the old engine installed itself stay.
static void adoptEarlierLibrary(SGDSPFileKind kind, NSString *documents, NSString *directory) {
    static NSSet<NSString *> *installedByEngine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        installedByEngine = [NSSet setWithArray:@[
            @"Butterworth.vdc", @"FrontRearContrast.vdc", @"mh750.vdc", @"3bandSplitting.eel", @"8bandSplitting.eel",
            @"Joe0Bloggs DRX10K compander-HR.eel", @"audioGlitchGenerator.eel", @"autoWideness.eel",
            @"autopeakfilter.eel", @"butterworth3Band.eel", @"butterworth8Band.eel", @"dc_remove.eel", @"decimate.eel",
            @"delayChorus.eel", @"depthsurround.eel", @"downmixer.eel", @"fftConvolution2x4x2.eel",
            @"fftConvolutionHRTF.eel", @"firFilter.eel", @"firlsProc.eel", @"fractionalDelayline.eel",
            @"gainControl.eel", @"hadamVerb.eel", @"highpass.eel", @"lofiDistortionMangler.eel", @"lowpass.eel",
            @"metallic-reverb.eel", @"msCentreBoost.eel", @"phaseshifter.eel", @"pitchDownshift.eel",
            @"polyphaseFilterbank.eel", @"polyphaseFilterbankEqualization.eel", @"stereoFieldManipulator.eel",
            @"stereoPhaseInvert.eel", @"stereowide.eel", @"stftCentreBoost.eel", @"stftCentreCut.eel",
            @"stftDenoise.eel", @"stftFilter.eel", @"swapChannels.eel", @"timeAdjustment.eel",
            @"viper_dynamicbass.eel", @"viper_dynamicbass_preset.eel"
        ]];
    });
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *earlier = [[documents stringByAppendingPathComponent:@"spoti.pw/JamesDSP"] stringByAppendingPathComponent:libraryName(kind)];
    NSUInteger moved = 0;
    for (NSString *name in [files contentsOfDirectoryAtPath:earlier error:nil]) {
        if ([name hasPrefix:@"."] || [installedByEngine containsObject:name]) continue;
        NSString *from = [earlier stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if (![files fileExistsAtPath:from isDirectory:&isDirectory] || isDirectory) continue;
        if ([files moveItemAtPath:from toPath:[directory stringByAppendingPathComponent:name] error:nil]) moved++;
    }
    if (moved) SGLog(@"dsp: %lu files moved into the %@ library", (unsigned long)moved, libraryName(kind));
}

NSString *SGDSPLibraryDirectory(SGDSPFileKind kind) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [[documents stringByAppendingPathComponent:@"spoti.pw/Audio effects"] stringByAppendingPathComponent:libraryName(kind)];
    os_unfair_lock_lock(&lock);
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            SGLog(@"dsp: the %@ library could not be made: %@", libraryName(kind), error);
        } else {
            adoptEarlierLibrary(kind, documents, directory);
        }
    }
    os_unfair_lock_unlock(&lock);
    return directory;
}

NSArray<NSString *> *SGDSPLibraryFiles(SGDSPFileKind kind) {
    NSString *directory = SGDSPLibraryDirectory(kind);
    NSArray<NSString *> *extensions = SGDSPFileExtensions(kind);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
        if ([name hasPrefix:@"."] || ![extensions containsObject:name.pathExtension.lowercaseString]) continue;
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:name] isDirectory:&isDirectory] && !isDirectory) {
            [names addObject:name];
        }
    }
    return [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

static NSError *fileError(NSString *message) {
    return [NSError errorWithDomain:SGDSPFileErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Whether the bytes look like a file of the kind, before it goes into the library: a WAV (RIFF, RF64) or
// FLAC stream, a DDC file's two rates, a Liveprog script's @sample section.
static BOOL looksLike(SGDSPFileKind kind, NSData *data) {
    if (kind == SGDSPFileImpulseResponse) {
        if (data.length < 12) return NO;
        const char *bytes = data.bytes;
        return !memcmp(bytes, "RIFF", 4) || !memcmp(bytes, "RF64", 4) || !memcmp(bytes, "fLaC", 4);
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                     ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (kind == SGDSPFileDDC) return [text containsString:@"SR_44100"] && [text containsString:@"SR_48000"];
    return [text containsString:@"@sample"];
}

NSString *SGDSPImportFile(SGDSPFileKind kind, NSURL *url, NSError **error) {
    NSString *name = url.lastPathComponent;
    NSArray<NSString *> *extensions = SGDSPFileExtensions(kind);
    NSString *kindName = kind == SGDSPFileImpulseResponse ? @"an impulse response" : kind == SGDSPFileDDC ? @"a DDC file" : @"a Liveprog script";
    if (!name.length || [name hasPrefix:@"."] || ![extensions containsObject:name.pathExtension.lowercaseString]) {
        if (error) *error = fileError([NSString stringWithFormat:@"%@ is not %@ (.%@)", name ?: @"The file", kindName,
                                       [extensions componentsJoinedByString:@", ."]]);
        return nil;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data) {
        if (error) *error = readError ?: fileError([NSString stringWithFormat:@"%@ could not be read", name]);
        return nil;
    }
    if (!looksLike(kind, data)) {
        if (error) *error = fileError([NSString stringWithFormat:@"%@ is not %@", name, kindName]);
        return nil;
    }
    NSString *path = [SGDSPLibraryDirectory(kind) stringByAppendingPathComponent:name];
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = writeError;
        return nil;
    }
    SGLog(@"dsp: %@ added to the %@ library (%lu bytes)", name, libraryName(kind), (unsigned long)data.length);
    // A file replaced while an effect uses it is read again.
    if ([SGDSPString(fileKey(kind)) isEqualToString:name]) SGDSPApply(SGDSPEffectOf(fileKey(kind)));
    return name;
}

BOOL SGDSPDeleteFile(SGDSPFileKind kind, NSString *name) {
    if (!name.length || ![name.lastPathComponent isEqualToString:name] || [name hasPrefix:@"."]) return NO;
    NSString *path = [SGDSPLibraryDirectory(kind) stringByAppendingPathComponent:name];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&error]) {
        SGLog(@"dsp: %@ could not be deleted: %@", name, error);
        return NO;
    }
    SGLog(@"dsp: %@ deleted from the %@ library", name, libraryName(kind));
    // The effect using it lets it go (and says the file is gone).
    if ([SGDSPString(fileKey(kind)) isEqualToString:name]) SGDSPApply(SGDSPEffectOf(fileKey(kind)));
    return YES;
}
