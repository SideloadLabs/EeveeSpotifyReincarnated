#import "DownloadEvidence.h"
#include <assert.h>
#include <math.h>

static void fallback(NSDictionary *fields){
 SAPDownloadContextEvidence value=SAPReadDownloadContextEvidence(fields);
 assert(!value.trustedTotals && fabs(value.progress-.37)<.000001);
}
int main(void){@autoreleasepool{
 SAPDownloadContextEvidence missing=SAPReadDownloadContextEvidence(@{});
 assert(!missing.downloaded && !missing.nativeActive && !missing.trustedTotals && missing.progress==0);
 // Downloaded item counts and playlist membership do not confirm an album context.
 SAPDownloadContextEvidence items=SAPReadDownloadContextEvidence(@{@"downloaded":@7,@"total":@7,@"totals_state":@2,@"playlist_member":@YES});
 assert(!items.downloaded && !items.nativeActive && items.trustedTotals && items.progress==1);
 SAPDownloadContextEvidence complete=SAPReadDownloadContextEvidence(@{@"native_state":@3});
 assert(complete.downloaded && !complete.nativeActive);
 SAPDownloadContextEvidence recovery=SAPReadDownloadContextEvidence(@{@"native_state":@3,@"recovery_removal_pending":@YES});
 assert(!recovery.downloaded);
 for(NSNumber *state in @[@2,@4,@5])assert(SAPReadDownloadContextEvidence(@{@"native_state":state}).nativeActive);
 for(NSNumber *state in @[@0,@1,@3,@6])assert(!SAPReadDownloadContextEvidence(@{@"native_state":state}).nativeActive);
 fallback(@{@"percent":@37});
 fallback(@{@"totals_state":@1,@"total":@10,@"downloaded":@5,@"percent":@37});
 fallback(@{@"totals_state":@2,@"total":@0,@"downloaded":@0,@"percent":@37});
 fallback(@{@"totals_state":@2,@"total":@10,@"downloaded":@11,@"percent":@37});
 SAPDownloadContextEvidence partial=SAPReadDownloadContextEvidence(@{@"totals_state":@2,@"total":@10,@"downloaded":@5,@"percent":@37});
 assert(partial.trustedTotals && partial.progress==.5 && !partial.downloaded);
 puts("PASS: unknown context stays unconfirmed; item counts never imply context completion; recovery removal, native activity and trusted-total/fallback boundaries preserve their distinct meanings");
}return 0;}
