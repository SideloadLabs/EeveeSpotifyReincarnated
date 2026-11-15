#pragma once
#import <Foundation/Foundation.h>
// Tracks in the current page, ordered as displayed, with unique identities.
static inline NSArray<NSDictionary *> *SAPOfflineLibrarySelection(NSArray<NSDictionary *> *scope,NSSet<NSString *> *selected,BOOL selecting) {
    if(!selecting || !selected.count)return @[];
    NSMutableArray *result=NSMutableArray.array;NSMutableSet *seen=NSMutableSet.set;
    for(NSDictionary *row in scope) {
        NSString *uri=row[@"uri"];
        if([selected containsObject:uri] && ![seen containsObject:uri]){[seen addObject:uri];[result addObject:row];}
    }
    return result;
}
// Prune only selected identities with a fresh, positively verified offline removal.
static inline NSArray<NSDictionary *> *SAPOfflineLibraryRemainingTracks(NSArray<NSDictionary *> *tracks,NSArray<NSDictionary *> *selected,NSArray<NSDictionary *> *results) {
    NSMutableSet *wanted=NSMutableSet.set,*removed=NSMutableSet.set;
    for(NSDictionary *row in selected)if([row[@"uri"]isKindOfClass:NSString.class])[wanted addObject:row[@"uri"]];
    for(id value in results)if([value isKindOfClass:NSDictionary.class]&&[value[@"offline_removed"]isEqual:@YES]&&[wanted containsObject:value[@"uri"]])[removed addObject:value[@"uri"]];
    NSMutableArray *remaining=NSMutableArray.array;
    for(NSDictionary *row in tracks)if(![removed containsObject:row[@"uri"]])[remaining addObject:row];
    return remaining;
}
