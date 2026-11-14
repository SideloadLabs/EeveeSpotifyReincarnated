#pragma once
#import <Foundation/Foundation.h>
@interface SAPOfflineLibraryProgress : NSObject
- (instancetype)initWithTracks:(NSArray<NSDictionary *> *)tracks;
- (void)applyEvent:(NSDictionary *)event;
- (NSDictionary *)snapshotForTracks:(NSArray<NSDictionary *> *)scope;
- (NSString *)stateForTrackURI:(NSString *)uri;
@end
