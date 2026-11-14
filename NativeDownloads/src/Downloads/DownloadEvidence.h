#pragma once
#import <Foundation/Foundation.h>

// Context and item states use different native enums. Keep this context view
// independent of local intent, stopped visuals and playlist membership.
typedef struct {
    BOOL downloaded;
    BOOL nativeActive;
    BOOL trustedTotals;
    double progress;
} SAPDownloadContextEvidence;

static inline SAPDownloadContextEvidence SAPReadDownloadContextEvidence(NSDictionary *raw) {
    NSUInteger state = [raw[@"native_state"] unsignedIntegerValue];
    BOOL trusted = [raw[@"totals_state"] unsignedIntegerValue] == 2 &&
        [raw[@"total"] unsignedIntegerValue] > 0 &&
        [raw[@"downloaded"] unsignedIntegerValue] <= [raw[@"total"] unsignedIntegerValue];
    return (SAPDownloadContextEvidence){
        .downloaded = [raw[@"native_state"] isEqual:@3] && ![raw[@"recovery_removal_pending"] boolValue] && ![raw[@"stop_removal_pending"] boolValue],
        .nativeActive = state == 2 || state == 4 || state == 5,
        .trustedTotals = trusted,
        .progress = trusted ? [raw[@"downloaded"] doubleValue] / [raw[@"total"] doubleValue]
                            : [raw[@"percent"] doubleValue] / 100.
    };
}
