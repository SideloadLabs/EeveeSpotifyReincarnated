#import "ArtistSessionPrivate.h"

@implementation SAPArtistDownloadSession (Ownership)
- (void)enqueue:(NSDictionary *)item order:(NSDictionary *)order {
    NSString *uri=item[@"uri"];self.queueOrders[uri]=order;NSUInteger index=0;
    for(NSDictionary *queued in self.queue){if(compareQueueOrder(order,self.queueOrders[queued[@"uri"]])==NSOrderedAscending)break;index++;}
    [self.queue insertObject:[item copy] atIndex:index];
}
- (void)recordLease:(id)owner uri:(NSString *)uri order:(NSDictionary *)order {
    NSMutableDictionary *orders=self.leaseOrders[uri];if(!orders)self.leaseOrders[uri]=orders=[NSMutableDictionary dictionary];if(!orders[owner])orders[owner]=order;
}
- (void)refreshQueuedURI:(NSString *)uri {
    if(![self.queuedURIs containsObject:uri])return;
    NSUInteger index=[self.queue indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger i,BOOL *stop){return [item[@"uri"]isEqual:uri];}];if(index==NSNotFound)return;
    NSMutableDictionary *ready=self.readyItems[uri];NSDictionary *item=self.queue[index],*readyOrder=nil;
    for(id owner in ready){NSDictionary *candidate=self.leaseOrders[uri][owner];if(!readyOrder || compareQueueOrder(candidate,readyOrder)==NSOrderedAscending){readyOrder=candidate;item=ready[owner];}}
    [self stateFor:uri][@"reserved"]=@(!ready.count);
    NSDictionary *order=nil;for(NSDictionary *candidate in [self.leaseOrders[uri]allValues])if(!order || compareQueueOrder(candidate,order)==NSOrderedAscending)order=candidate;
    // Removing a younger owner must not shift this release within its batch.
    if(!order || compareQueueOrder(order,self.queueOrders[uri])==NSOrderedSame){self.queue[index]=item;return;}
    [self.queue removeObjectAtIndex:index];[self enqueue:item order:order];
}
- (NSUInteger)ticketOrdinal:(id)owner uri:(NSString *)uri {
    NSMutableDictionary *ordinals=self.batchTickets[owner][@"ordinals"];
    NSNumber *ordinal=ordinals[uri];if(!ordinal)ordinals[uri]=ordinal=@(ordinals.count);return ordinal.unsignedIntegerValue;
}
- (NSUInteger)reserveTicket:(id)owner {
    NSDictionary *ticket=self.batchTickets[owner];
    if(ticket){if(!self.queueOrders[ticket[@"uri"]])[self enqueue:@{@"uri":ticket[@"uri"],@"reserved_batch_end":@YES} order:@{@"rank":ticket[@"rank"],@"ordinal":@(NSUIntegerMax)}];return [ticket[@"rank"]unsignedIntegerValue];}
    NSUInteger rank=++self.nextQueueRank;NSString *uri=[@"task-reservation:"stringByAppendingString:NSUUID.UUID.UUIDString];
    self.batchTickets[owner]=@{@"uri":uri,@"rank":@(rank),@"ordinals":[NSMutableDictionary dictionary]};
    [self enqueue:@{@"uri":uri,@"reserved_batch_end":@YES} order:@{@"rank":@(rank),@"ordinal":@(NSUIntegerMax)}];return rank;
}
- (void)releaseTicket:(id)owner {
    NSString *uri=self.batchTickets[owner][@"uri"];if(!uri)return;
    [self.queue filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return ![item[@"uri"]isEqual:uri];}]];
    [self.queueOrders removeObjectForKey:uri];[self.batchTickets removeObjectForKey:owner];
}
- (void)registerOwner:(id)artist uri:(NSString *)uri {
    if(![ownerArtist(artist) isKindOfClass:NSString.class] || ![ownerArtist(artist) length] || !validContextURI(uri))return;
    NSMutableSet *owners=self.contextOwners[uri];if(!owners)self.contextOwners[uri]=owners=[NSMutableSet set];[owners addObject:artist];
    NSMutableSet *contexts=self.artistContexts[artist];if(!contexts)self.artistContexts[artist]=contexts=[NSMutableSet set];[contexts addObject:uri];
}
- (void)clearOwners:(NSString *)uri {
    [self.readyItems removeObjectForKey:uri];[self.leaseOrders removeObjectForKey:uri];
    for(id artist in self.contextOwners[uri]){NSMutableSet *contexts=self.artistContexts[artist];[contexts removeObject:uri];if(!contexts.count)[self.artistContexts removeObjectForKey:artist];}[self.contextOwners removeObjectForKey:uri];
}
@end
