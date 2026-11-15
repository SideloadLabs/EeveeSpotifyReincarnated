#import <Foundation/Foundation.h>
#import "JournalPrivate.h"
#include <assert.h>

int main(void){@autoreleasepool{
 // Native item states: 0 not_downloaded, 1 error, 3 downloaded, 4/5/6 in progress, 7 failed.
 for(NSUInteger state=4;state<=6;state++)assert(SAPJournalNeedsPoll(YES,state,0));
 for(NSUInteger state=0;state<=3;state++)assert(!SAPJournalNeedsPoll(YES,state,0) && !SAPJournalNeedsPoll(YES,state,1));
 assert(!SAPJournalNeedsPoll(YES,7,0) && !SAPJournalNeedsPoll(YES,7,2));
 assert(SAPJournalNeedsPoll(NO,0,1) && "a requested track without a native state yet is still polled");
 assert(!SAPJournalNeedsPoll(NO,0,0) && "a track only seen by name is never polled");
 puts("PASS: diagnostics polling covers only in-progress and just-requested tracks; catalog, downloaded and failed tracks are not re-queried");
}return 0;}
