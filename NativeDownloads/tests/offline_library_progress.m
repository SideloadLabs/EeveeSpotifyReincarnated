#import "OfflineLibraryProgress.h"
#import <assert.h>
@interface CountingScope : NSArray
@property(nonatomic,strong) NSArray *values;
@property(nonatomic) NSUInteger reads;
@end
@implementation CountingScope
- (NSUInteger)count {self.reads++;return self.values.count;}
- (id)objectAtIndex:(NSUInteger)index {self.reads++;return self.values[index];}
@end
static NSDictionary *track(NSString *uri){return @{@"uri":uri};}
int main(void){@autoreleasepool {
 NSArray *a=@[track(@"a"),track(@"b")],*all=[a arrayByAddingObject:track(@"c")];
 SAPOfflineLibraryProgress *p=[[SAPOfflineLibraryProgress alloc]initWithTracks:all];
 assert([p stateForTrackURI:@"outside"]==nil);
 assert([[p stateForTrackURI:@"a"]isEqual:@"queued"]);
 [p applyEvent:@{@"phase":@"preparing",@"uri":@"a",@"message":@"Reading cache"}];
 assert([[p stateForTrackURI:@"a"]isEqual:@"preparing"]&&[[p stateForTrackURI:@"b"]isEqual:@"queued"]);
 [p applyEvent:@{@"phase":@"converting",@"uri":@"a"}];assert([[p stateForTrackURI:@"a"]isEqual:@"converting"]);
 assert([[p snapshotForTracks:nil][@"total"]unsignedIntegerValue]==3);
 assert([[p snapshotForTracks:@[track(@"outside")]][@"visible"]boolValue]==NO);
 [p applyEvent:@{@"phase":@"prepared",@"uri":@"a",@"success":@YES}];
 assert([[p stateForTrackURI:@"a"]isEqual:@"prepared"]);
 [p applyEvent:@{@"phase":@"prepared",@"uri":@"a",@"success":@YES}];
 assert([[p snapshotForTracks:a][@"completed"]unsignedIntegerValue]==1);
 assert([[p snapshotForTracks:a][@"fraction"]doubleValue]==.5);
 assert([[p snapshotForTracks:@[track(@"c")]][@"completed"]unsignedIntegerValue]==0);
 [p applyEvent:@{@"phase":@"preparing",@"uri":@"c"}];
 assert([[p snapshotForTracks:a][@"message"]containsString:@"Waiting"]);
 [p applyEvent:@{@"phase":@"prepared",@"uri":@"b",@"success":@NO}];
 assert([[p stateForTrackURI:@"b"]isEqual:@"failed"]);
 assert([[p snapshotForTracks:a][@"failed"]unsignedIntegerValue]==1);
 [p applyEvent:@{@"phase":@"packaging",@"fraction":@.25}];
 assert([[p snapshotForTracks:a][@"fraction"]doubleValue]==.25);
 [p applyEvent:@{@"phase":@"cancelled"}];
 assert([[p stateForTrackURI:@"c"]isEqual:@"cancelled"]&&[[p stateForTrackURI:@"a"]isEqual:@"prepared"]);
 assert([[p snapshotForTracks:a][@"fraction"]doubleValue]==.25);
 [p applyEvent:@{@"phase":@"ready"}];
 assert([[p snapshotForTracks:a][@"phase"]isEqual:@"cancelled"]);
 CountingScope *scope=CountingScope.new;scope.values=@[track(@"x"),track(@"y"),track(@"future")];
 SAPOfflineLibraryProgress *cached=[[SAPOfflineLibraryProgress alloc]initWithTracks:@[track(@"x"),track(@"y")]];
 assert([cached snapshotForTracks:scope][@"total"] && [[cached snapshotForTracks:scope][@"total"]integerValue]==2);
 scope.reads=0;
 for(NSUInteger i=0;i<50;i++) {
  [cached applyEvent:@{@"phase":@"converting",@"uri":@"x"}];
  [cached applyEvent:@{@"phase":@"prepared",@"uri":@"x",@"success":@YES}];
  assert([[cached snapshotForTracks:scope][@"completed"]integerValue]==1);
 }
 assert(scope.reads==0); // Production snapshots must not rewalk immutable scope rows.
 [cached applyEvent:@{@"phase":@"queue_extended",@"uris":@[@"future",@"future"]}];
 assert([[cached snapshotForTracks:scope][@"total"]integerValue]==3);
 [cached applyEvent:@{@"phase":@"prepared",@"uri":@"future",@"success":@NO}];
 assert([[cached snapshotForTracks:scope][@"completed"]integerValue]==2);
 assert([[cached snapshotForTracks:scope][@"failed"]integerValue]==1);
 assert([[cached snapshotForTracks:nil][@"total"]integerValue]==3 && scope.reads==0);
 [cached applyEvent:@{@"phase":@"ready"}];
 assert([[cached snapshotForTracks:scope][@"fraction"]doubleValue]==1 && scope.reads==0);
 puts("offline_library_progress PASS");
}}
