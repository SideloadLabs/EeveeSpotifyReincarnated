#import "OfflineLibraryProgress.h"
// A page's immutable scope is indexed once. Event updates touch only the
// cached aggregates; no whole-queue set copies are needed for progress frames.
@interface SAPOfflineProgressScope : NSObject
@property(nonatomic,strong) NSSet<NSString *> *wanted;
@property(nonatomic,strong) NSMutableSet<NSString *> *identities;
@property(nonatomic) NSUInteger completed,failed,converting;
@end
@implementation SAPOfflineProgressScope @end
@interface SAPOfflineLibraryProgress ()
@property(nonatomic,strong) NSSet<NSString *> *identities;
@property(nonatomic,strong) NSMutableSet<NSString *> *completed,*failures,*converting;
@property(nonatomic,copy) NSString *phase,*currentURI,*message;
@property(nonatomic) double packageFraction;
@property(nonatomic) BOOL terminal,packaging;
@property(nonatomic,strong) NSMapTable<NSArray *,SAPOfflineProgressScope *> *scopes;
@end
@implementation SAPOfflineLibraryProgress
- (instancetype)initWithTracks:(NSArray<NSDictionary *> *)tracks {
    if((self=[super init])) {
        NSMutableSet *identities=NSMutableSet.set;for(NSDictionary *row in tracks)if([row[@"uri"]isKindOfClass:NSString.class])[identities addObject:row[@"uri"]];
        self.scopes=[[NSMapTable alloc]initWithKeyOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory capacity:3];
        self.identities=identities;self.completed=NSMutableSet.set;self.converting=NSMutableSet.set;self.failures=NSMutableSet.set;self.phase=@"preparing";
    }return self;
}
- (void)applyEvent:(NSDictionary *)event {
    if(self.terminal)return;
    NSString *phase=event[@"phase"],*uri=event[@"uri"];
    if([phase isEqual:@"queue_extended"]) {
        NSMutableSet *identities=[self.identities mutableCopy];
        for(id value in event[@"uris"])if([value isKindOfClass:NSString.class] && [value length] && ![identities containsObject:value]) {
            [identities addObject:value];
            for(SAPOfflineProgressScope *scope in self.scopes.objectEnumerator)if([scope.wanted containsObject:value])[scope.identities addObject:value];
        }
        self.identities=identities;
        if(self.packaging){self.packaging=NO;self.packageFraction=0;self.phase=@"preparing";self.currentURI=nil;self.message=nil;}
        return;
    }
    if([phase isEqual:@"converting"]){
        if([self.identities containsObject:uri] && ![self.converting containsObject:uri]) {
            [self.converting addObject:uri];
            for(SAPOfflineProgressScope *scope in self.scopes.objectEnumerator)if([scope.identities containsObject:uri])scope.converting++;
        }return;
    }
    if([phase isEqual:@"prepared"]) {
        BOOL converting=[self.converting containsObject:uri],completed=[self.completed containsObject:uri],failed=[self.failures containsObject:uri];
        [self.converting removeObject:uri];
        if([self.identities containsObject:uri]){[self.completed addObject:uri];if(![event[@"success"]boolValue])[self.failures addObject:uri];}
        for(SAPOfflineProgressScope *scope in self.scopes.objectEnumerator)if([scope.identities containsObject:uri]) {
            if(converting)scope.converting--;
            if(!completed)scope.completed++;
            if(!failed && [self.failures containsObject:uri])scope.failed++;
        }
        return;
    }
    if([phase isEqual:@"packaging"]) {self.packaging=YES;self.packageFraction=MIN(1,MAX(0,[event[@"fraction"]doubleValue]));}
    self.phase=phase?:@"preparing";self.currentURI=uri;self.message=event[@"message"];
    if([@[@"ready",@"failed",@"cancelled"]containsObject:phase])self.terminal=YES;
}
- (NSDictionary *)snapshotForTracks:(NSArray<NSDictionary *> *)scope {
    SAPOfflineProgressScope *aggregate=nil;
    if(scope) {
        aggregate=[self.scopes objectForKey:scope];
        if(!aggregate) {
            aggregate=SAPOfflineProgressScope.new;NSMutableSet *wanted=NSMutableSet.set;
            for(NSDictionary *row in scope)if([row[@"uri"]isKindOfClass:NSString.class])[wanted addObject:row[@"uri"]];
            aggregate.wanted=wanted;aggregate.identities=NSMutableSet.set;
            for(NSString *uri in wanted)if([self.identities containsObject:uri]) {
                [aggregate.identities addObject:uri];aggregate.completed += [self.completed containsObject:uri];
                aggregate.failed += [self.failures containsObject:uri];aggregate.converting += [self.converting containsObject:uri];
            }
            [self.scopes setObject:aggregate forKey:scope];
        }
    }
    NSSet *ids=scope?aggregate.identities:self.identities;
    NSUInteger done=scope?aggregate.completed:self.completed.count,failed=scope?aggregate.failed:self.failures.count;
    NSUInteger encoding=scope?aggregate.converting:self.converting.count;
    double fraction=self.packaging?self.packageFraction:(ids.count?(double)done/ids.count:0);
    if([self.phase isEqual:@"ready"])fraction=1;
    NSString *message=self.message?:@"Preparing files…";
    if(!self.terminal && !self.packaging && ![ids containsObject:self.currentURI])message=done==ids.count?@"Files prepared · Waiting for the remaining selection":@"Waiting for selected files…";
    if(!self.terminal && !self.packaging && encoding)message=[NSString stringWithFormat:@"Converting to M4A · %lu active",(unsigned long)encoding];
    return @{@"visible":@(ids.count>0),@"phase":self.phase?:@"preparing",@"completed":@(done),@"total":@(ids.count),@"failed":@(failed),@"fraction":@(fraction),@"message":message,@"active":@(!self.terminal)};
}
- (NSString *)stateForTrackURI:(NSString *)uri {
    if(!uri.length||![self.identities containsObject:uri])return nil;
    if([self.failures containsObject:uri])return @"failed";
    if([self.completed containsObject:uri])return @"prepared";
    if(self.terminal)return [self.phase isEqual:@"cancelled"]?@"cancelled":@"not_exported";
    if([self.converting containsObject:uri])return @"converting";
    if([self.currentURI isEqual:uri]&&[self.phase isEqual:@"preparing"])return @"preparing";
    return @"queued";
}
@end
