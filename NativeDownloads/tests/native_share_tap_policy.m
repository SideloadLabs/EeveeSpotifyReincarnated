#import "NativeShareTapPolicy.h"
#include <assert.h>
int main(void){@autoreleasepool {
 assert(SAPShareIntentFromLabel(@"Больше")==SAPNativeShareMore);
 assert(SAPShareIntentFromLabel(@" Copy\nlink ")==SAPNativeShareCopy);
 assert(SAPShareIntentFromLabel(@"Сообщение")==SAPNativeShareMessage);
 assert(SAPShareIntentFromLabel(@"Threads")==SAPNativeShareNone);
 assert(SAPShareIntentFromLabel(@"X")==SAPNativeShareNone);
 assert(SAPShareIntentFromLabel(@"Copy link Messages More")==SAPNativeShareNone);
 assert(SAPShareIntentFromLabel(nil)==SAPNativeShareNone);
 assert(SAPShareTapAllowed(YES,YES,NO,YES));
 assert(!SAPShareTapAllowed(NO,YES,NO,YES));assert(!SAPShareTapAllowed(YES,NO,NO,YES));assert(!SAPShareTapAllowed(YES,YES,YES,YES));assert(!SAPShareTapAllowed(YES,YES,NO,NO));
 assert(!SAPShareShouldPrepare(YES,SAPNativeShareNone,NO,NO));
 assert(SAPShareShouldPrepare(YES,SAPNativeShareMore,NO,NO));
 assert(!SAPShareShouldPrepare(YES,SAPNativeShareMore,YES,NO));
 assert(!SAPShareShouldPrepare(NO,SAPNativeShareMore,NO,NO));
 assert(SAPShareCellMatchesAction(@[@"More",@"Больше"],SAPNativeShareMore));
 assert(!SAPShareCellMatchesAction(@[@"More",@"Messages"],SAPNativeShareMore));
 assert(!SAPShareCellMatchesAction(@[@"More",@"WhatsApp"],SAPNativeShareMore));
 puts("PASS stock-share tap policy: exact destination labels, unrelated links unchanged, enabled/visible/entity gates");
}return 0;}
