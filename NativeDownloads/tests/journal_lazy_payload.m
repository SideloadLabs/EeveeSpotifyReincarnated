#import "TrackJournal.h"
#include <assert.h>

static bool diagnostics;
static NSUInteger evaluatedNames,evaluatedFacts,recorded;
static NSString *lastName;
static NSDictionary *lastFacts;
bool SAPDiagnosticsEnabled(void){return diagnostics;}
void SAPJournalNoteAction(NSString *name,NSDictionary *facts){recorded++;lastName=name;lastFacts=facts;}
static NSString *name(void){evaluatedNames++;return @"test_action";}
static NSDictionary *facts(void){evaluatedFacts++;return @{@"count":@(evaluatedFacts)};}
int main(void){@autoreleasepool{
 diagnostics=false;
 SAP_JOURNAL_ACTION(name(),facts());
 assert(!evaluatedNames && !evaluatedFacts && !recorded);
 diagnostics=true;
 SAP_JOURNAL_ACTION(name(),facts());
 assert(evaluatedNames==1 && evaluatedFacts==1 && recorded==1);
 assert([lastName isEqual:@"test_action"] && [lastFacts[@"count"]isEqual:@1]);
 diagnostics=false;
 SAP_JOURNAL_ACTION(name(),facts());
 assert(evaluatedNames==1 && evaluatedFacts==1 && recorded==1);
 // The existing function remains directly callable with its original ABI.
 SAPJournalNoteAction(@"compatibility",@{@"preserved":@YES});
 assert(recorded==2 && [lastName isEqual:@"compatibility"] && [lastFacts[@"preserved"]boolValue]);
 puts("PASS: journal facts and event names are not evaluated while OFF; evaluated exactly once while ON; original action function ABI preserved");
}return 0;}
