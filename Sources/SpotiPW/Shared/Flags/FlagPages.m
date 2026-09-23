// Labs: Spotify's flags for features it built and did not ship; every row forces one flag.
#import "Settings/SGModPage.h"
#import "Flags.h"

static UIViewController *martiniPage(void) {
    return [[SGModPage alloc] initWithTitle:@"AI Chat (Martini)" intro:SGRestartNote sections:@[
        SGSection(@"On Home", @[
            SGFlagRow(@"Chat entry point", @"ios-home-evopage-impl.interactive_entrypoint_enabled"),
            SGFlagRow(@"Martini behind it", @"ios-home-evopage-impl.interactive_entrypoint_martini_enabled"),
            SGFlagRow(@"Floating chat", @"ios-home-evopage-impl.interactive_entrypoint_floating_chat_enabled"),
            SGFlagRow(@"Microphone", @"ios-home-evopage-impl.interactive_entrypoint_mic_enabled"),
            SGFlagRow(@"Glowing pill", @"ios-home-evopage-impl.interactive_entrypoint_pill_glow_enabled"),
        ]),
        SGSection(@"The chat", @[
            SGFlagRow(@"Intent pills", @"ios-martini-floatingchat-impl.intent_pills_enabled"),
            SGFlagRow(@"Thinking states", @"ios-martini-floatingchat-impl.thinking_states_enabled"),
            SGFlagRow(@"Voice recording", @"ios-martini-floatingchat-impl.voice_recording_enabled"),
        ]),
        SGSection(@"In the player", @[
            SGFlagRow(@"Chat entry point", @"ios-martini-npvcardprovider-impl.floating_chat_entry_point_enabled"),
        ]),
    ] footer:nil];
}

UIViewController *SGLabsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Labs" intro:@"Unreleased features; some do nothing on your version. Changes apply after you restart Spotify." sections:@[
        SGSection(nil, @[
            SGWithSymbol(SGPageRow(@"AI Chat (Martini)", ^UIViewController *{ return martiniPage(); }), @"bubble.left.and.bubble.right"),
        ]),
        SGSection(@"Library", @[
            SGFlagRow(@"Local files from the Files app", @"ios-feature-localfiles.documents_enabled"),
        ]),
        SGSection(@"Home screen widget", @[
            SGFlagRow(@"Progress bar", @"ios-widgets-widgetremoteconfig-impl.progress_bar_enabled"),
        ]),
        SGNotedSection(@"Sleep timer", @[
            SGFlagRow(@"Fade out", @"ios-feature-sleeptimer.enable_fade_out"),
            SGFlagRow(@"One minute option", @"ios-feature-sleeptimer.enable_one_minute_option"),
            SGFlagRow(@"Options sheet", @"ios-feature-sleeptimer.use_options_sheet"),
        ], @"Options sheet is always on in Redesigned UI."),
        SGSection(@"Player", @[
            SGFlagRow(@"Snake on the cover art", @"ios-feature-cover-art-snake.enabled"),
        ]),
        SGSection(@"Podcast comments", @[
            SGFlagRow(@"Comments card", @"ios-feature-comments.enable_comments_card"),
            SGFlagRow(@"Pinned comments", @"ios-feature-comments.enable_pinned_comments"),
            SGFlagRow(@"Several reactions", @"ios-feature-comments.enable_multi_reactions"),
        ]),
    ] footer:nil];
}
