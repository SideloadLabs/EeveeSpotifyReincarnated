#pragma once
#import <Foundation/Foundation.h>
// Automatic refresh is authorized only for this proven stale offline-copy case.
static inline BOOL SAPShouldRefreshCachedTrack(BOOL share,BOOL attempted,BOOL downloaded,NSDictionary *evidence){
 return share&&!attempted&&downloaded&&[evidence[@"stage"]isEqual:@"no_media_key"]&&[evidence[@"cache_seen"]boolValue]&&[evidence[@"storage_decoded"]unsignedIntegerValue]>0&&![evidence[@"media_key_available"]boolValue];
}
