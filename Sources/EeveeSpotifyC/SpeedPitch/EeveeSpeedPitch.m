// the calls Swift makes (include/EeveeSpeedPitch.h). SpeedPitchEngine.m changes the sound and
// SpeedPitchClock.x keeps Spotify's progress bar in step with it.
#import "EeveeSpeedPitch.h"
#import "SpeedPitchPrivate.h"

static void (^sg_logSink)(NSString *);
static BOOL sg_reachable, sg_clockHooked;

void EeveeSpeedPitchLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    void (^sink)(NSString *) = sg_logSink;
    if (sink) sink(message);
    else NSLog(@"[EeveeSpotify][SpeedPitch] %@", message);
}

BOOL EeveeSpeedPitchInstall(BOOL pitchFollowsSpeed, void (^log)(NSString *message)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_logSink = [log copy];
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
    if (!EeveeSpeedPitchSpeedAvailable()) return;
    float next = (float)fmax(0.25, fmin(speed, 4));
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
