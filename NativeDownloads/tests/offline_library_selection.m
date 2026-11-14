#import "OfflineLibrarySelection.h"
#import <assert.h>
int main(void) {@autoreleasepool {
    NSDictionary *a=@{@"uri":@"spotify:track:a"},*b=@{@"uri":@"spotify:track:b"};
    NSArray *scope=@[a,b,a];
    assert(SAPOfflineLibrarySelection(scope,[NSSet setWithObject:a[@"uri"]],NO).count==0);
    assert(SAPOfflineLibrarySelection(scope,NSSet.set,YES).count==0);
    NSArray *chosen=SAPOfflineLibrarySelection(scope,[NSSet setWithObjects:a[@"uri"],@"spotify:track:outside",nil],YES);
    assert(chosen.count==1 && [chosen.firstObject isEqual:a]);
    chosen=SAPOfflineLibrarySelection(@[b,a],[NSSet setWithObjects:a[@"uri"],b[@"uri"],nil],YES);
    assert(([chosen isEqual:@[b,a]]));
    NSArray *evidence=@[@{@"uri":a[@"uri"],@"offline_removed":@YES},@{@"uri":b[@"uri"],@"offline_removed":@YES},@{@"uri":@"outside",@"offline_removed":@YES}];
    assert(([SAPOfflineLibraryRemainingTracks(@[a,b],@[a],evidence)isEqual:@[b]]));
    assert(([SAPOfflineLibraryRemainingTracks(@[a,b],@[a],@[@{@"uri":a[@"uri"],@"offline_removed":@NO}])isEqual:@[a,b]]));
    assert(([SAPOfflineLibraryRemainingTracks(@[a,b],@[a],@[@{@"uri":a[@"uri"],@"offline_removed":NSNull.null}])isEqual:@[a,b]]));
    puts("offline_library_selection PASS");
}}
