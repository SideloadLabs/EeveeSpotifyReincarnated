#pragma once
#import <Foundation/Foundation.h>
#import "OfflineLimits.h"

// Assess only the observed local setup. This does not establish track authorization.
static inline NSDictionary *SAPAssessNativeSetup(NSDictionary *state, BOOL valid) {
    BOOL quota = valid && [state[@"music_limit"] longLongValue] >= SAPMinimumTrackLimit &&
        [state[@"music_duration_seconds"] longLongValue] >= SAPMinimumMusicDurationSeconds;
    NSNumber *mode = state[@"offline_key_request_mode"];
    BOOL selector = [state[@"key_mode_runtime_selectable"] boolValue];
    BOOL selectorBinding = !selector || [state[@"key_mode_selector_binding_verified"] boolValue];
    BOOL knownMode = mode && (mode.integerValue == 0 || mode.integerValue == 1);
    BOOL key = valid && knownMode && selectorBinding;
    BOOL guard = valid && [state[@"restriction_guard_active"] boolValue];
    NSMutableArray *blockers = [NSMutableArray array], *messages = [NSMutableArray array];
    if (!valid) {
        [blockers addObject:@"native_state_unverified"];
        [messages addObject:@"The native manager identity or state could not be verified."];
    } else {
        if (!guard) {
            [blockers addObject:@"restriction_patch_unverified"];
            [messages addObject:@"The download restriction patch is missing or does not match this executable. Install a verified Vitrine-Pixie build."];
        }
        if (!key) {
            if (!selectorBinding) {
                [blockers addObject:@"key_mode_selector_binding_unverified"];
                [messages addObject:@"The selector resolves to another library or cannot be resolved. Its configured mode cannot be verified."];
            } else {
                [blockers addObject:@"key_mode_unverified"];
                [messages addObject:@"The request-mode instruction could not be verified."];
            }
        }
        if (!quota) {
            [blockers addObject:@"local_quota_unverified"];
            [messages addObject:@"The requested local track quota was not confirmed after preparation."];
        }
    }
    BOOL ready = valid && quota && guard && key;
    return @{@"quota_ready":@(quota), @"local_patches_verified":@(guard && key),
        @"local_prepared":@(ready), @"authorization_checked":@NO,
        @"setup_blockers":[blockers copy],
        @"reason":ready ? @"Local settings prepared; device registration and per-track download authorization are separate checks." : [messages componentsJoinedByString:@"\n"]};
}
