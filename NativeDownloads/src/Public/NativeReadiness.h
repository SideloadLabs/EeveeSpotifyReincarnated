#pragma once
#import <Foundation/Foundation.h>
#import "OfflineLimits.h"

// A supported manager and elevated quotas alone do not establish readiness.
// Inspect the actual executable state, including a missing/unknown key mode.
static BOOL SAPNativeReadiness(NSMutableDictionary *state, BOOL valid) {
    BOOL quotas=valid && [state[@"music_limit"] longLongValue]>=SAPMinimumTrackLimit &&
        [state[@"music_duration_seconds"] longLongValue]>=SAPMinimumMusicDurationSeconds;
    id mode=state[@"offline_key_request_mode"];
    BOOL patches=valid && [state[@"restriction_guard_active"] boolValue] &&
        [mode isKindOfClass:NSNumber.class] && [mode isEqualToNumber:@0];
    state[@"valid"]=@(valid);
    state[@"quota_ready"]=@(quotas);
    state[@"executable_patches_ready"]=@(patches);
    state[@"ready"]=@(quotas && patches);
    return quotas && patches;
}
