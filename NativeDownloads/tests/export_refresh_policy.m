#import <Foundation/Foundation.h>
#import "ExportRefreshPolicy.h"
#include <assert.h>
int main(void){@autoreleasepool {
 NSDictionary *missing=@{@"stage":@"no_media_key",@"cache_seen":@YES,@"storage_decoded":@1,@"media_key_available":@NO};
 assert(SAPShouldRefreshCachedTrack(YES,NO,YES,missing));
 assert(!SAPShouldRefreshCachedTrack(YES,YES,YES,missing));
 assert(!SAPShouldRefreshCachedTrack(YES,NO,NO,missing));
 assert(!SAPShouldRefreshCachedTrack(NO,NO,YES,missing));
 for(NSString *stage in @[@"no_cache_file",@"storage_decode_failed",@"audio_validation_failed",@"media_scheme_not_recognized",@"mp3_failed"]){NSMutableDictionary *wrong=[missing mutableCopy];wrong[@"stage"]=stage;assert(!SAPShouldRefreshCachedTrack(YES,NO,YES,wrong));}
 NSMutableDictionary *known=[missing mutableCopy];known[@"media_key_available"]=@YES;assert(!SAPShouldRefreshCachedTrack(YES,NO,YES,known));
 known=[missing mutableCopy];known[@"storage_decoded"]=@0;assert(!SAPShouldRefreshCachedTrack(YES,NO,YES,known));
 assert(!SAPShouldRefreshCachedTrack(YES,NO,YES,nil));
 puts("PASS refresh only verified downloaded cache with missing media key, once; unrelated failures untouched");
}return 0;}
