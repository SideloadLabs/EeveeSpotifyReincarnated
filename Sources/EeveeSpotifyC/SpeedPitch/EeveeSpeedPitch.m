// the calls Swift makes (include/EeveeSpeedPitch.h). SpeedPitchEngine.m changes the sound and
// SpeedPitchClock.x keeps Spotify's progress bar in step with it.
#import "EeveeSpeedPitch.h"
#import "../Shared/LogSink.h"
#import "SpeedPitchPrivate.h"

static BOOL sg_reachable, sg_clockHooked;

void EeveeSpeedPitchLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    EeveeLogSinkWrite(EeveeLogSpeedPitch, format, args);
    va_end(args);
}

BOOL EeveeSpeedPitchInstall(BOOL pitchFollowsSpeed, void (^log)(NSString *message)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        EeveeLogSinkSet(EeveeLogSpeedPitch, log);
        BOOL canSpeed = NO;
        sg_reachable = SpeedPitchEngineInstall(pitchFollowsSpeed, &canSpeed);
        sg_clockHooked = SpeedPitchClockInstall();
        SPLog(@"installed: output %@, speed %@", sg_reachable ? @"reached" : @"not reached",
              canSpeed && sg_clockHooked ? @"possible once Spotify connects its output" : @"off");
    });
    return sg_reachable;
}

BOOL EeveeSpeedPitchSpeedAvailable(void) {
    return sg_clockHooked && SpeedPitchEngineTapped();
}

BOOL EeveeSpeedPitchPitchAvailable(void) {
    return sg_reachable || SpeedPitchEngineTapped();
}

double EeveeSpeedPitchSpeed(void) {
    return SpeedPitchEngineSpeed();
}

void EeveeSpeedPitchSetSpeed(double speed) {
    float next = (float)fmax(0.25, fmin(speed, 4));
    // a speed set before the engine lost Spotify's output waits for it to come back; 1x can always be put back.
    if (!EeveeSpeedPitchSpeedAvailable() && next != 1) return;
    SpeedPitchClockSpeedWillChange(SpeedPitchEngineSpeed(), next);
    SpeedPitchEngineSetSpeed(next);
}

float EeveeSpeedPitchSemitones(void) {
    return SpeedPitchEngineSemitones();
}

void EeveeSpeedPitchSetSemitones(float semitones) {
    if (!EeveeSpeedPitchPitchAvailable()) return;
    SpeedPitchEngineSetSemitones(fmaxf(-24, fminf(semitones, 24)));
}

BOOL EeveeSpeedPitchPitchFollowsSpeed(void) {
    return SpeedPitchEngineFollows();
}

void EeveeSpeedPitchSetPitchFollowsSpeed(BOOL follows) {
    SpeedPitchEngineSetFollows(follows);
}
