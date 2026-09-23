// The Vibrations sections of the Player page, under either look (App/Pages.m puts them there): a card
// per switch, the way the Audio effects page has one per effect, each opening out into its settings while
// its switch is on. Controls has its strength; Music Haptics its strength and what it follows, a choice
// that also says whether the rumble plays, rather than a switch of its own that one choice would leave
// with nothing to do.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Haptics.h"

static NSString *const kMusicHapticsInfo = @"The iPhone taps along with the drums and rumbles under the bass of whatever Spotify is playing, worked out from the sound as it plays, much like Music Haptics in Apple Music.\n\nIt follows the sound this iPhone plays, through its speaker or headphones, while Spotify is open: iOS plays no haptics for an app in the background, and a song playing on another device through Connect has no sound here to follow.";

static NSArray<NSString *> *followsNames(void) {
    return @[@"Everything", @"Beat", @"Bass"];
}

static NSArray<NSString *> *followsNotes(void) {
    return @[@"A tap on each kick and snare, and a rumble under the bass",
             @"A tap on each kick and snare, no rumble",
             @"A tap on each kick, and a rumble under the bass"];
}

static void strengthRange(NSString *key, NSInteger *minimum, NSInteger *maximum) {
    BOOL music = [key isEqualToString:SGKeyMusicStrength];
    *minimum = music ? SGMusicStrengthMin : SGControlStrengthMin;
    *maximum = music ? SGMusicStrengthMax : SGControlStrengthMax;
}

double SGHapticsStrength(NSString *key) {
    NSInteger minimum, maximum;
    strengthRange(key, &minimum, &maximum);
    return MAX(minimum, MIN(maximum, SGInt(key, 100))) / 100.0;
}

SGMusicFollows SGMusicHapticsFollows(void) {
    NSInteger follows = SGInt(SGKeyMusicFollows, SGMusicFollowsEverything);
    return follows >= SGMusicFollowsEverything && follows <= SGMusicFollowsBass ? (SGMusicFollows)follows : SGMusicFollowsEverything;
}

// A percentage slider over a strength key, telling `changed` each step it stores.
static SGModRow *strengthRow(NSString *key, void (^changed)(void)) {
    NSInteger minimum, maximum;
    strengthRange(key, &minimum, &maximum);
    return SGSliderRow(@"Strength", nil, minimum, maximum, SGStrengthStep,
        ^double { return SGHapticsStrength(key) * 100; },
        ^(double value) {
            SGSetInt(key, lround(value));
            if (changed) changed();
        },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld%%", lround(value)]; });
}

NSArray<SGModSection *> *SGVibrationsSections(void) {
    SGModRow *controls = SGSwitchRow(@"Controls", nil, SGKeyControlHaptics);
    SGModRow *controlStrength = strengthRow(SGKeyControlStrength, ^{
        // Felt as it is set: a tap at the new strength with each step.
        SGPlayFeedback(SGFeedbackAdd);
    });
    controlStrength.visible = ^BOOL { return SGEnabled(SGKeyControlHaptics); };

    SGModRow *music = SGOptionRow(@"Music Haptics", nil, SGKeyMusicHaptics);
    music.info = kMusicHapticsInfo;
    music.changed = ^(BOOL on) { SGSetMusicHapticsEnabled(on); };
    BOOL (^musicOn)(void) = ^BOOL { return SGFlag(SGKeyMusicHaptics, NO); };
    SGModRow *musicStrength = strengthRow(SGKeyMusicStrength, ^{ SGMusicHapticsSettingsChanged(); });
    musicStrength.visible = musicOn;
    SGModRow *follows = SGChoiceRow(@"Follows", nil, SGKeyMusicFollows, followsNames(), SGMusicFollowsEverything);
    follows.choiceNotes = followsNotes();
    follows.chosen = ^(NSInteger index) { SGMusicHapticsSettingsChanged(); };
    follows.visible = musicOn;

    return @[
        SGSection(@"Vibrations", @[SGWithSymbol(controls, @"hand.tap"), controlStrength]),
        SGSection(nil, @[SGWithSymbol(music, @"waveform"), musicStrength, follows]),
    ];
}
