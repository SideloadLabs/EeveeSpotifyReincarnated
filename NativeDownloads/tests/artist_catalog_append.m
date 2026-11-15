#import <Foundation/Foundation.h>
#import "ArtistCatalogAppend.h"
#include <assert.h>
static NSDictionary *group(NSString *title,NSArray *ids){NSMutableArray *rows=[NSMutableArray array];for(NSString *uri in ids)[rows addObject:@{@"uri":uri}];return @{@"title":title,@"releases":rows};}
int main(void){@autoreleasepool {
 NSArray *old=@[group(@"Singles",@[@"s1"])];
 NSDictionary *delta=SAPArtistCatalogAppendChanges(old,@[group(@"Albums",@[@"a1"]),group(@"Singles",@[@"s1",@"s2"]) ]);
 assert([delta[@"sections"]containsIndex:0]);NSArray *rows=delta[@"rows"];assert(rows.count==1&&[rows[0]indexAtPosition:0]==1&&[rows[0]indexAtPosition:1]==1);
 delta=SAPArtistCatalogAppendChanges(@[],old);assert([delta[@"sections"]containsIndex:0]&&[delta[@"rows"]count]==0);
 delta=SAPArtistCatalogAppendChanges(old,old);assert([delta[@"sections"]count]==0&&[delta[@"rows"]count]==0);
 assert(!SAPArtistCatalogAppendChanges(old,@[group(@"Singles",@[@"s2",@"s1"])]));
 assert(!SAPArtistCatalogAppendChanges(old,@[]));
 assert(!SAPArtistCatalogAppendChanges(@[group(@"Albums",@[@"a"]),group(@"Singles",@[@"s1"])],@[group(@"Singles",@[@"s1"]),group(@"Albums",@[@"a"])]));
 puts("PASS catalog append-only updates preserve old rows and remap inserts across new categories; incompatible updates rejected");
}return 0;}
