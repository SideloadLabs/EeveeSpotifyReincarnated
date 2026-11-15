#pragma once
#import <Foundation/Foundation.h>
// Calculate insertion-only updates. Existing sections and row identities must
// retain their order; new sections use destination indexes, as UIKit requires.
static inline NSDictionary *SAPArtistCatalogAppendChanges(NSArray *old,NSArray *next){
    NSMutableDictionary *previous=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<old.count;i++){NSString *title=old[i][@"title"];if(!title.length||previous[title])return nil;previous[title]=@(i);}
    NSMutableIndexSet *sections=[NSMutableIndexSet indexSet];NSMutableArray *rows=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];NSInteger last=-1;NSUInteger retained=0;
    for(NSUInteger section=0;section<next.count;section++){
        NSDictionary *group=next[section];NSString *title=group[@"title"];if(!title.length||[seen containsObject:title])return nil;[seen addObject:title];
        NSNumber *index=previous[title];if(!index){[sections addIndex:section];continue;}
        if(index.integerValue<=last)return nil;last=index.integerValue;retained++;
        NSArray *before=old[index.unsignedIntegerValue][@"releases"],*after=group[@"releases"];if(after.count<before.count)return nil;
        for(NSUInteger row=0;row<before.count;row++){NSString *uri=before[row][@"uri"];if(!uri.length||![uri isEqual:after[row][@"uri"]])return nil;}
        for(NSUInteger row=before.count;row<after.count;row++){NSUInteger indexes[]={section,row};[rows addObject:[NSIndexPath indexPathWithIndexes:indexes length:2]];}
    }
    return retained==old.count?@{@"sections":sections,@"rows":rows}:nil;
}
