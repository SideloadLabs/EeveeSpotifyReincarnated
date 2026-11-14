#import "NativeSetupStatus.h"
#include <assert.h>
int main(void) {@autoreleasepool {
    NSMutableDictionary *state=[@{@"music_limit":@(SAPMinimumTrackLimit),@"music_duration_seconds":@(SAPMinimumMusicDurationSeconds),
        @"restriction_guard_active":@YES,@"offline_key_request_mode":@0,@"key_mode_runtime_selectable":@NO} mutableCopy];
    assert([SAPAssessNativeSetup(state,YES)[@"local_prepared"]boolValue]);
    assert(![SAPAssessNativeSetup(state,YES)[@"authorization_checked"]boolValue]);
    state[@"restriction_guard_active"]=@NO;state[@"offline_key_request_mode"]=@1;
    NSDictionary *foreign=SAPAssessNativeSetup(state,YES);
    assert(![foreign[@"local_prepared"]boolValue]);
    assert([foreign[@"setup_blockers"]containsObject:@"restriction_patch_unverified"]);
    assert(![foreign[@"setup_blockers"]containsObject:@"fixed_mode_one"]);
    assert(![foreign[@"setup_blockers"]containsObject:@"local_quota_unverified"]);
    state[@"restriction_guard_active"]=@YES;
    assert([SAPAssessNativeSetup(state,YES)[@"local_prepared"]boolValue]);
    assert(![SAPAssessNativeSetup(state,YES)[@"authorization_checked"]boolValue]);
    state[@"key_mode_runtime_selectable"]=@YES;
    state[@"key_mode_selector_binding_verified"]=@YES;
    assert([SAPAssessNativeSetup(state,YES)[@"local_prepared"]boolValue]);
    state[@"offline_key_request_mode"]=@0;
    assert([SAPAssessNativeSetup(state,YES)[@"local_prepared"]boolValue]);
    state[@"key_mode_selector_binding_verified"]=@NO;
    assert(![SAPAssessNativeSetup(state,YES)[@"local_prepared"]boolValue]);
    assert([SAPAssessNativeSetup(state,YES)[@"setup_blockers"]containsObject:@"key_mode_selector_binding_unverified"]);
    state[@"key_mode_selector_binding_verified"]=@YES;
    state[@"music_limit"]=@0;
    assert([SAPAssessNativeSetup(state,YES)[@"setup_blockers"]containsObject:@"local_quota_unverified"]);
    assert([SAPAssessNativeSetup(state,NO)[@"setup_blockers"]isEqual:@[@"native_state_unverified"]]);
    [state removeObjectForKey:@"offline_key_request_mode"];state[@"key_mode_runtime_selectable"]=@NO;
    assert([SAPAssessNativeSetup(state,YES)[@"setup_blockers"]containsObject:@"key_mode_unverified"]);
    puts("PASS: verified modes 0 and 1 allowed; unknown selector binding blocked; patch, quota and authorization remain separate");
}return 0;}
